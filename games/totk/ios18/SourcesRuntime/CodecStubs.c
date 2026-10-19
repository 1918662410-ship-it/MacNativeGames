typedef struct vpx_codec_ctx vpx_codec_ctx_t;
typedef struct vpx_codec_iface vpx_codec_iface_t;
typedef struct vpx_image vpx_image_t;

/* libopus is linked from Vendor/libopus-ios.a. libvpx remains a stub until the
   movie path is ported; the game boot/title does not need it. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

int vpx_codec_dec_init_ver(vpx_codec_ctx_t *ctx, vpx_codec_iface_t *iface, const void *cfg, unsigned long flags, int ver) {
    (void)ctx; (void)iface; (void)cfg; (void)flags; (void)ver; return -1;
}
int vpx_codec_decode(vpx_codec_ctx_t *ctx, const uint8_t *data, size_t len, void *user_priv, unsigned long deadline) {
    (void)ctx; (void)data; (void)len; (void)user_priv; (void)deadline; return -1;
}
int vpx_codec_destroy(vpx_codec_ctx_t *ctx) { (void)ctx; return -1; }
const char *vpx_codec_err_to_string(int err) { (void)err; return "vpx stub"; }
const char *vpx_codec_error_detail(vpx_codec_ctx_t *ctx) { (void)ctx; return "vpx stub"; }
vpx_image_t *vpx_codec_get_frame(vpx_codec_ctx_t *ctx, void **iter) { (void)ctx; (void)iter; return NULL; }
const char *vpx_codec_version_str(void) { return "vpx stub"; }
vpx_codec_iface_t *vpx_codec_vp9_dx(void) { return NULL; }
