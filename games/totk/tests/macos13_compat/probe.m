// Resource ownership and indirect GPU access for the Ventura Metal 3 path.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "m3_compat.h"
#include <stdio.h>
#include <string.h>

@interface RecordingEncoder : NSObject
@property NSMutableArray *resources;
@property NSUInteger declarations;
@property NSMapTable *usages;
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage;
- (void)useResources:(id const __unsafe_unretained *)resources count:(NSUInteger)n usage:(MTLResourceUsage)usage;
@end
@implementation RecordingEncoder
- (void)useResources:(id const __unsafe_unretained *)r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)stages { [self useResources:r count:n usage:u]; }
- (void)useResource:(id)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)stages { [self useResource:r usage:u]; }
- (void)useResources:(id const __unsafe_unretained *)resources count:(NSUInteger)n usage:(MTLResourceUsage)usage { for(NSUInteger i=0;i<n;i++)[self useResource:resources[i] usage:usage]; }
- (instancetype)init { if ((self = [super init])) { _resources = [NSMutableArray array]; _usages=[NSMapTable weakToStrongObjectsMapTable]; } return self; }
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage {
    NSCAssert((usage & MTLResourceUsageRead) != 0, @"indirect reads must be declared");
    [_resources addObject:resource]; [_usages setObject:@(usage) forKey:resource]; ++_declarations;
}
@end
#define CHECK(ok, message) do { if (!(ok)) { fprintf(stderr,"FAIL %s\n",message); return 1; } printf("PASS %s\n",message); } while(0)

int main(int argc, char **argv) { @autoreleasepool {
    M3ResidencySet *set = [M3ResidencySet new];
    RecordingEncoder *encoder = [RecordingEncoder new];
    __weak NSObject *weak;
    @autoreleasepool {
    @autoreleasepool {
        NSObject *resource = [NSObject new]; weak = resource;
        [set addAllocation:(id)resource]; [set addAllocation:(id)resource];
    }
    CHECK(weak != nil, "registered resource stays alive");
    m3_use_resident_resources(encoder);
    CHECK(encoder.declarations == 1, "duplicate registration declares once");
    m3_use_resident_resources(encoder);
    CHECK(encoder.declarations == 1, "unchanged generation avoids repeated declarations");
    m3_encoder_begin(encoder);m3_use_resident_resources(encoder);
    CHECK(encoder.declarations==2,"recycled encoder declares resources again in a new pass");
    @autoreleasepool {
        NSObject *second = [NSObject new]; [set addAllocation:(id)second];
        m3_use_resident_resources(encoder);
        CHECK(encoder.declarations == 4, "late allocation is declared on the current encoder");
        [set removeAllocation:(id)second];
    }
    RecordingEncoder *next = [RecordingEncoder new];
    m3_use_resident_resources(next);
    CHECK(next.resources.count == 1, "new encoder sees only live registrations");
    @autoreleasepool { [set removeAllocation:(id)weak]; }
    [encoder.resources removeAllObjects]; [next.resources removeAllObjects];
    }
    CHECK(weak == nil, "retired resource is released");
    if (argc > 1 && !strcmp(argv[1], "--cpu-only")) return 0;

    NSArray *devices = MTLCopyAllDevices();
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("TRACE Metal devices=%lu default=%s\n", (unsigned long)devices.count, dev.name.UTF8String ?: "none");
    if (!dev && devices.count) { dev = m3_default_device(); printf("TRACE fallback device=%s unified=%d\n", dev.name.UTF8String, dev.hasUnifiedMemory); }
    if (!dev) { puts("BLOCKED GPU execution: Metal returned no device (exit 77)"); return 77; }
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> readTex=[dev newTextureWithDescriptor:td];
    td.usage|=MTLTextureUsageShaderWrite;
    id<MTLTexture> writeTex=[dev newTextureWithDescriptor:td];
    CHECK(readTex&&writeTex,"test textures allocated");
    [set addAllocation:readTex];[set addAllocation:writeTex];
    RecordingEncoder *access=[RecordingEncoder new];m3_use_resident_resources(access);
    CHECK([[access.usages objectForKey:readTex] unsignedLongValue]==MTLResourceUsageRead,"read-only texture is not declared writable");
    CHECK([[access.usages objectForKey:writeTex] unsignedLongValue]==(MTLResourceUsageRead|MTLResourceUsageWrite),"shader-writable texture preserves write access");
    id<MTLBuffer> conservative=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    [set addAllocation:conservative];
    RecordingEncoder *selective=[RecordingEncoder new];
    m3_encoder_begin(selective);m3_encoder_selective(selective);m3_use_resident_resources(selective);
    CHECK(![selective.resources containsObject:readTex] && ![selective.resources containsObject:writeTex],"selective pass omits unrelated textures");
    CHECK([selective.resources containsObject:conservative],"selective pass retains conservative buffer declarations");
    m3_encoder_begin(selective);m3_use_resident_resources(selective);
    CHECK([selective.resources containsObject:readTex] && [selective.resources containsObject:writeTex],"recycled non-selective pass restores full texture declarations");
    [set removeAllocation:conservative];
    [set removeAllocation:readTex];[set removeAllocation:writeTex];
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { device uint *value; }; kernel void read_indirect(constant Args &a [[buffer(0)]], device uint *out [[buffer(1)]]) { out[0] = a.value[0] + 1; }";
    MTLCompileOptions *opts = [MTLCompileOptions new]; opts.languageVersion = MTLLanguageVersion3_0; opts.fastMathEnabled = NO;
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:opts error:&error];
    if (!lib) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    CHECK(lib != nil, "Metal 3 shader compiles");
    id<MTLComputePipelineState> pipeline = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_indirect"] error:&error];
    CHECK(pipeline != nil, "compute pipeline created");
    uint32_t input = 41;
    id<MTLBuffer> value = [dev newBufferWithBytes:&input length:sizeof(input) options:MTLResourceStorageModeShared];
    uint64_t address = value.gpuAddress;
    id<MTLBuffer> args = [dev newBufferWithBytes:&address length:sizeof(address) options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [dev newBufferWithLength:sizeof(input) options:MTLResourceStorageModeShared];
    [set addAllocation:value];
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:pipeline]; [ce setBuffer:args offset:0 atIndex:0]; [ce setBuffer:output offset:0 atIndex:1];
    m3_use_resident_resources(ce);
    [ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "GPU command completes");
    CHECK(*(uint32_t *)output.contents == 42, "indirect buffer access returns 42");
    [set removeAllocation:value];
    return 0;
} }
