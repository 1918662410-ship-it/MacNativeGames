#include "nvn_resource_use_cache.h"
#include <assert.h>
#include <stdio.h>
static nvn_resource_use_cache cache;
int main(void) {
 assert(nvn_resource_use_emit(&cache,16,1,1,1));
 assert(!nvn_resource_use_emit(&cache,16,1,1,1));
 assert(nvn_resource_use_emit(&cache,16,1,3,1)); /* read -> write must emit */
 assert(!nvn_resource_use_emit(&cache,16,1,1,1));
 assert(nvn_resource_use_emit(&cache,16,1,1,0)); /* new stage must emit */
 assert(nvn_resource_use_emit(&cache,16,2,1,1)); /* new pass must emit */
 for(uintptr_t i=1;i<=NVN_RESOURCE_USE_SLOTS+3;i++)assert(nvn_resource_use_emit(&cache,i*32,3,1,0));
 assert(nvn_resource_use_emit(&cache,0x7ffffffff000ull,3,3,1)); /* full table */
 assert(nvn_resource_use_emit(&cache,16,4,1,1));
 puts("PASS resource declarations: duplicate, write escalation, stage, pass, collision and saturation fallback");
}
