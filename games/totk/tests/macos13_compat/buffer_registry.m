// Address-map regression: exceed the old 1024-entry cap without allocating GPU memory.
#import <Foundation/Foundation.h>
#import "m3_compat.h"
@interface RegistryBuffer : NSObject
@property uint64_t gpuAddress;
@property NSUInteger length;
@end
@implementation RegistryBuffer
@end
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"FAIL line %d index=%lu: %s\n",__LINE__,(unsigned long)i,#x);return 1;} }while(0)
int main(int argc, const char **argv) { @autoreleasepool {
 NSMutableArray *buffers=[NSMutableArray array];NSUInteger i=0,off=0;
 for(i=0;i<4097;i++) {
  RegistryBuffer *b=[RegistryBuffer new];b.gpuAddress=0x100000000ull+i*0x10000;b.length=4096;[buffers addObject:b];m3_buf_add((id)b);
 }
 for(i=0;i<buffers.count;i++) {
  RegistryBuffer *b=buffers[i];REQUIRE(m3_buf(b.gpuAddress+37,&off)==(id)b && off==37);
  REQUIRE(m3_buf(b.gpuAddress+b.length-1,&off)==(id)b && off==b.length-1);
  REQUIRE(m3_buf(b.gpuAddress+b.length,&off)==nil);
 }
 for(i=0;i<buffers.count;i+=2) { RegistryBuffer *b=buffers[i];m3_buf_del((id)b);REQUIRE(!m3_buf(b.gpuAddress,&off)); }
 for(i=1;i<buffers.count;i+=2) { RegistryBuffer *b=buffers[i];REQUIRE(m3_buf(b.gpuAddress+19,&off)==(id)b && off==19); }
 for(i=0;i<buffers.count;i++) { RegistryBuffer *b=buffers[i];if(!(i%2))m3_buf_add((id)b);m3_buf_add((id)b);m3_buf_del((id)b);REQUIRE(!m3_buf(b.gpuAddress,&off)); }
 puts("PASS 4097 buffers: address boundaries, removal compaction, re-add, duplicate registration");
 if(argc>1 && !strcmp(argv[1],"--gpu")) {
  id<MTLDevice> dev=m3_default_device();REQUIRE(dev);NSMutableArray *real=[NSMutableArray array];
  for(i=0;i<1050;i++){id<MTLBuffer> b=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];REQUIRE(b);[real addObject:b];m3_buf_add(b);}
  id<MTLBuffer> value=real.lastObject;*(uint32_t *)value.contents=41;
  id<MTLBuffer> result=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];m3_buf_add(result);
  NSError *error=nil;id<MTLLibrary> lib=[dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void read_value(device uint *v [[buffer(0)]],device uint *out [[buffer(1)]]) {out[0]=v[0]+1;}" options:nil error:&error];REQUIRE(lib);
  id<MTLComputePipelineState> pipeline=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_value"] error:&error];REQUIRE(pipeline);
  id<MTLCommandQueue> queue=[dev newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=m3_encoder_begin([cb computeCommandEncoder]);
  M3ArgTable *table=[M3ArgTable new];m3_attach(table,enc,M3_STAGE_COMPUTE);[table setAddress:value.gpuAddress atIndex:0];[table setAddress:result.gpuAddress atIndex:1];[enc setComputePipelineState:pipeline];[enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];REQUIRE(cb.status==MTLCommandBufferStatusCompleted);REQUIRE(*(uint32_t *)result.contents==42);
  for(id<MTLBuffer> b in real)m3_buf_del(b);m3_buf_del(result);
  puts("PASS real GPU reads buffer 1050 through M3ArgTable: result=42");
 }

}return 0;}
