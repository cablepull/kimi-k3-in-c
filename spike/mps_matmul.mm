// GPU spike: measure MPS bf16 trunk matmul vs CPU, for speed AND bit-exactness delta.
//
// The engine's per-token matmul is a matrix-VECTOR product (M=1: one token against the
// weight matrix). That is bandwidth-bound -- each weight is read once -- so the GPU win
// should track the memory-bandwidth ratio, not the FLOP ratio. And GPU FP won't match
// the CPU reference bit-for-bit, which breaks the engine's exact-token oracle. This
// measures both, on the real bf16 trunk dimensions (12288 x 7168), before anyone commits
// to a Metal port.
//
// Build: clang++ -std=c++17 -O3 -fobjc-arc mps_matmul.mm -o mps_matmul \
//        -framework Metal -framework MetalPerformanceShaders -framework Foundation
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <ctime>
#ifdef _OPENMP
#include <omp.h>
#endif

static double now_s() {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static inline float bf16f(uint16_t b) { uint32_t u = (uint32_t)b << 16; float f; __builtin_memcpy(&f, &u, 4); return f; }
static inline uint16_t fbf16(float f) { uint32_t u; __builtin_memcpy(&u, &f, 4); return (uint16_t)(u >> 16); }

int main() {
    const int in = 7168, out = 12288;   // KDA q_proj bf16 matmul, the trunk's shape
    std::vector<uint16_t> W((size_t)out * in);   // bf16 weights
    std::vector<float>    x(in), y_cpu(out), y_gpu(out);
    srand(1);
    for (auto &w : W) w = fbf16((float)(rand() % 1000 - 500) / 5000.0f);
    for (auto &v : x) v = (float)(rand() % 1000 - 500) / 500.0f;

    // ---- CPU reference: y[o] = sum_i W[o,i] * x[i], double accumulate (engine style) ----
    const int reps = 20;
    double t0 = now_s();
    for (int r = 0; r < reps; r++) {
#ifdef _OPENMP
#       pragma omp parallel for schedule(static)
#endif
        for (int o = 0; o < out; o++) {
            double acc = 0.0;
            const uint16_t *wr = &W[(size_t)o * in];
            for (int i = 0; i < in; i++) acc += (double)bf16f(wr[i]) * (double)x[i];
            y_cpu[o] = (float)acc;
        }
    }
    double cpu_ms = (now_s() - t0) / reps * 1e3;
    double gflop = 2.0 * out * in / 1e9;
    int nth = 1;
#ifdef _OPENMP
    #pragma omp parallel
    { nth = omp_get_num_threads(); }
#endif
    printf("CPU  (%2d threads)         %7.2f ms  %8.1f GFLOP/s\n", nth, cpu_ms, gflop / (cpu_ms/1e3));

    // ---- GPU via MPS: dequant W to fp32 (unified memory, no copy), GEMV as 1xK * KxN ----
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    // Unified memory: allocate shared buffers the CPU fills and the GPU reads in place.
    id<MTLBuffer> bW = [dev newBufferWithLength:(size_t)out*in*sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLBuffer> bx = [dev newBufferWithLength:(size_t)in*sizeof(float)      options:MTLResourceStorageModeShared];
    id<MTLBuffer> by = [dev newBufferWithLength:(size_t)out*sizeof(float)     options:MTLResourceStorageModeShared];
    float *Wf = (float*)bW.contents;
    for (size_t k = 0; k < (size_t)out*in; k++) Wf[k] = bf16f(W[k]);   // bf16 -> fp32
    __builtin_memcpy(bx.contents, x.data(), in*sizeof(float));

    // y[1xN] = x[1xK] * W^T[KxN]; store W as [out x in] row-major = W^T with transposeRight.
    MPSMatrixDescriptor *dX = [MPSMatrixDescriptor matrixDescriptorWithRows:1 columns:in rowBytes:in*sizeof(float) dataType:MPSDataTypeFloat32];
    MPSMatrixDescriptor *dW = [MPSMatrixDescriptor matrixDescriptorWithRows:out columns:in rowBytes:in*sizeof(float) dataType:MPSDataTypeFloat32];
    MPSMatrixDescriptor *dY = [MPSMatrixDescriptor matrixDescriptorWithRows:1 columns:out rowBytes:out*sizeof(float) dataType:MPSDataTypeFloat32];
    MPSMatrix *mX = [[MPSMatrix alloc] initWithBuffer:bx descriptor:dX];
    MPSMatrix *mW = [[MPSMatrix alloc] initWithBuffer:bW descriptor:dW];
    MPSMatrix *mY = [[MPSMatrix alloc] initWithBuffer:by descriptor:dY];
    MPSMatrixMultiplication *mm = [[MPSMatrixMultiplication alloc] initWithDevice:dev
        transposeLeft:NO transposeRight:YES resultRows:1 resultColumns:out interiorColumns:in alpha:1.0 beta:0.0];

    // warm
    { id<MTLCommandBuffer> cb = [q commandBuffer]; [mm encodeToCommandBuffer:cb leftMatrix:mX rightMatrix:mW resultMatrix:mY]; [cb commit]; [cb waitUntilCompleted]; }
    t0 = now_s();
    for (int r = 0; r < reps; r++) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        [mm encodeToCommandBuffer:cb leftMatrix:mX rightMatrix:mW resultMatrix:mY];
        [cb commit]; [cb waitUntilCompleted];
    }
    double gpu_ms = (now_s() - t0) / reps * 1e3;
    printf("GPU  (MPS, fp32)         %7.2f ms  %8.1f GFLOP/s   (%.1fx CPU)\n",
           gpu_ms, gflop / (gpu_ms/1e3), cpu_ms / gpu_ms);

    // ---- bit-exactness delta: GPU vs CPU-double reference ----
    __builtin_memcpy(y_gpu.data(), by.contents, out*sizeof(float));
    double max_abs = 0, max_rel = 0; int exact = 0;
    for (int o = 0; o < out; o++) {
        double a = fabs((double)y_gpu[o] - (double)y_cpu[o]);
        double rel = a / (fabs((double)y_cpu[o]) + 1e-9);
        if (a > max_abs) max_abs = a;
        if (rel > max_rel) max_rel = rel;
        if (y_gpu[o] == y_cpu[o]) exact++;
    }
    printf("bit-exactness: %d/%d outputs identical, max abs diff %.3e, max rel %.3e\n",
           exact, out, max_abs, max_rel);
    printf("=> GPU is %s bit-exact with the CPU reference.\n", exact == out ? "" : "NOT");
    return 0;
}
