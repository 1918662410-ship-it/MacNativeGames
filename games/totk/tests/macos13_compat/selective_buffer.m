// Real GPU check for the streamed-pass selective texture declaration strategy.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "m3_compat.h"
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} }while(0)
int main(int argc, const char **argv) { @autoreleasepool {
 int mode=argc>1?atoi(argv[1]):1;REQUIRE(mode>=0 && mode<=2);
 id<MTLDevice> dev=m3_default_device(); REQUIRE(dev);
 NSError *error=nil;
 NSString *src=@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { texture2d<float> tex [[id(0)]]; device atomic_uint *count [[id(1)]]; };\nvertex float4 vs(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 fs(constant Args &a [[buffer(0)]]) { atomic_fetch_add_explicit(a.count,1u,memory_order_relaxed); return a.tex.read(uint2(0)); }";
 id<MTLLibrary> lib=[dev newLibraryWithSource:src options:nil error:&error]; REQUIRE(lib);
 id<MTLFunction> fragment=[lib newFunctionWithName:@"fs"];
 MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"vs"];pd.fragmentFunction=fragment;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
 id<MTLRenderPipelineState> pipeline=[dev newRenderPipelineStateWithDescriptor:pd error:&error];REQUIRE(pipeline);
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
 id<MTLTexture> source=[dev newTextureWithDescriptor:td]; uint8_t expected[4]={41,89,137,255};[source replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:expected bytesPerRow:4];
 td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> output=[dev newTextureWithDescriptor:td];REQUIRE(source&&output);
 id<MTLBuffer> written=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];*(uint32_t *)written.contents=41;
 id<MTLArgumentEncoder> args=[fragment newArgumentEncoderWithBufferIndex:0];id<MTLBuffer> ab=[dev newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];[args setArgumentBuffer:ab offset:0];[args setTexture:source atIndex:0];[args setBuffer:written offset:0 atIndex:1];
 M3ResidencySet *resident=[M3ResidencySet new];[resident addAllocation:source];[resident addAllocation:output];[resident addAllocation:ab];[resident addAllocation:written];m3_selective_buffers_set(mode);
 id<MTLCommandQueue> queue=[dev newCommandQueue];
 for(int pass=0;pass<4;pass++) {
  id<MTLCommandBuffer> cb=[queue commandBuffer];MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=output;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc=m3_encoder_begin([cb renderCommandEncoderWithDescriptor:rp]);m3_encoder_selective(enc);m3_use_resident_resources(enc);
  if(pass==3){m3_encoder_full_buffers(enc);m3_use_resident_resources(enc);}
  [enc setRenderPipelineState:pipeline];[enc setFragmentBuffer:ab offset:0 atIndex:0];[enc useResource:source usage:MTLResourceUsageRead stages:MTLRenderStageFragment];[enc useResource:written usage:MTLResourceUsageRead|MTLResourceUsageWrite stages:MTLRenderStageFragment];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
  uint8_t actual[4]={0};[output getBytes:actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];REQUIRE(!memcmp(actual,expected,4));REQUIRE(*(uint32_t *)written.contents==(uint32_t)(42+pass));
 }
 printf("PASS buffer mode %d: actual indirect atomic writes, four passes return 42..45, last pass conservative fallback\n",mode);
}return 0;}
