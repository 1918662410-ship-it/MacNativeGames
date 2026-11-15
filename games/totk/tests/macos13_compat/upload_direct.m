// Exercise the real upload kernel with no global residency declarations.
#import <Foundation/Foundation.h>
#import "m3_compat.h"
#import "../tex/nvn_deswizzle_gpu.h"
#include "nvn.h"
#define CHECK(x) do {if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void) { @autoreleasepool {
 id<MTLDevice> dev=m3_default_device();CHECK(dev);CHECK(nvn_deswz_gpu_init(dev)==0);
 id<MTLCommandQueue> queue=[dev newCommandQueue];M3ArgTable *table=[M3ArgTable new];
 M3ResidencySet *resident=[M3ResidencySet new];
 [resident addAllocation:[dev newBufferWithLength:16384 options:MTLResourceStorageModeShared]];
 for(int mode=0;mode<2;mode++) for(int variant=0;variant<4;variant++) {
  nvn_texdesc d={.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=67,.height=35,.depth=1,.levels=3};
  unsigned level=variant==1?1:0,layer=0;
  if(variant==2){d.target=NVN_TEXTURE_TARGET_2D_ARRAY;d.depth=3;layer=2;d.format=NVN_FORMAT_RGBA_DXT5;}
  if(variant==3){d.target=NVN_TEXTURE_TARGET_3D;d.depth=5;}
  nvn_texlayout layout;nvn_tex_layout(&d,&layout);
  uint32_t row,rows,slices,bpb;uint64_t base;unsigned th,td;
  CHECK(nvn_deswizzle_geom(&d,level,layer,&row,&rows,&slices,&base,&th,&td,&bpb)==0);
  size_t pitch=(row+31)&~31u,n=pitch*rows*slices;
  id<MTLBuffer> src=[dev newBufferWithLength:layout.size+256 options:MTLResourceStorageModeShared];
  id<MTLBuffer> dst=[dev newBufferWithLength:n+256 options:MTLResourceStorageModeShared];
  id<MTLBuffer> params=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
  CHECK(src&&dst&&params);m3_buf_add(src);m3_buf_add(dst);m3_buf_add(params);
  [resident addAllocation:src];[resident addAllocation:dst];[resident addAllocation:params];
  for(size_t i=0;i<src.length;i++)((uint8_t*)src.contents)[i]=(uint8_t)((i*37u)^(i>>7));
  memset(dst.contents,0xcd,dst.length);uint8_t *expected=malloc(n);CHECK(expected);memset(expected,0xcd,n);
  CHECK(nvn_deswizzle(&d,level,layer,(uint8_t*)src.contents+128,expected,pitch)==0);
  id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=m3_encoder_begin([cb computeCommandEncoder]);
  if(mode)m3_encoder_direct_resources(e);
  CHECK(nvn_deswz_gpu_encode_m4((id<MTL4ComputeCommandEncoder>)e,table,params,64,src,128,&d,level,layer,dst,128,pitch)==0);[e endEncoding];
  // A later blit must observe the compute writes through ordinary Metal tracking.
  id<MTLBuffer> copy=[dev newBufferWithLength:n options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit copyFromBuffer:dst sourceOffset:128 toBuffer:copy destinationOffset:0 size:n];[blit endEncoding];
  [cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
  CHECK(!memcmp(copy.contents,expected,n));for(int i=0;i<128;i++){CHECK(((uint8_t*)dst.contents)[i]==0xcd);CHECK(((uint8_t*)dst.contents)[n+128+i]==0xcd);}
  printf("PASS mode=%d variant=%d bytes=%zu CPU/GPU match, offsets and guards intact\n",mode,variant,n);
  free(expected);m3_buf_del(src);m3_buf_del(dst);m3_buf_del(params);
  [resident removeAllocation:src];[resident removeAllocation:dst];[resident removeAllocation:params];
 }
}return 0;}
