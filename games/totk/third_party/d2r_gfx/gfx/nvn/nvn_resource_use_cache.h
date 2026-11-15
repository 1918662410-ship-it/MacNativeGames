#ifndef NVN_RESOURCE_USE_CACHE_H
#define NVN_RESOURCE_USE_CACHE_H
#include <stdint.h>
#include <stddef.h>
/* Producer-owned cache. Suppress only declarations already made in this pass,
   with the same shader stage and at least the requested access permissions.
   Saturation falls back to emitting, never to dropping a declaration. */
#define NVN_RESOURCE_USE_SLOTS 4096u
typedef struct { uintptr_t resource; uint64_t pass; uint32_t permissions; } nvn_resource_use_entry;
typedef struct { nvn_resource_use_entry entries[NVN_RESOURCE_USE_SLOTS]; } nvn_resource_use_cache;
static inline int nvn_resource_use_emit(nvn_resource_use_cache *cache, uintptr_t resource,
                                       uint64_t pass, uint32_t usage, int vertex) {
    uint32_t permissions=usage << (vertex ? 0 : 8);
    size_t slot=((resource>>4)^(resource>>17))&(NVN_RESOURCE_USE_SLOTS-1);
    for(size_t n=0;n<NVN_RESOURCE_USE_SLOTS;n++,slot=(slot+1)&(NVN_RESOURCE_USE_SLOTS-1)) {
        nvn_resource_use_entry *e=&cache->entries[slot];
        if(e->pass!=pass || !e->resource) { *e=(nvn_resource_use_entry){resource,pass,permissions};return 1; }
        if(e->resource==resource) {
            if((e->permissions&permissions)==permissions)return 0;
            e->permissions|=permissions;return 1;
        }
    }
    return 1;
}
#endif
