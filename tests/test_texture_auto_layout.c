/* Independent golden metadata: original SDK CPU queries for uncompressed and
 * BC3-sRGB boundary cases. No game bytes are included. The old rounded-up
 * heuristic mismatches 16 of these 40 cases, including the 160x160 shrine pad. */
#include "nvn_tex.h"
#include "nvn_deswizzle.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct { unsigned format,width,height,levels,h; uint64_t size; } Case;
static const Case cases[] = {
    {0x25,40,1,6,0,4608},
    {0x25,40,8,6,0,4608},
    {0x25,40,9,6,0,6144},
    {0x25,40,10,6,0,6144},
    {0x25,40,11,6,1,6144},
    {0x25,40,16,6,1,6144},
    {0x25,40,17,6,1,9216},
    {0x25,40,21,6,1,10240},
    {0x25,40,22,6,2,10240},
    {0x25,40,32,6,2,10240},
    {0x25,40,33,6,2,16384},
    {0x25,40,40,6,2,18944},
    {0x25,40,42,6,2,18944},
    {0x25,40,43,6,3,18944},
    {0x25,40,64,7,3,19456},
    {0x25,40,65,7,3,31744},
    {0x25,40,85,7,3,37376},
    {0x25,40,86,7,4,37376},
    {0x25,40,128,8,4,37888},
    {0x25,40,129,8,4,62464},
    {0x48,160,4,8,0,12288},
    {0x48,160,32,8,0,12288},
    {0x48,160,36,8,0,17408},
    {0x48,160,40,8,0,17408},
    {0x48,160,44,8,1,17408},
    {0x48,160,64,8,1,17408},
    {0x48,160,68,8,1,30208},
    {0x48,160,84,8,1,30208},
    {0x48,160,88,8,2,30208},
    {0x48,160,128,8,2,30208},
    {0x48,160,132,8,2,57344},
    {0x48,160,160,8,2,57344},
    {0x48,160,168,8,2,57344},
    {0x48,160,172,8,3,57344},
    {0x48,160,256,9,3,57856},
    {0x48,160,260,9,3,112128},
    {0x48,160,340,9,3,113152},
    {0x48,160,344,9,4,113152},
    {0x48,160,512,10,4,113664},
    {0x48,160,516,10,4,222208},
};
static void check(int ok,const char *message) { if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
int main(void) {
    for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        const Case *c=&cases[i];
        nvn_texdesc d={.target=1,.format=(int)c->format,.samples=1,.width=c->width,.height=c->height,.depth=1,.levels=c->levels};
        nvn_texlayout l;nvn_tex_layout(&d,&l);
        if(l.tileH!=c->h || l.size!=c->size){fprintf(stderr,"case %u format=%#x %ux%u: H=%u expected=%u size=%llu expected=%llu\n",i,c->format,c->width,c->height,l.tileH,c->h,(unsigned long long)l.size,(unsigned long long)c->size);return 1;}
    }
    nvn_texdesc pad={.target=1,.format=0x48,.samples=1,.width=160,.height=160,.depth=1,.levels=8};
    unsigned h,d;nvn_tex_level_tiles(&pad,0,&h,&d);
    check(h==2 && d==0,"160x160 BC3 base mip uses four-GOB blocks");
    check(nvn_bl_offset(320,0,0,640,40,h,d)==10240,"right-half material block comes from the correct GOB column");
    check(nvn_bl_offset(624,39,0,640,40,h,d)==39408,"last real BC3 block precedes padding");
    pad.pkg_block_h=4;nvn_tex_level_tiles(&pad,0,&h,&d);
    check(h==3,"explicit packaged H3 overrides automatic H2");
    check(nvn_bl_offset(320,0,0,640,40,h,d)==20480,"explicit layout preserves its own addressing");
    puts("PASS: 40 original-SDK layout goldens, shrine BC3 block addresses, explicit-layout override.");
    return 0;
}
