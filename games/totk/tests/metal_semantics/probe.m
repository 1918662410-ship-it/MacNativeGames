// Metal behaviours the shader translation relies on, measured on this GPU (2026-10-15, flash investigation):
//  1. min / max / clamp / saturate with a NaN operand return the other operand (fast:: and precise::, safe and fast
//     math), like Maxwell's FMNMX / .SAT; so NaN is not kept alive by the translated shaders where hardware drops it.
//  2. under safe math (what the translated game shaders use) x * 0 stays IEEE: NaN / Inf times 0 is NaN.
//  3. a colour attachment the fragment function does not write keeps its content, with or without blending.
// Exit 1 on any difference. Run alone (GPU): make probe-metal-semantics.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "../../third_party/d2r_gfx/gfx/nvn/m3_device.h"
#if !DM_NVN_M3
#define m3_default_device MTLCreateSystemDefaultDevice
#endif
#include <math.h>
#include <stdio.h>
#include <string.h>

static NSString *kMinMax = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const float *in [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
    "  float x = in[i]; float y = in[8 + i]; device float *o = out + i * 12;\n"
    "  o[0] = fast::max(x, 0.0f); o[1] = fast::min(x, 1.0f); o[2] = fast::clamp(x, 0.0f, 1.0f); o[3] = precise::max(x, 0.0f);\n"
    "  o[4] = precise::min(x, 1.0f); o[5] = precise::clamp(x, 0.0f, 1.0f); o[6] = saturate(x); o[7] = max(x, 0.0f);\n"
    "  o[8] = fast::max(x, y); o[9] = fast::min(x, y); o[10] = x * 0.0f; o[11] = 0.0f; }\n";
static NSString *kUnwritten = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]]) { float2 q = float2((vid << 1) & 2, vid & 2); V o; o.p = float4(q * 2.0 - 1.0, 0.5, 1.0); return o; }\n"
    "struct O { float4 c0 [[color(0)]]; };\n"
    "fragment O fs() { O o; o.c0 = float4(0.25, 0.5, 0.75, 1.0); return o; }\n";

static int failures, checks;
static void expect(int ok, const char *what) { checks++; if (!ok) { failures++; printf("FAIL %s\n", what); } }

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = m3_default_device(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    if (!dev) { printf("no Metal device\n"); return 1; }
    // 1 + 2: NaN / Inf through min / max / clamp / saturate and x * 0
    const float in[16] = {NAN, -NAN, INFINITY, -INFINITY, 0.5f, -0.5f, 2.0f, 0.0f, 3, 3, 3, 3, 3, 3, 3, 3};
    for (int safe = 1; safe >= 0; safe--) {
        MTLCompileOptions *o = [MTLCompileOptions new]; o.fastMathEnabled = !safe;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kMinMax options:o error:&e]; if (!lib) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e]; if (!ps) return 1;
        id<MTLBuffer> bi = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
        id<MTLBuffer> bo = [dev newBufferWithLength:8 * 12 * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:bi offset:0 atIndex:0]; [ce setBuffer:bo offset:0 atIndex:1];
        [ce dispatchThreads:MTLSizeMake(8, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const float *r = bo.contents; char what[160];
        for (int i = 0; i < 2; i++) {   // the two NaN inputs
            const float want[10] = {0, 1, 0, 0, 1, 0, 0, 0, 3, 3};
            const char *names[10] = {"fast::max(x,0)", "fast::min(x,1)", "fast::clamp(x,0,1)", "precise::max(x,0)", "precise::min(x,1)",
                                     "precise::clamp(x,0,1)", "saturate(x)", "max(x,0)", "fast::max(x,3)", "fast::min(x,3)"};
            for (int k = 0; k < 10; k++) { snprintf(what, sizeof what, "%s math: %s with x = %sNaN gives %g, want %g", safe ? "safe" : "fast", names[k], i ? "-" : "", r[i * 12 + k], want[k]);
                expect(r[i * 12 + k] == want[k], what); }
        }
        if (safe) for (int i = 0; i < 4; i++) { snprintf(what, sizeof what, "safe math: x * 0 with x = %g gives %g, want NaN (IEEE)", in[i], r[i * 12 + 10]); expect(isnan(r[i * 12 + 10]), what); }
    }
    // 3: a colour attachment the fragment function does not write
    id<MTLLibrary> lib = [dev newLibraryWithSource:kUnwritten options:nil error:&e]; if (!lib) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
    const struct { const char *name; BOOL blend; MTLBlendFactor sf, df; } cases[] = {{"no blending", NO, MTLBlendFactorOne, MTLBlendFactorZero},
        {"blend one / zero", YES, MTLBlendFactorOne, MTLBlendFactorZero}, {"blend src-alpha / one-minus-src-alpha", YES, MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha},
        {"blend one / one", YES, MTLBlendFactorOne, MTLBlendFactorOne}};
    for (unsigned c = 0; c < sizeof cases / sizeof *cases; c++) for (int load = 0; load < 2; load++) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.colorAttachments[1].pixelFormat = MTLPixelFormatR32Float;
        d.colorAttachments[1].writeMask = MTLColorWriteMaskAll; d.colorAttachments[1].blendingEnabled = cases[c].blend;
        d.colorAttachments[1].sourceRGBBlendFactor = d.colorAttachments[1].sourceAlphaBlendFactor = cases[c].sf;
        d.colorAttachments[1].destinationRGBBlendFactor = d.colorAttachments[1].destinationAlphaBlendFactor = cases[c].df;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!ps) { printf("%s\n", e.localizedDescription.UTF8String); return 1; }
        MTLTextureDescriptor *t0 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        t0.usage = MTLTextureUsageRenderTarget; t0.storageMode = MTLStorageModePrivate;
        MTLTextureDescriptor *t1 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:64 height:64 mipmapped:NO];
        t1.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; t1.storageMode = MTLStorageModeShared;
        id<MTLTexture> a0 = [dev newTextureWithDescriptor:t0], a1 = [dev newTextureWithDescriptor:t1];
        float fill[64 * 64]; for (int i = 0; i < 64 * 64; i++) fill[i] = 123.0f;
        [a1 replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:fill bytesPerRow:64 * 4];
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = a0; p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore;
        p.colorAttachments[1].texture = a1; p.colorAttachments[1].storeAction = MTLStoreActionStore;
        p.colorAttachments[1].loadAction = load ? MTLLoadActionLoad : MTLLoadActionClear; p.colorAttachments[1].clearColor = MTLClearColorMake(123, 0, 0, 0);
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:p];
        [en setRenderPipelineState:ps]; for (int k = 0; k < 3; k++) [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
        float out[64 * 64]; [a1 getBytes:out bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
        int kept = 0; for (int i = 0; i < 64 * 64; i++) kept += out[i] == 123.0f;
        char what[160]; snprintf(what, sizeof what, "unwritten R32F attachment, %s, %s: %d / 4096 texels kept", cases[c].name, load ? "load" : "clear", kept);
        expect(kept == 64 * 64, what);
    }
    printf("{\"status\":\"%s\",\"probe\":\"metal-semantics\",\"checked\":%d,\"failed\":%d}\n", failures ? "fail" : "pass", checks, failures);
    return failures ? 1 : 0;
} }
