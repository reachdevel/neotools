#include "cvpx.h"
#include <stdlib.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

struct neo_vpx {
    vpx_codec_ctx_t codec;
    vpx_codec_iter_t iter;
    int open;
};

neo_vpx *neo_vpx_open(int vp9) {
    neo_vpx *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    vpx_codec_dec_cfg_t cfg = { 1, 0, 0 };
    vpx_codec_iface_t *iface = vp9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx();
    if (vpx_codec_dec_init(&d->codec, iface, &cfg, 0) != VPX_CODEC_OK) { free(d); return NULL; }
    d->open = 1;
    return d;
}

void neo_vpx_close(neo_vpx *d) {
    if (!d) return;
    if (d->open) vpx_codec_destroy(&d->codec);
    free(d);
}

int neo_vpx_decode(neo_vpx *d, const uint8_t *data, size_t size) {
    d->iter = NULL;
    return vpx_codec_decode(&d->codec, data, (unsigned int)size, NULL, 0) == VPX_CODEC_OK ? 0 : -1;
}

int neo_vpx_next(neo_vpx *d, neo_vpx_image *out) {
    vpx_image_t *img = vpx_codec_get_frame(&d->codec, &d->iter);
    if (!img) return 0;
    out->width = (int)img->d_w;
    out->height = (int)img->d_h;
    out->bitDepth = (int)img->bit_depth;
    out->colorSpace = (int)img->cs;
    out->fullRange = img->range == VPX_CR_FULL_RANGE ? 1 : 0;
    out->chromaShiftX = (int)img->x_chroma_shift;
    out->chromaShiftY = (int)img->y_chroma_shift;
    for (int i = 0; i < 3; i++) { out->plane[i] = img->planes[i]; out->stride[i] = img->stride[i]; }
    return 1;
}
