// Indirect texture RAW dependencies across separate compute encoders, plus stage timestamps.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "m3_compat.h"
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} }while(0)
int main(void) { @autoreleasepool {
 id<MTLDevice> dev=m3_default_device();REQUIRE(dev);NSError *error=nil;
 NSString *src=@"#include <metal_stdlib>\nusing namespace metal;struct Args { texture2d<uint,access::read> src [[id(0)]];texture2d<uint,access::write> dst [[id(1)]];};kernel void step(constant Args &a [[buffer(0)]]) {a.dst.write(a.src.read(uint2(0))+uint4(1),uint2(0));}";
 id<MTLLibrary> lib=[dev newLibraryWithSource:src options:nil error:&error];REQUIRE(lib);
 id<MTLFunction> fn=[lib newFunctionWithName:@"step"];id<MTLComputePipelineState> ps=[dev newComputePipelineStateWithFunction:fn error:&error];REQUIRE(ps);
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
 id<MTLTexture> tex[2]={[dev newTextureWithDescriptor:td],[dev newTextureWithDescriptor:td]};uint32_t initial=41;[tex[0] replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&initial bytesPerRow:4];
 M3ResidencySet *resident=[M3ResidencySet new];[resident addAllocation:tex[0]];[resident addAllocation:tex[1]];
 id<MTLCounterSet> timestamps=nil;for(id<MTLCounterSet> set in dev.counterSets)if([set.name isEqual:MTLCommonCounterSetTimestamp])timestamps=set;
 REQUIRE(timestamps && [dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]);MTLCounterSampleBufferDescriptor *sd=[MTLCounterSampleBufferDescriptor new];sd.counterSet=timestamps;sd.sampleCount=8;sd.storageMode=MTLStorageModeShared;id<MTLCounterSampleBuffer> samples=[dev newCounterSampleBufferWithDescriptor:sd error:&error];REQUIRE(samples);
 id<MTLCommandQueue> queue=[dev newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];
 for(int pass=0;pass<4;pass++) {
  id<MTLArgumentEncoder> args=[fn newArgumentEncoderWithBufferIndex:0];id<MTLBuffer> ab=[dev newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];[args setArgumentBuffer:ab offset:0];[args setTexture:tex[pass%2] atIndex:0];[args setTexture:tex[1-pass%2] atIndex:1];[resident addAllocation:ab];
  MTLComputePassDescriptor *pd=[MTLComputePassDescriptor computePassDescriptor];pd.sampleBufferAttachments[0].sampleBuffer=samples;pd.sampleBufferAttachments[0].startOfEncoderSampleIndex=pass*2;pd.sampleBufferAttachments[0].endOfEncoderSampleIndex=pass*2+1;
  id<MTLComputeCommandEncoder> enc=m3_encoder_begin([cb computeCommandEncoderWithDescriptor:pd]);m3_encoder_compute_selective(enc);
  [enc setComputePipelineState:ps];[enc setBuffer:ab offset:0 atIndex:0];m3_use_compute_resource(enc,tex[pass%2],MTLResourceUsageRead);m3_use_compute_resource(enc,tex[1-pass%2],MTLResourceUsageWrite);m3_use_resident_resources(enc);[enc dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[enc endEncoding];
 }
 [cb commit];[cb waitUntilCompleted];REQUIRE(cb.status==MTLCommandBufferStatusCompleted);uint32_t result=0;[tex[0] getBytes:&result bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];REQUIRE(result==45);
 NSData *data=[samples resolveCounterRange:NSMakeRange(0,8)];REQUIRE(data.length==8*sizeof(MTLCounterResultTimestamp));const MTLCounterResultTimestamp *ts=data.bytes;
 for(int i=0;i<4;i++){REQUIRE(ts[2*i].timestamp && ts[2*i+1].timestamp!=MTLCounterErrorValue && ts[2*i+1].timestamp>=ts[2*i].timestamp);printf("pass %d: %llu -> %llu\n",i,(unsigned long long)ts[2*i].timestamp,(unsigned long long)ts[2*i+1].timestamp);}
 puts("PASS selective compute: four indirect read/write passes produce 45; four valid stage intervals");
}return 0;}
