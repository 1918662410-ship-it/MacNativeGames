// Standalone classic CAMetalLayer presentation check. No game data is loaded.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import "m3_compat.h"
#include <stdio.h>
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    id<MTLDevice> dev = m3_default_device(); if (!dev) return 77;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,360) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Metal 3 / macOS 13 — compatibility test (not Zelda)";
    window.contentView.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = dev; layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.drawableSize = CGSizeMake(640,360); layer.framebufferOnly = NO; window.contentView.layer = layer;
    [window center]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    __block int status = 1;
    NSString *output = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ @autoreleasepool {
        NSError *error = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal; struct V { float4 p [[position]]; float2 uv; }; vertex V vs(uint i [[vertex_id]]) { float2 p = float2((i << 1) & 2, i & 2); return {float4(p*2-1,0,1),p}; } fragment float4 fs(V v [[stage_in]]) { return float4(v.uv.x,v.uv.y,0.25,1); }";
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&error];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = layer.pixelFormat;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!ps || !drawable) { fprintf(stderr,"FAIL pipeline or drawable: %s\n",error.localizedDescription.UTF8String ?: "no drawable"); exit(1); }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> queue = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        M3ArgTable *table = [M3ArgTable new]; m3_attach(table,en,M3_STAGE_VERTEX);
        [en setRenderPipelineState:ps]; m3_use_resident_resources(en); [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        id<MTLBuffer> pixels = [dev newBufferWithLength:640*360*4 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(640,360,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:640*4 destinationBytesPerImage:640*360*4]; [blit endEncoding];
        [cb presentDrawable:drawable]; [cb commit]; [cb waitUntilCompleted];
        const uint8_t *bgra = pixels.contents; NSUInteger center = (180*640+320)*4;
        status = cb.status == MTLCommandBufferStatusCompleted && bgra[center+2] > 100 && bgra[center+1] > 100 && bgra[center] > 50 ? 0 : 1;
        printf("%s classic nextDrawable + triangle + present + readback; center BGRA=%u,%u,%u,%u\n",status ? "FAIL":"PASS",bgra[center],bgra[center+1],bgra[center+2],bgra[center+3]); fflush(stdout);
        if (!status && output) {
            NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:640 pixelsHigh:360 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:640*4 bitsPerPixel:32];
            for (NSUInteger i=0;i<640*360;i++) { image.bitmapData[i*4]=bgra[i*4+2]; image.bitmapData[i*4+1]=bgra[i*4+1]; image.bitmapData[i*4+2]=bgra[i*4]; image.bitmapData[i*4+3]=bgra[i*4+3]; }
            [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [window orderOut:nil]; exit(status); });
    }});
    [NSApp run]; return status;
} }
