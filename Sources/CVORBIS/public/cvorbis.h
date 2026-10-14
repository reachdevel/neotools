#ifndef NEO_CVORBIS_H
#define NEO_CVORBIS_H
#include <stddef.h>
#include <stdint.h>

/// A Vorbis decoder (libvorbis 1.3.7 and the bit reader of libogg 1.3.5, BSD-3-Clause, see COPYING), reduced to what neomedia needs:
/// the packets come from a Matroska file, not from an Ogg stream.
typedef struct neo_vorbis neo_vorbis;

/// The three header packets (identification, comment, setup). Returns NULL when they are not a Vorbis stream.
neo_vorbis *neo_vorbis_open(const uint8_t *id, size_t idSize, const uint8_t *comment, size_t commentSize, const uint8_t *setup, size_t setupSize,
                            int *channels, long *sampleRate);
void neo_vorbis_close(neo_vorbis *d);
/// One audio packet. Returns 0 when it was accepted.
int neo_vorbis_packet(neo_vorbis *d, const uint8_t *data, size_t size);
/// Up to `maxFrames` decoded frames, interleaved floats. Returns how many (0: the decoder needs the next packet).
int neo_vorbis_read(neo_vorbis *d, float *out, int maxFrames);

#endif
