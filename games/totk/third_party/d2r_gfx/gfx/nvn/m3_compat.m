// Metal 4 → Metal 3 兼容层实现（DM_NVN_M3=1）
// Implementation of the Metal 4 -> Metal 3 compatibility layer.
#import "m3_compat.h"
#if DM_NVN_M3

#import <os/lock.h>
#import <string.h>
#import <objc/runtime.h>

id<MTLDevice> m3_default_device(void) {
    static id<MTLDevice> device; static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = MTLCreateSystemDefaultDevice();
        if (!device) for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
            if (candidate.hasUnifiedMemory && [candidate supportsFamily:MTLGPUFamilyMetal3]) {
                device = candidate;
                fprintf(stderr, "[m3] default GPU unavailable; selected %s from device enumeration\n", device.name.UTF8String);
                break;
            }
        }
    });
    return device;
}

// Share a strong resource snapshot across encoders until membership changes.
// Metal may recycle encoder objects between passes; begin explicitly resets its declaration stamp.
#import <stdatomic.h>
@interface M3ResourceSnapshot : NSObject {
@public
    NSArray *owners;
    id<MTLResource> __unsafe_unretained *items;
    NSUInteger count,readCount;
    NSArray *buffers;
    id<MTLResource> __unsafe_unretained *bufferItems;
    NSUInteger bufferCount;
    uint64_t generation;
}
@end
@implementation M3ResourceSnapshot
- (void)dealloc { free(items); free(bufferItems); }
@end
static NSHashTable *g_m3_sets;
static _Atomic uint64_t g_m3_resource_generation = 1;
static M3ResourceSnapshot *g_m3_snapshot;
static char g_m3_encoder_generation, g_m3_selective, g_m3_buffer_readonly;
static _Atomic int g_m3_selective_on = -1;
static _Atomic int g_m3_selective_buffers = -1;
static _Atomic int g_m3_selective_compute = -1;
// 0: every compute encoder declares all resident resources.
// 1: reflected game dispatches declare actual textures; all buffers stay global.
// 2: reflected game dispatches declare actual textures and buffers; helper kernels,
//    which bind everything through direct Metal slots, declare nothing extra.
int m3_selective_compute_enabled(void) {
    int on=atomic_load_explicit(&g_m3_selective_compute,memory_order_relaxed);
    if(on<0) { const char *v=getenv("TOTK_M3_SELECTIVE_COMPUTE");int expected=-1,want=v?atoi(v):2;
        if(want<0||want>2)want=0;
        atomic_compare_exchange_strong(&g_m3_selective_compute,&expected,want);
        on=atomic_load(&g_m3_selective_compute);
    }
    return on;
}
void m3_selective_compute_set(int on) { atomic_store(&g_m3_selective_compute,on<0?0:on>2?2:on); }
// Precise compute mode: an indirect buffer address that cannot be resolved makes
// this one encoder fall back to the full conservative declaration at dispatch.
void m3_use_compute_buffer(id encoder, id<MTLResource> buffer, MTLResourceUsage usage) {
    if([objc_getAssociatedObject(encoder,&g_m3_selective) intValue]!=2) return;
    if(buffer) [(id<MTLComputeCommandEncoder>)encoder useResource:buffer usage:usage];
    else {
        objc_setAssociatedObject(encoder,&g_m3_selective,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder,&g_m3_encoder_generation,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
void m3_encoder_compute_selective(id encoder) {
    objc_setAssociatedObject(encoder,&g_m3_selective,@2,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void m3_use_compute_resource(id encoder, id<MTLResource> resource, MTLResourceUsage usage) {
    if(resource && [objc_getAssociatedObject(encoder,&g_m3_selective) intValue]==2)
        [(id<MTLComputeCommandEncoder>)encoder useResource:resource usage:usage];
}

// 0: global RW; 1: global read plus precise writes; 2: only actual bindings.
void m3_selective_buffers_set(int mode) { if(mode>=0 && mode<=2)atomic_store(&g_m3_selective_buffers,mode); }
static int m3_selective_buffers_mode(void) {
    int mode=atomic_load_explicit(&g_m3_selective_buffers,memory_order_relaxed);
    if(mode<0) { const char *v=getenv("TOTK_M3_SELECTIVE_BUFFERS");int expected=-1,want=v?atoi(v):2;
        if(want<0||want>2)want=2;
        atomic_compare_exchange_strong(&g_m3_selective_buffers,&expected,want);
        mode=atomic_load(&g_m3_selective_buffers);
    }
    return mode;
}
void m3_encoder_full_buffers(id encoder) {
    objc_setAssociatedObject(encoder,&g_m3_buffer_readonly,@0,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder,&g_m3_encoder_generation,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
int m3_selective_textures_enabled(void) {
    int on=atomic_load_explicit(&g_m3_selective_on,memory_order_relaxed);
    if(on<0) { const char *v=getenv("TOTK_M3_SELECTIVE_TEXTURES");int expected=-1;
        atomic_compare_exchange_strong(&g_m3_selective_on,&expected,!v || strcmp(v,"0"));
        on=atomic_load(&g_m3_selective_on);
    }
    return on;
}
void m3_selective_textures_set(int on) { atomic_store(&g_m3_selective_on,on!=0); }

void m3_encoder_selective(id encoder) {
    objc_setAssociatedObject(encoder,&g_m3_buffer_readonly,@(m3_selective_buffers_mode()),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder,&g_m3_selective,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSObject *residency_lock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; g_m3_sets = [NSHashTable weakObjectsHashTable]; });
    return lock;
}
static void residency_changed(void) { atomic_fetch_add(&g_m3_resource_generation,1); g_m3_snapshot=nil; }
@implementation M3ResidencySet {
    NSHashTable *_resources;
}
- (instancetype)init {
    if ((self = [super init])) {
        _resources = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        @synchronized(residency_lock()) { [g_m3_sets addObject:self]; }
    }
    return self;
}
- (void)dealloc { @synchronized(residency_lock()) { [g_m3_sets removeObject:self]; residency_changed(); } }
- (void)addAllocation:(id<MTLResource>)r { if (r) @synchronized(residency_lock()) { if (![_resources containsObject:r]) { [_resources addObject:r]; residency_changed(); } } }
- (void)removeAllocation:(id<MTLResource>)r { if (r) @synchronized(residency_lock()) { if ([_resources containsObject:r]) { [_resources removeObject:r]; residency_changed(); } } }
- (NSArray *)snapshot { return _resources.allObjects; }
- (void)commit {}
@end
id m3_encoder_begin(id encoder) {
    if(encoder) {
        objc_setAssociatedObject(encoder,&g_m3_encoder_generation,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder,&g_m3_selective,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder,&g_m3_buffer_readonly,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}
void m3_encoder_direct_resources(id encoder) {
    objc_setAssociatedObject(encoder,&g_m3_selective,@3,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// Diagnostic: attribute global declarations to their call sites (TOTK_M3_DECL_STATS=1).
#import <execinfo.h>
#import <dlfcn.h>
typedef struct { void *pc[3]; uint64_t calls, entries; } M3DeclSite;
static M3DeclSite g_m3_decl_sites[64];
static os_unfair_lock g_m3_decl_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t g_m3_decl_last_ns;
static int m3_decl_stats_on(void) { static int on=-1; if(on<0){const char *v=getenv("TOTK_M3_DECL_STATS");on=v&&atoi(v);} return on; }
static void m3_decl_note(NSUInteger entries) {
    void *bt[6]; int n=backtrace(bt,6); M3DeclSite key={{n>2?bt[2]:0,n>3?bt[3]:0,n>4?bt[4]:0},0,0};
    os_unfair_lock_lock(&g_m3_decl_lock);
    int slot=-1;
    for(int i=0;i<64;i++){ if(!g_m3_decl_sites[i].calls){ if(slot<0)slot=i; continue; } if(!memcmp(g_m3_decl_sites[i].pc,key.pc,sizeof key.pc)){slot=i;break;} }
    if(slot>=0){ memcpy(g_m3_decl_sites[slot].pc,key.pc,sizeof key.pc); g_m3_decl_sites[slot].calls++; g_m3_decl_sites[slot].entries+=entries; }
    uint64_t now=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if(!g_m3_decl_last_ns) g_m3_decl_last_ns=now;
    if(now-g_m3_decl_last_ns>10000000000ull){
        double sec=(now-g_m3_decl_last_ns)/1e9; g_m3_decl_last_ns=now;
        for(int i=0;i<64;i++){ M3DeclSite *d=&g_m3_decl_sites[i]; if(!d->calls)continue;
            Dl_info a={0},b={0},c={0}; dladdr(d->pc[0],&a); dladdr(d->pc[1],&b); dladdr(d->pc[2],&c);
            fprintf(stderr,"[m3-decl] %.0f calls/s %.0f entries/s  %s <- %s <- %s\n",d->calls/sec,d->entries/sec,a.dli_sname?a.dli_sname:"?",b.dli_sname?b.dli_sname:"?",c.dli_sname?c.dli_sname:"?");
        }
        memset(g_m3_decl_sites,0,sizeof g_m3_decl_sites);
    }
    os_unfair_lock_unlock(&g_m3_decl_lock);
}
void m3_use_resident_resources(id encoder) {
    if (!encoder) return;
    if([objc_getAssociatedObject(encoder,&g_m3_selective) intValue]==3) return;
    // Only streamed render encoders may omit global buffers. Actual indirect
    // allocations are declared before each draw; direct Metal bindings track themselves.
    if([objc_getAssociatedObject(encoder,&g_m3_selective) intValue]==1 &&
       [objc_getAssociatedObject(encoder,&g_m3_buffer_readonly) intValue]==2) return;
    if([objc_getAssociatedObject(encoder,&g_m3_selective) intValue]==2 && m3_selective_compute_enabled()==2) return;
    uint64_t current=atomic_load_explicit(&g_m3_resource_generation,memory_order_acquire);
    if ([objc_getAssociatedObject(encoder,&g_m3_encoder_generation) unsignedLongLongValue]==current) return;
    M3ResourceSnapshot *snapshot;
    @synchronized(residency_lock()) {
        if(!g_m3_snapshot){
            NSMutableArray *resources=[NSMutableArray array];
            for(M3ResidencySet *set in g_m3_sets)[resources addObjectsFromArray:[set snapshot]];
            M3ResourceSnapshot *built=[M3ResourceSnapshot new];
            NSMutableArray *read=[NSMutableArray array],*write=[NSMutableArray array];
            for(id<MTLResource> resource in resources){
                BOOL readOnly=NO;
                if([resource conformsToProtocol:@protocol(MTLTexture)]){
                    MTLTextureUsage usage=[(id<MTLTexture>)resource usage];
                    readOnly=usage!=MTLTextureUsageUnknown&&!(usage&MTLTextureUsageShaderWrite);
                }
                [(readOnly?read:write) addObject:resource];
            }
            built->readCount=read.count;[read addObjectsFromArray:write];
            built->owners=[read copy];built->count=read.count;
            NSMutableArray *buffers=[NSMutableArray array];
            for(id r in read) if(![r conformsToProtocol:@protocol(MTLTexture)]) [buffers addObject:r];
            built->buffers=[buffers copy];
            built->bufferCount=buffers.count;
            built->bufferItems=(id<MTLResource> __unsafe_unretained *)calloc(built->bufferCount,sizeof(id));
            if(built->bufferCount&&!built->bufferItems){fprintf(stderr,"[m3] buffer snapshot allocation failed\n");abort();}
            for(NSUInteger i=0;i<built->bufferCount;i++)built->bufferItems[i]=built->buffers[i];
            built->generation=atomic_load(&g_m3_resource_generation);
            built->items=(id<MTLResource> __unsafe_unretained *)calloc(built->count,sizeof(id));
            if(built->count&&!built->items){fprintf(stderr,"[m3] resource snapshot allocation failed\n");abort();}
            for(NSUInteger i=0;i<built->count;i++)built->items[i]=built->owners[i];
            g_m3_snapshot=built;
        }
        snapshot=g_m3_snapshot;
    }
    // Only streamed game passes opt in. Other encoders retain full residency declarations.
    if ([objc_getAssociatedObject(encoder,&g_m3_selective) boolValue]) {
        if(m3_decl_stats_on()) m3_decl_note(snapshot->bufferCount);
        if(snapshot->bufferCount) {
            if([objc_getAssociatedObject(encoder,&g_m3_selective) intValue]==2)
                [(id<MTLComputeCommandEncoder>)encoder useResources:snapshot->bufferItems count:snapshot->bufferCount usage:MTLResourceUsageRead|MTLResourceUsageWrite];
            else [encoder useResources:snapshot->bufferItems count:snapshot->bufferCount usage:([objc_getAssociatedObject(encoder,&g_m3_buffer_readonly) boolValue]?MTLResourceUsageRead:MTLResourceUsageRead|MTLResourceUsageWrite) stages:MTLRenderStageVertex|MTLRenderStageFragment];
        }
        objc_setAssociatedObject(encoder,&g_m3_encoder_generation,@(snapshot->generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    // Render encoders use the stages-aware API so tracked indirect resources get hazard protection.
    BOOL render=[encoder respondsToSelector:@selector(useResources:count:usage:stages:)];
    if(m3_decl_stats_on()) m3_decl_note(snapshot->count);
    if(snapshot->readCount){
        if(render)[encoder useResources:snapshot->items count:snapshot->readCount usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];
        else [encoder useResources:snapshot->items count:snapshot->readCount usage:MTLResourceUsageRead];
    }
    NSUInteger writable=snapshot->count-snapshot->readCount;
    if(writable){
        if(render)[encoder useResources:snapshot->items+snapshot->readCount count:writable usage:MTLResourceUsageRead|MTLResourceUsageWrite stages:MTLRenderStageVertex|MTLRenderStageFragment];
        else [encoder useResources:snapshot->items+snapshot->readCount count:writable usage:MTLResourceUsageRead|MTLResourceUsageWrite];
    }
    objc_setAssociatedObject(encoder,&g_m3_encoder_generation,@(snapshot->generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---------------------------------------------------------------------------
// GPU 地址 → MTLBuffer 反查表
// ---------------------------------------------------------------------------
typedef struct { uint64_t gpu, len; __unsafe_unretained id<MTLBuffer> buf; } M3BufferEntry;
static M3BufferEntry *g_m3_bufs;
static NSUInteger g_m3_nbufs, g_m3_buf_capacity;
static os_unfair_lock g_m3_lk = OS_UNFAIR_LOCK_INIT;

void m3_buf_add(id<MTLBuffer> b) {
    if (!b) return;
    os_unfair_lock_lock(&g_m3_lk);
    for (NSUInteger i=0;i<g_m3_nbufs;i++) if(g_m3_bufs[i].buf==b) {
        os_unfair_lock_unlock(&g_m3_lk); return;
    }
    if(g_m3_nbufs==g_m3_buf_capacity) {
        NSUInteger capacity=g_m3_buf_capacity ? g_m3_buf_capacity*2 : M3_INITIAL_BUF_CAPACITY;
        if(capacity<g_m3_buf_capacity || capacity>SIZE_MAX/sizeof(M3BufferEntry)) {
            fprintf(stderr,"[m3] buffer registry size overflow\n"); abort();
        }
        M3BufferEntry *grown=realloc(g_m3_bufs,capacity*sizeof(*grown));
        if(!grown) { fprintf(stderr,"[m3] cannot grow buffer registry to %lu entries\n",(unsigned long)capacity); abort(); }
        g_m3_bufs=grown;g_m3_buf_capacity=capacity;
        fprintf(stderr,"[m3] buffer registry capacity=%lu live=%lu\n",(unsigned long)capacity,(unsigned long)g_m3_nbufs);
    }
    g_m3_bufs[g_m3_nbufs++]=(M3BufferEntry){b.gpuAddress,b.length,b};
    os_unfair_lock_unlock(&g_m3_lk);
}

void m3_buf_del(id<MTLBuffer> b) {
    if (!b) return;
    os_unfair_lock_lock(&g_m3_lk);
    for (NSUInteger i = 0; i < g_m3_nbufs; i++)
        if (g_m3_bufs[i].buf == b) { g_m3_bufs[i] = g_m3_bufs[--g_m3_nbufs]; break; }
    os_unfair_lock_unlock(&g_m3_lk);
}

// 最近命中的那一项先试：同一通道里的绑定几乎都落在同一两个缓冲上
// Try the most recently hit entry first: bindings within one pass almost always land on the same one or two buffers.
id<MTLBuffer> m3_buf(uint64_t gpu, NSUInteger *off) {
    static _Thread_local NSUInteger last;
    id<MTLBuffer> r = nil;
    *off = 0;
    if (!gpu) return nil;
    os_unfair_lock_lock(&g_m3_lk);
    NSInteger i = (last < g_m3_nbufs && gpu >= g_m3_bufs[last].gpu && gpu - g_m3_bufs[last].gpu < g_m3_bufs[last].len) ? (NSInteger)last : -1;
    for (NSUInteger k = 0; i < 0 && k < g_m3_nbufs; k++)
        if (gpu >= g_m3_bufs[k].gpu && gpu - g_m3_bufs[k].gpu < g_m3_bufs[k].len) i = k;
    if (i >= 0) { last = i; r = g_m3_bufs[i].buf; *off = (NSUInteger)(gpu - g_m3_bufs[i].gpu); }
    os_unfair_lock_unlock(&g_m3_lk);
    return r;
}

// ---------------------------------------------------------------------------
// 当前编码器（供时间戳采样用；Metal 3 的计数采样挂在编码器上而不是命令缓冲上）
// Current encoder (for counter sampling: Metal 3 samples on an encoder, not on a command buffer).
// ---------------------------------------------------------------------------
static __unsafe_unretained id g_m3_cur_enc;

void m3_set_cur_enc(id enc) { g_m3_cur_enc = enc; }

// ---------------------------------------------------------------------------
// 参数表
// ---------------------------------------------------------------------------
@implementation M3ArgTableDescriptor
@end

static int g_m3_red_bound;   // 未登记地址只报一次红，避免刷屏 | report an unregistered address once

@implementation M3ArgTable

- (void)setAddress:(uint64_t)gpu atIndex:(NSUInteger)i {
    NSUInteger off = 0;
    id<MTLBuffer> b = m3_buf(gpu, &off);
    if (gpu && !b) {
        if (!g_m3_red_bound++) fprintf(stderr, "[dm] [m3] 【红】绑定：显卡地址 %#llx 不在任何登记过的缓冲里（槽 %lu）\n",
                                       (unsigned long long)gpu, (unsigned long)i);
        return;
    }
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexBuffer:b offset:off atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentBuffer:b offset:off atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setBuffer:b offset:off atIndex:i]; break;
    }
}

- (void)setTexture:(id<MTLTexture>)tex atIndex:(NSUInteger)i {
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexTexture:tex atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentTexture:tex atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setTexture:tex atIndex:i]; break;
    }
}

- (void)setSamplerState:(id<MTLSamplerState>)smp atIndex:(NSUInteger)i {
    switch (_stage) {
        case M3_STAGE_VERTEX:   [(id<MTLRenderCommandEncoder>)_enc setVertexSamplerState:smp atIndex:i]; break;
        case M3_STAGE_FRAGMENT: [(id<MTLRenderCommandEncoder>)_enc setFragmentSamplerState:smp atIndex:i]; break;
        default:                [(id<MTLComputeCommandEncoder>)_enc setSamplerState:smp atIndex:i]; break;
    }
}

@end

void m3_attach(M3ArgTable *t, id enc, int stage) {
    m3_use_resident_resources(enc);
    t.enc = enc;
    t.stage = stage;
}

// ---------------------------------------------------------------------------
// GPU 时间戳
// ---------------------------------------------------------------------------
@implementation M3CounterHeapDescriptor
@end

@implementation M3CounterHeap {
    id<MTLCounterSampleBuffer> _sb;
}

- (instancetype)initWithDevice:(id<MTLDevice>)dev count:(NSUInteger)count {
    if ((self = [super init])) {
        id<MTLCounterSet> set = nil;
        for (id<MTLCounterSet> cs in [dev counterSets])
            if ([[cs name] isEqualToString:MTLCommonCounterSetTimestamp]) { set = cs; break; }
        if (!set) { fprintf(stderr, "[dm] [m3] 【红】设备没有 timestamp 计数器集\n"); return self; }
        MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
        d.counterSet = set;
        d.sampleCount = count;
        d.storageMode = MTLStorageModeShared;
        NSError *e = nil;
        _sb = [dev newCounterSampleBufferWithDescriptor:d error:&e];
        if (!_sb) fprintf(stderr, "[dm] [m3] 【红】建立计数器采样缓冲失败：%s\n", e.localizedDescription.UTF8String);
    }
    return self;
}

- (id<MTLCounterSampleBuffer>)sampleBuffer { return _sb; }

- (NSData *)resolveCounterRange:(NSRange)r { return [_sb resolveCounterRange:r]; }

@end

// 在「当前编码器」上采一个时间戳；Metal 3 没有命令缓冲级别的写法
// Sample one timestamp on the current encoder; Metal 3 has no command-buffer-level form.
void m3_timestamp(M3CounterHeap *h, NSUInteger i) {
    if (!h || !g_m3_cur_enc) return;
    id<MTLCounterSampleBuffer> sb = [h sampleBuffer];
    if (!sb) return;
    id e = g_m3_cur_enc;
    if ([e conformsToProtocol:@protocol(MTLRenderCommandEncoder)])
        [(id<MTLRenderCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
    else if ([e conformsToProtocol:@protocol(MTLComputeCommandEncoder)])
        [(id<MTLComputeCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
    else if ([e conformsToProtocol:@protocol(MTLBlitCommandEncoder)])
        [(id<MTLBlitCommandEncoder>)e sampleCountersInBuffer:sb atSampleIndex:i withBarrier:NO];
}

// ---------------------------------------------------------------------------
// 提交回调
// ---------------------------------------------------------------------------
@implementation M3CommitFeedback
+ (instancetype)withCommandBuffer:(id<MTLCommandBuffer>)cb {
    M3CommitFeedback *f = [M3CommitFeedback new];
    f->_GPUStartTime = cb.GPUStartTime;
    f->_GPUEndTime = cb.GPUEndTime;
    f->_error = cb.error;
    return f;
}
@end

void m3_commit(id<MTLCommandBuffer> cb, M3CommitOptions *o) {
    if (!cb) return;
    if (o.handlers.count) {
        NSArray *hs = [o.handlers copy];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            M3CommitFeedback *fb = [M3CommitFeedback withCommandBuffer:c];
            for (M3CommitFeedbackHandler h in hs) h(fb);
        }];
    }
    [cb commit];
    /* 判定用：TOTK_M3_SYNC_PRESENT=1 时每次提交后等 GPU 完成，排除 drawable 重叠使用时序 */
    /* Diagnostic: with TOTK_M3_SYNC_PRESENT=1 wait for the GPU after every commit, to rule out drawable overlap. */
    static int syncp = -1;
    if (syncp < 0) syncp = getenv("TOTK_M3_SYNC_PRESENT") != NULL;
    if (syncp) [cb waitUntilCompleted];
}

@implementation M3CommitOptions

- (void)addFeedbackHandler:(M3CommitFeedbackHandler)block {
    if (!_handlers) _handlers = [NSMutableArray array];
    if (block) [_handlers addObject:[block copy]];
}

@end

// ---------------------------------------------------------------------------
// 命令分配器 / 队列描述符（Metal 3 无对应概念，只承接属性赋值）
// ---------------------------------------------------------------------------
@implementation M3CommandAllocatorDescriptor
@end
@implementation M3CommandAllocator
@end
@implementation M3CommandQueueDescriptor
@end

// ---------------------------------------------------------------------------
// 着色器编译
// ---------------------------------------------------------------------------
@implementation M3CompilerDescriptor
@end

@implementation M3Compiler {
    id<MTLDevice> _dev;
}

- (instancetype)initWithDevice:(id<MTLDevice>)dev {
    if ((self = [super init])) _dev = dev;
    return self;
}

- (id<MTLLibrary>)newLibraryWithSource:(NSString *)src options:(MTLCompileOptions *)opts error:(NSError **)err {
    return [_dev newLibraryWithSource:src options:opts error:err];
}

@end

void m3_draw_indexed(id enc, MTLPrimitiveType p, NSUInteger n, MTLIndexType t,
                     uint64_t gpu, NSUInteger len, NSUInteger inst, NSInteger baseV, NSUInteger baseI) {
    m3_use_resident_resources(enc);
    (void)len;
    if (!n) return;
    NSUInteger off = 0;
    id<MTLBuffer> b = m3_buf(gpu, &off);
    if (!b) return;
    [(id<MTLRenderCommandEncoder>)enc drawIndexedPrimitives:p indexCount:n indexType:t
                                                indexBuffer:b indexBufferOffset:off
                                              instanceCount:inst baseVertex:baseV baseInstance:baseI];
}

#endif /* DM_NVN_M3 */
