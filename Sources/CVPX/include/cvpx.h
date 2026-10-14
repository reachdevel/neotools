#ifndef NEO_CVPX_H
#define NEO_CVPX_H
#include <stddef.h>
#include <stdint.h>

/// A VP8 / VP9 decoder (libvpx 1.15.0, BSD-3-Clause, see COPYING), reduced to what neomedia needs.
typedef struct neo_vpx neo_vpx;

neo_vpx *neo_vpx_open(int vp9);
void neo_vpx_close(neo_vpx *d);
/// Gives the decoder one compressed picture (a packet of the file). Returns 0 when it was accepted.
int neo_vpx_decode(neo_vpx *d, const uint8_t *data, size_t size);

typedef struct {
    int width, height;
    int bitDepth;                       // 8 or 10/12 (stored in 16 bits)
    int colorSpace;                     // 0 unknown, 1 BT.601, 2 BT.709, 3 SMPTE 170, 4 SMPTE 240, 5 BT.2020, 7 sRGB (libvpx numbering)
    int fullRange;                      // 1: the picture uses the full 0-255 range
    int chromaShiftX, chromaShiftY;     // 1, 1 for 4:2:0; 1, 0 for 4:2:2; 0, 0 for 4:4:4
    const uint8_t *plane[3];
    int stride[3];                      // bytes
} neo_vpx_image;

/// The next picture that is to be shown, or 0 when there is none. The pointers stay valid until the next decode.
int neo_vpx_next(neo_vpx *d, neo_vpx_image *out);

#endif
