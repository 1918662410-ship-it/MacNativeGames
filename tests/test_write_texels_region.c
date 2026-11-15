#include "../games/totk/third_party/d2r_gfx/gfx/tex/nvn_deswizzle.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach_time.h>
int main(void){
  int fmts[64],nf=0; for(int f=1;f<200&&nf<64;f++){int bw,bh; if(nvn_fmt_bpb(f,&bw,&bh)) fmts[nf++]=f;}
  srand(7); long checks=0;
  for(int it=0;it<3000;it++){
    nvn_texdesc d={0}; d.format=fmts[rand()%nf]; int tg=rand()%3; d.target=tg==0?1:tg==1?2:8; /* 2D, 3D, 2D array */
    d.width=1+rand()%300; d.height=1+rand()%300; d.depth=d.target==1?1:1+rand()%5; d.levels=1+rand()%4; d.samples=0;
    if(it%7==0){d.target=1;d.depth=1;d.flags=(it%14)?0x10:0x40;d.levels=1;}
    int bw,bh,bpb=nvn_fmt_bpb(d.format,&bw,&bh); nvn_texlayout L; nvn_tex_layout(&d,&L);
    unsigned level=rand()%d.levels; unsigned layer=d.target==8?rand()%d.depth:0;
    uint32_t rb,rows,sl,b2; uint64_t base; unsigned th,td;
    if(!nvn_tex_is_linear(&d)){ if(nvn_deswizzle_geom(&d,level,layer,&rb,&rows,&sl,&base,&th,&td,&b2)) continue; }
    else { rb=(d.width+bw-1)/bw*bpb; rows=(d.height+bh-1)/bh; sl=1; }
    uint8_t *A=malloc(L.size+64),*B=malloc(L.size+64); for(uint64_t i=0;i<L.size;i++)A[i]=rand(); memcpy(B,A,L.size);
    uint32_t xb0=(rand()%(rb/bpb))*bpb, y0=rand()%rows, wb=(1+rand()%((rb-xb0)/bpb))*bpb, hb=1+rand()%(rows-y0), z=rand()%sl;
    size_t pitch=wb+(rand()%3)*bpb; uint8_t *src=malloc(pitch*hb); for(size_t i=0;i<pitch*hb;i++)src[i]=rand();
    /* reference: full round trip */
    uint8_t *lin=malloc((size_t)rb*rows*sl);
    if(nvn_deswizzle(&d,level,layer,A,lin,rb)){free(A);free(B);free(src);free(lin);continue;}
    for(uint32_t y=0;y<hb;y++)memcpy(lin+((size_t)z*rows+y0+y)*rb+xb0,src+y*pitch,wb);
    if(nvn_swizzle(&d,level,layer,lin,rb,A)){printf("FAIL swizzle\n");return 1;}
    if(nvn_swizzle_region(&d,level,layer,z,xb0,y0,wb,hb,src,pitch,B)){printf("FAIL region rc it=%d\n",it);return 1;}
    if(memcmp(A,B,L.size)){printf("FAIL mismatch it=%d fmt=%d tgt=%d %ux%ux%u lv%u\n",it,d.format,d.target,d.width,d.height,d.depth,level);return 1;}
    checks++; free(A);free(B);free(src);free(lin);
  }
  /* timing: 2048x2048 RGBA8-like 4 bpb, 64x64 region */
  nvn_texdesc d={0}; d.target=1; d.width=d.height=2048; d.depth=1; d.levels=1; int f4=0; for(int i=0;i<nf;i++){int bw,bh; if(nvn_fmt_bpb(fmts[i],&bw,&bh)==4&&bw==1){f4=fmts[i];break;}} d.format=f4;
  nvn_texlayout L; nvn_tex_layout(&d,&L); uint8_t *M=calloc(1,L.size),*lin=malloc(2048*2048*4),*src=calloc(1,64*64*4);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); uint64_t t0=mach_absolute_time();
  nvn_deswizzle(&d,0,0,M,lin,2048*4); nvn_swizzle(&d,0,0,lin,2048*4,M); uint64_t t1=mach_absolute_time();
  nvn_swizzle_region(&d,0,0,0,512,512,256,64,src,256,M); uint64_t t2=mach_absolute_time();
  printf("PASS %ld region checks; %llu-byte texture: full round trip %.2f ms, 64x64 region %.4f ms\n",checks,(unsigned long long)L.size,(t1-t0)*(double)tb.numer/tb.denom/1e6,(t2-t1)*(double)tb.numer/tb.denom/1e6);
  return 0;}
