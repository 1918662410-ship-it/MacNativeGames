/* Independent GPU reference: compare a load-clear with a fragment writing the
   same requested depth. Run alone through the shared game slot. No game data. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn_depth_clear.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V {float4 p [[position]];};\n"
    "vertex V vs(uint i [[vertex_id]]) {float2 q=float2((i<<1)&2,i&2); V o;o.p=float4(q*2.-1.,.5,1.);return o;}\n"
    "struct D {float z [[depth(any)]];};\n"
    "fragment D fs(constant float& d [[buffer(0)]]) {return D{d};}\n";

static void check(int ok, const char *what) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",what);exit(1); }
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();check(dev!=nil,"Metal device");
    NSError *error=nil;
    id<MTLLibrary> lib=[dev newLibraryWithSource:source options:nil error:&error];
    if (!lib) fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    check(lib!=nil,"synthetic depth shader");
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"vs"];pd.fragmentFunction=[lib newFunctionWithName:@"fs"];
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
    id<MTLRenderPipelineState> pipeline=[dev newRenderPipelineStateWithDescriptor:pd error:&error];
    check(pipeline!=nil,"depth-only pipeline");
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];
    dd.depthCompareFunction=MTLCompareFunctionAlways;dd.depthWriteEnabled=YES;
    id<MTLDepthStencilState> ds=[dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:128 height:4 mipmapped:NO];
    td.usage=MTLTextureUsageRenderTarget;td.storageMode=MTLStorageModePrivate;
    id<MTLTexture> depth=[dev newTextureWithDescriptor:td];
    id<MTLBuffer> read=[dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> parameter=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    check(depth&&read&&parameter,"test resources");
    id<MTLCommandQueue> q3=[dev newCommandQueue];
    check(q3 != nil,"Metal 3 queue");

    float values[1024];unsigned count=0;
    const float anchors[]={0.f,1.f,.25f,.5f,.75f,
        nextafterf(.25f,0.f),nextafterf(.25f,1.f),nextafterf(.5f,0.f),nextafterf(.5f,1.f)};
    for(unsigned i=0;i<sizeof anchors/sizeof anchors[0];i++)values[count++]=anchors[i];
    for(unsigned i=0;i<256;i++)values[count++]=fmaf((float)i/255.f,.5f,.5f);
    uint32_t state=0x51a7d16u;
    for(unsigned i=0;i<512;i++){state=state*1664525u+1013904223u;values[count++]=(float)(state>>8)*0x1p-24f;}

    unsigned total_bad=0;
    for(int api=3;api<=3;api++) {
        unsigned bad[2]={0,0};
        for(unsigned i=0;i<count;i++)for(int fixed=0;fixed<2;fixed++) { @autoreleasepool {
            float value=values[i];*(float *)parameter.contents=value;
            double clear=fixed?nvn_depth16_clear_value(value):(double)value;
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];
            MTLRenderPassDepthAttachmentDescriptor *attachment=[rp depthAttachment];
            attachment.texture=depth;attachment.loadAction=MTLLoadActionClear;attachment.storeAction=MTLStoreActionStore;attachment.clearDepth=clear;
            id<MTLCommandBuffer> cb3=[q3 commandBuffer];
            id<MTLRenderCommandEncoder> render=[cb3 renderCommandEncoderWithDescriptor:rp];
            [render setRenderPipelineState:pipeline];[render setDepthStencilState:ds];
            [render setViewport:(MTLViewport){0,0,128,4,0,1}];[render setScissorRect:(MTLScissorRect){0,0,64,4}];
            [render setFragmentBuffer:parameter offset:0 atIndex:0];
            [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[render endEncoding];
            id<MTLBlitCommandEncoder> blit=[cb3 blitCommandEncoder];
            [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,4,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
            [blit endEncoding];
            [cb3 commit];[cb3 waitUntilCompleted];check(cb3.status!=MTLCommandBufferStatusError,"Metal 3 completion");
            const uint16_t *r=read.contents;
            if(r[128+16]!=r[128+96]) {
                bad[fixed]++;
                if(fixed&&bad[fixed]<=4)fprintf(stderr,"Metal %d depth %.9g: fragment %u clear %u\n",api,value,r[128+16],r[128+96]);
            }
        }}
        printf("{\"api\":%d,\"depth_values\":%u,\"old_mismatches\":%u,\"fixed_mismatches\":%u,\"game_data\":false}\n",api,count,bad[0],bad[1]);
        total_bad+=bad[1];
    }
    check(total_bad==0,"load-clears must match the independent fragment-depth reference");
    return 0;
}}
