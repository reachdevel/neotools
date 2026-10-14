#include "cdav1d.h"
#include <stdlib.h>
#include <errno.h>
#include "dav1d/dav1d.h"

struct neo_av1 {
    Dav1dContext *ctx;
    Dav1dPicture picture;
    int havePicture;
    Dav1dData data;
    int haveData;
};

neo_av1 *neo_av1_open(int threads) {
    neo_av1 *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    Dav1dSettings s;
    dav1d_default_settings(&s);
    s.n_threads = threads > 0 ? threads : 1;
    s.max_frame_delay = 1;
    if (dav1d_open(&d->ctx, &s) < 0) { free(d); return NULL; }
    return d;
}

void neo_av1_close(neo_av1 *d) {
    if (!d) return;
    if (d->havePicture) dav1d_picture_unref(&d->picture);
    if (d->haveData) dav1d_data_unref(&d->data);
    if (d->ctx) dav1d_close(&d->ctx);
    free(d);
}

int neo_av1_send(neo_av1 *d, const uint8_t *data, size_t size, int64_t timestamp) {
    if (d->haveData) { dav1d_data_unref(&d->data); d->haveData = 0; }
    uint8_t *buffer = dav1d_data_create(&d->data, size);
    if (!buffer) return -1;
    for (size_t i = 0; i < size; i++) buffer[i] = data[i];
    d->data.m.timestamp = timestamp;
    d->haveData = 1;
    return 0;
}

int neo_av1_next(neo_av1 *d, neo_av1_image *out) {
    if (d->havePicture) { dav1d_picture_unref(&d->picture); d->havePicture = 0; }
    // give the pending packet to the decoder first
    while (d->haveData && d->data.sz > 0) {
        int r = dav1d_send_data(d->ctx, &d->data);
        if (r < 0 && r != DAV1D_ERR(EAGAIN)) { dav1d_data_unref(&d->data); d->haveData = 0; return -1; }
        if (r == DAV1D_ERR(EAGAIN)) break;                   // the decoder wants its pictures taken first
    }
    int r = dav1d_get_picture(d->ctx, &d->picture);
    if (r == DAV1D_ERR(EAGAIN)) return 0;
    if (r < 0) return -1;
    d->havePicture = 1;
    Dav1dPicture *p = &d->picture;
    out->width = p->p.w;
    out->height = p->p.h;
    out->bitDepth = p->p.bpc;
    out->layout = (int)p->p.layout;
    out->fullRange = p->seq_hdr ? p->seq_hdr->color_range : 0;
    out->matrix = p->seq_hdr ? (int)p->seq_hdr->mtrx : 2;
    out->timestamp = p->m.timestamp;
    out->plane[0] = p->data[0]; out->plane[1] = p->data[1]; out->plane[2] = p->data[2];
    out->stride[0] = (int)p->stride[0]; out->stride[1] = (int)p->stride[1]; out->stride[2] = (int)p->stride[1];
    return 1;
}

void neo_av1_flush(neo_av1 *d) { (void)d; }
