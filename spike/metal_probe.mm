// Minimal probe: can we create a Metal device + an MPS matmul object with just CLT
// (no full Xcode / no metal shader compiler)? If this builds and runs, the MPS spike
// is feasible.
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <cstdio>

int main() {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("no Metal device\n"); return 1; }
    printf("Metal device: %s\n", [[dev name] UTF8String]);
    printf("  unified memory: %s\n", dev.hasUnifiedMemory ? "yes" : "no");
    printf("  max buffer:     %.1f GB\n", (double)dev.maxBufferLength / 1e9);
    // Prove MPS matmul is constructible (precompiled, no metal compiler needed).
    MPSMatrixMultiplication *mm =
        [[MPSMatrixMultiplication alloc] initWithDevice:dev
            transposeLeft:NO transposeRight:NO
            resultRows:16 resultColumns:16 interiorColumns:16
            alpha:1.0 beta:0.0];
    printf("  MPSMatrixMultiplication: %s\n", mm ? "constructed OK" : "FAILED");
    return mm ? 0 : 1;
}
