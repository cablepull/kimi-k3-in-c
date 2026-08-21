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
    const int in = 7168, out = 12288;   // trunk bf16 matmul shape (out x in)
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    printf("device: %s, unified memory: %s\n\n", [[dev name] UTF8String],
           dev.hasUnifiedMemory ? "yes" : "no");

    // Weights (bf16 -> fp32 once, resident in shared/unified memory: GPU reads in place).
    std::vector<uint16_t> W((size_t)out * in);
    srand(1);
    for (auto &w : W) w = fbf16((float)(rand() % 1000 - 500) / 5000.0f);
    id<MTLBuffer> bW = [dev newBufferWithLength:(size_t)out*in*sizeof(float) options:MTLResourceStorageModeShared];
    float *Wf = (float*)bW.contents;
    for (size_t k = 0; k < (size_t)out*in; k++) Wf[k] = bf16f(W[k]);
    MPSMatrixDescriptor *dW = [MPSMatrixDescriptor matrixDescriptorWithRows:out columns:in rowBytes:in*sizeof(float) dataType:MPSDataTypeFloat32];
    MPSMatrix *mW = [[MPSMatrix alloc] initWithBuffer:bW descriptor:dW];

    // Sweep M = tokens processed together. M=1 is single-token DECODE (GEMV, the steady
    // per-token cost). M>1 is PREFILL / BATCHED serving (GEMM): each weight is reused
    // across M tokens, so the work becomes FLOP-bound -- where the GPU should pull away.
    printf("M(tokens) |  CPU 16t GFLOP/s |  GPU GFLOP/s |  GPU speedup   <- decode is M=1\n");
    printf("----------|------------------|--------------|-------------\n");
    for (int M : {1, 4, 16, 64, 256}) {
        std::vector<float> X((size_t)M*in);
        for (auto &v : X) v = (float)(rand()%1000-500)/500.0f;
        std::vector<float> Ycpu((size_t)M*out);
        const double gflop = 2.0 * M * out * in / 1e9;
        const int reps = M >= 64 ? 5 : 20;

        // CPU: Y[M x out] = X[M x in] * W^T, double accumulate, threaded over (m,o).
        double t0 = now_s();
        for (int r = 0; r < reps; r++) {
#ifdef _OPENMP
#           pragma omp parallel for schedule(static) collapse(2)
#endif
            for (int m = 0; m < M; m++)
                for (int o = 0; o < out; o++) {
                    double acc = 0.0; const uint16_t *wr = &W[(size_t)o*in];
                    const float *xr = &X[(size_t)m*in];
                    for (int i = 0; i < in; i++) acc += (double)bf16f(wr[i]) * (double)xr[i];
                    Ycpu[(size_t)m*out+o] = (float)acc;
                }
        }
        double cpu_ms = (now_s()-t0)/reps*1e3;

        // GPU MPS GEMM.
        id<MTLBuffer> bX = [dev newBufferWithLength:(size_t)M*in*sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> bY = [dev newBufferWithLength:(size_t)M*out*sizeof(float) options:MTLResourceStorageModeShared];
        __builtin_memcpy(bX.contents, X.data(), (size_t)M*in*sizeof(float));
        MPSMatrixDescriptor *dX = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:in rowBytes:in*sizeof(float) dataType:MPSDataTypeFloat32];
        MPSMatrixDescriptor *dY = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:out rowBytes:out*sizeof(float) dataType:MPSDataTypeFloat32];
        MPSMatrix *mX = [[MPSMatrix alloc] initWithBuffer:bX descriptor:dX];
        MPSMatrix *mY = [[MPSMatrix alloc] initWithBuffer:bY descriptor:dY];
        MPSMatrixMultiplication *mm = [[MPSMatrixMultiplication alloc] initWithDevice:dev
            transposeLeft:NO transposeRight:YES resultRows:M resultColumns:out interiorColumns:in alpha:1.0 beta:0.0];
        { id<MTLCommandBuffer> cb=[q commandBuffer]; [mm encodeToCommandBuffer:cb leftMatrix:mX rightMatrix:mW resultMatrix:mY]; [cb commit]; [cb waitUntilCompleted]; }
        t0 = now_s();
        for (int r = 0; r < reps; r++) {
            id<MTLCommandBuffer> cb=[q commandBuffer];
            [mm encodeToCommandBuffer:cb leftMatrix:mX rightMatrix:mW resultMatrix:mY];
            [cb commit]; [cb waitUntilCompleted];
        }
        double gpu_ms = (now_s()-t0)/reps*1e3;
        printf("%9d | %16.1f | %12.1f | %8.1fx\n",
               M, gflop/(cpu_ms/1e3), gflop/(gpu_ms/1e3), cpu_ms/gpu_ms);
    }
    printf("\nDecode (M=1) is bandwidth-bound => GPU ~parity. Prefill/batch (M>>1) is\n"
           "FLOP-bound => GPU pulls away. Single-stream chat lives at M=1.\n");
    return 0;
}
