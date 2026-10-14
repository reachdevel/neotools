#include "cvorbis.h"
#include <stdlib.h>
#include <string.h>
#include "vorbis/codec.h"

struct neo_vorbis {
    vorbis_info info;
    vorbis_comment comment;
    vorbis_dsp_state dsp;
    vorbis_block block;
    int ready;
    int64_t packets;
};

static int header(neo_vorbis *d, const uint8_t *p, size_t n, int first) {
    ogg_packet op;
    memset(&op, 0, sizeof op);
    op.packet = (unsigned char *)p;
    op.bytes = (long)n;
    op.b_o_s = first;
    op.packetno = d->packets++;
    return vorbis_synthesis_headerin(&d->info, &d->comment, &op);
}

neo_vorbis *neo_vorbis_open(const uint8_t *id, size_t idSize, const uint8_t *comment, size_t commentSize, const uint8_t *setup, size_t setupSize,
                            int *channels, long *sampleRate) {
    neo_vorbis *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    vorbis_info_init(&d->info);
    vorbis_comment_init(&d->comment);
    if (header(d, id, idSize, 1) != 0 || header(d, comment, commentSize, 0) != 0 || header(d, setup, setupSize, 0) != 0 ||
        vorbis_synthesis_init(&d->dsp, &d->info) != 0 || vorbis_block_init(&d->dsp, &d->block) != 0) {
        vorbis_comment_clear(&d->comment);
        vorbis_info_clear(&d->info);
        free(d);
        return NULL;
    }
    d->ready = 1;
    *channels = d->info.channels;
    *sampleRate = d->info.rate;
    return d;
}

void neo_vorbis_close(neo_vorbis *d) {
    if (!d) return;
    if (d->ready) { vorbis_block_clear(&d->block); vorbis_dsp_clear(&d->dsp); }
    vorbis_comment_clear(&d->comment);
    vorbis_info_clear(&d->info);
    free(d);
}

int neo_vorbis_packet(neo_vorbis *d, const uint8_t *data, size_t size) {
    ogg_packet op;
    memset(&op, 0, sizeof op);
    op.packet = (unsigned char *)data;
    op.bytes = (long)size;
    op.granulepos = -1;
    op.packetno = d->packets++;
    if (vorbis_synthesis(&d->block, &op) != 0) return -1;
    return vorbis_synthesis_blockin(&d->dsp, &d->block) == 0 ? 0 : -1;
}

int neo_vorbis_read(neo_vorbis *d, float *out, int maxFrames) {
    float **pcm = NULL;
    int frames = vorbis_synthesis_pcmout(&d->dsp, &pcm);
    if (frames <= 0) return 0;
    if (frames > maxFrames) frames = maxFrames;
    int channels = d->info.channels;
    for (int i = 0; i < frames; i++) for (int c = 0; c < channels; c++) out[i * channels + c] = pcm[c][i];
    vorbis_synthesis_read(&d->dsp, frames);
    return frames;
}
