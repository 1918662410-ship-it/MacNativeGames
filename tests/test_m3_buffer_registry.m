#import "m3_compat.h"
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return 2;
        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4096; i++) {
            id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            if (!b) return 3;
            [buffers addObject:b];
            m3_buf_add(b);
        }
        NSUInteger failures = 0;
        for (NSUInteger i = 0; i < buffers.count; i++) {
            id<MTLBuffer> b = buffers[i];
            NSUInteger offset = 0;
            if (m3_buf(b.gpuAddress + 123, &offset) != b || offset != 123) failures++;
        }
        printf("4096 live GPU buffers: %lu lookup failures\n", (unsigned long)failures);
        for (NSUInteger i = 0; i < buffers.count; i += 2) m3_buf_del(buffers[i]);
        for (NSUInteger i = 0; i < buffers.count; i++) {
            id<MTLBuffer> b = buffers[i];
            NSUInteger offset;
            id<MTLBuffer> found = m3_buf(b.gpuAddress, &offset);
            if ((i % 2 == 0 && found != nil) || (i % 2 && found != b)) failures++;
        }
        for (id<MTLBuffer> b in buffers) { m3_buf_add(b); m3_buf_add(b); }
        for (id<MTLBuffer> b in buffers) m3_buf_del(b);
        for (id<MTLBuffer> b in buffers) {
            NSUInteger offset;
            if (m3_buf(b.gpuAddress, &offset)) failures++;
        }
        printf("Removal, reinsertion and duplicate registration: %lu total failures\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
