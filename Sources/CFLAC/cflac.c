#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#include "dr_flac.h"
#include "cflac.h"

typedef struct { neo_flac_read_fn read; neo_flac_seek_fn seek; neo_flac_tell_fn tell; void *user; } neo_flac_io;
struct neo_flac { drflac *flac; neo_flac_io io; };

static size_t on_read(void *u, void *buffer, size_t count) { neo_flac_io *io = (neo_flac_io *)u; return io->read(io->user, buffer, count); }
static drflac_bool32 on_seek(void *u, int offset, drflac_seek_origin origin) {
    neo_flac_io *io = (neo_flac_io *)u;
    return io->seek(io->user, offset, origin == DRFLAC_SEEK_SET ? 0 : 1) ? DRFLAC_TRUE : DRFLAC_FALSE;
}
static drflac_bool32 on_tell(void *u, drflac_int64 *cursor) {
    neo_flac_io *io = (neo_flac_io *)u;
    long long position = 0;
    if (!io->tell(io->user, &position)) return DRFLAC_FALSE;
    *cursor = position;
    return DRFLAC_TRUE;
}

neo_flac *neo_flac_open_stream(neo_flac_read_fn read, neo_flac_seek_fn seek, neo_flac_tell_fn tell, void *user, int *channels, long *sampleRate) {
    neo_flac *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->io.read = read; d->io.seek = seek; d->io.tell = tell; d->io.user = user;
    d->flac = drflac_open(on_read, on_seek, on_tell, &d->io, NULL);
    if (!d->flac) { free(d); return NULL; }
    *channels = (int)d->flac->channels;
    *sampleRate = (long)d->flac->sampleRate;
    return d;
}

neo_flac *neo_flac_open(const uint8_t *data, size_t size, int *channels, long *sampleRate) {
    drflac *f = drflac_open_memory(data, size, NULL);
    if (!f) return NULL;
    neo_flac *d = malloc(sizeof *d);
    if (!d) { drflac_close(f); return NULL; }
    d->flac = f;
    *channels = (int)f->channels;
    *sampleRate = (long)f->sampleRate;
    return d;
}

void neo_flac_close(neo_flac *d) { if (!d) return; drflac_close(d->flac); free(d); }

long neo_flac_read(neo_flac *d, float *out, long frames) { return (long)drflac_read_pcm_frames_f32(d->flac, (drflac_uint64)frames, out); }
