#ifndef NEO_CFLAC_H
#define NEO_CFLAC_H
#include <stddef.h>
#include <stdint.h>

/// A FLAC decoder (dr_flac, public domain / MIT No Attribution, see COPYING), reduced to what neomedia needs.
typedef struct neo_flac neo_flac;

/// The stream is given by three functions (the decoder reads it as it goes): bytes are copied into `buffer` (fewer at the end, 0 when it is over),
/// `seek` moves to `offset` from the start (origin 0) or from where it is (origin 1) and says whether that was possible, `tell` gives the position.
typedef size_t (*neo_flac_read_fn)(void *user, void *buffer, size_t count);
typedef int (*neo_flac_seek_fn)(void *user, int offset, int origin);
typedef int (*neo_flac_tell_fn)(void *user, long long *position);
neo_flac *neo_flac_open_stream(neo_flac_read_fn read, neo_flac_seek_fn seek, neo_flac_tell_fn tell, void *user, int *channels, long *sampleRate);

/// `data` is a whole native FLAC stream ("fLaC", the metadata, then the frames), which stays valid while the decoder is used.
neo_flac *neo_flac_open(const uint8_t *data, size_t size, int *channels, long *sampleRate);
void neo_flac_close(neo_flac *d);
/// Up to `frames` frames as interleaved floats. Returns how many (0 at the end).
long neo_flac_read(neo_flac *d, float *out, long frames);

#endif
