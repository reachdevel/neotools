#ifndef NEO_CDAV1D_H
#define NEO_CDAV1D_H
#include <stddef.h>
#include <stdint.h>

/// An AV1 decoder (dav1d 1.5.1, BSD-2-Clause, see COPYING), plain C, reduced to what neomedia needs.
typedef struct neo_av1 neo_av1;

neo_av1 *neo_av1_open(int threads);
void neo_av1_close(neo_av1 *d);
/// Gives the decoder one temporal unit (a packet of the file). Returns 0 when it was accepted.
int neo_av1_send(neo_av1 *d, const uint8_t *data, size_t size, int64_t timestamp);

typedef struct {
    int width, height;
    int bitDepth;                       // 8 or 10/12 (stored in 16 bits)
    int layout;                         // 0: 4:0:0, 1: 4:2:0, 2: 4:2:2, 3: 4:4:4
    int fullRange;
    int matrix;                         // 1 BT.709, 5/6 BT.601, 9 BT.2020 (the AV1 / H.273 numbers), 2 unspecified
    int64_t timestamp;
    const uint8_t *plane[3];
    int stride[3];                      // bytes
} neo_av1_image;

/// 1 and the picture while there are pictures to take, 0 when the decoder needs more data; -1 on a failure. Valid until the next call.
int neo_av1_next(neo_av1 *d, neo_av1_image *out);
/// No more data: the pictures still inside come out through `neo_av1_next`.
void neo_av1_flush(neo_av1 *d);

#endif
