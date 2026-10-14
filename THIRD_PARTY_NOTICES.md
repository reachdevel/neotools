# Third-party notices

Everything below is part of the neotools source tree (the licence text of each library is in a `COPYING` file next to its code, and must stay with it when the code is copied or redistributed), built into the commands, and under its own licence We wrote none of it; we only wrote the thin wrappers named in the last column. The system's own frameworks (ImageIO, AVFoundation, PDFKit, Vision, Compression, zlib...) are not listed: they are part of macOS.

| Software | Version | Licence | What for | Where | Our part |
|---|---|---|---|---|---|
| [libwebp](https://chromium.googlesource.com/webm/libwebp) | 1.6.0 | BSD-3-Clause (Google) | writing WebP | `Sources/CWebP` | the call in `MediaImage.swift` |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) | 1.15.0 | BSD-3-Clause (Google) | decoding VP8 and VP9 | `Sources/CVPX` | `cvpx.h`, `cvpx.c` |
| [dav1d](https://code.videolan.org/videolan/dav1d) | 1.5.1 | BSD-2-Clause (VideoLAN) | decoding AV1 | `Sources/CDAV1D` | `cdav1d.h`, the files that include each template for 8 and 16 bit |
| [libvorbis](https://github.com/xiph/vorbis) and the bit reader of [libogg](https://github.com/xiph/ogg) | 1.3.7, 1.3.5 | BSD-3-Clause (Xiph.Org) | decoding Vorbis | `Sources/CVORBIS` | `cvorbis.h`, `cvorbis.c` |
| [dr_flac](https://github.com/mackron/dr_libs) | | public domain or MIT-0 (David Reid) | decoding FLAC | `Sources/CFLAC` | `cflac.c` |
| [carquet](https://github.com/Vitruves/carquet) | 0.7.1 | MIT (Johan HG Natter) | reading and writing Parquet files | `Sources/CCARQUET` | `Sources/DocsKit/DocsParquet.swift` |
| [lz4](https://github.com/lz4/lz4) | 1.10.0 | BSD-2-Clause (Yann Collet) | a compression of Parquet files (carquet's dependency) | `Sources/CCARQUET/lz4_lib.c`, `lz4.h` | none |
| [zstd](https://github.com/facebook/zstd) | 1.5.7 | BSD-3-Clause (Meta) | a compression of Parquet files (carquet's dependency), as the single-file library the zstd project builds from its own sources | `Sources/CCARQUET/zstd_lib.c`, `zstd.h` | none |

## Notes

- **carquet:** the library was embedded without its command line tool, tests, examples and the vector (SIMD) code for x86 and SVE, which it does not need to work (it has plain C versions of everything); its own SIMD dispatch is off because the build does not define the architecture macros. Its upstream is young (first announced at the end of 2025); the files of this tree are those of its tag 0.7.1 (commit `162a5d6`). A Parquet file written by Apache Arrow (parquet-cpp-arrow 25.0.1, 5,700 rows, 14 columns) was read back with the right values, and 250 random mutations of that file never crashed the reader.
- **zlib** (gzip pages of Parquet files) is the system's: linked, not embedded.
- **Updating a library:** replace its directory by the new release, keep the wrapper files and the `COPYING`, build, run the suites of the commands that use it (`neomedia` for the first five, `neodocs` for the Parquet ones).
