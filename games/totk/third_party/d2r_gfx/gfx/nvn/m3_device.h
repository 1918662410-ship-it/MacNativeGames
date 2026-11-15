#pragma once
#import <Metal/Metal.h>
#if DM_NVN_M3
// Shared by the window and renderer so both use the same GPU.
id<MTLDevice> m3_default_device(void);
#endif
