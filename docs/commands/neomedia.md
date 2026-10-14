# neomedia

**Photos and videos in one tool.** Inspect them, convert them (HEIC, JPEG, AVIF, WebP, MP4...), make them smaller and take the
location out, with nothing to install: no `sips`, `ffmpeg`, `cwebp` or `exiftool` glued together by a script.

```
neomedia info|convert|shrink|strip PATH... [options]
```

`PATH` is a file or a folder (`-r` goes into folders). Anything that is not a photo or a video is counted and left alone.
Everything is done with Apple's frameworks (ImageIO, AVFoundation, VideoToolbox) plus a few small compiled-in codecs.

## Commands

| command | does |
|---|---|
| `info` | what is in each file: format, size, dimensions, date taken, place, length, codec, bit rate |
| `convert` | change the format (`--to jpg png heic avif webp tiff mp4 mov m4v`) or the video codec (`--codec h264\|hevc`) |
| `shrink` | the same format, smaller (`--quality`, `--max`, `--p`) |
| `strip` | take the location out (`--all`: all metadata), without touching the picture |

Defaults: HEIC becomes JPG, JPG becomes WebP.

## Options

| option | meaning |
|---|---|
| `--to format` | `convert`: the new format |
| `--quality n` | 1 to 100 |
| `--max n` | longest edge in pixels |
| `--p n` | shorter edge, as in 720p |
| `--codec c` | video: `h264` or `hevc` |
| `--strip gps\|all` | drop metadata while converting or shrinking |
| `--out dir` | write there |
| `--trash-original` | move the original to the Trash when the new file is written |
| `--keep-dates` | the new file gets the dates of the original |
| `-n`, `--dry-run` | show what would be written |
| `--no-subtitles` | MKV: do not save the subtitles next to the new file |
| `-j n` | photos converted at a time |
| `--sort key`, `--reverse` | `info`: name size taken length dimensions format |

Choosing files (every command): `--larger size`, `--smaller size` (`500K`, `5M`, `2G`), `--since date`, `--before date` (by the
day taken), `--gps`/`--no-gps`, `--format list`, `--wider n`, `--longer n`, `--only photo|video`, `-r`, `--download` (bring down
files that are only in iCloud; otherwise they are skipped and counted). `--json`, `-v` (also say what was left out), `--plain`.

## What it reads and writes

- **Photos read:** everything ImageIO reads: JPEG, PNG, HEIC/HEIF, AVIF, WebP, GIF, BMP, TIFF, JPEG 2000, JPEG XL, TGA, ICO/ICNS,
  PSD, OpenEXR and the RAW files macOS knows (DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2...).
- **Photos written:** JPG, PNG, HEIC, AVIF, TIFF, and WebP (the compiled-in libwebp; up to 16383 pixels a side; without metadata).
- **Videos read:** MP4, MOV, M4V, MPEG, TS/MTS, 3GP and AVI with codecs macOS has. **MKV and WebM** are read by our own reader:
  H.264 and HEVC are copied, VP8, VP9 and AV1 are decoded with the compiled-in libvpx and dav1d; sound is AAC, MP3, AC-3, E-AC-3,
  Opus, Vorbis or FLAC. FLV, WMV, OGV, MXF and others are not read.
- **Videos written:** MP4, MOV, M4V with H.264 or HEVC; AAC audio or the audio the file had.

## What it says

The command does the work and tells what it did that you may not expect, and the option that changes it: a Live Photo (the MOV is
left alone), an HDR photo rendered as standard range, an animation (first frame only), RAW (rendered the way macOS renders it),
a video already smaller than `--max` (copied), WebP written without metadata, subtitles saved next to an MKV conversion, pictures
that a decoder refused, sound that stopped early. At the end one line: `12 files: 340 MiB -> 85 MiB, 255 MiB saved`.

Exit status: 0 when everything asked was done or skipped on purpose, 1 when something failed, 64 for a wrong command line.

## Examples

```sh
neomedia info Pictures --sort size --reverse
neomedia convert IMG_0042.heic
neomedia shrink Pictures -r --larger 5M --max 1920 --out small
neomedia shrink clip.mov --p 720 --codec hevc
neomedia strip holiday --trash-original
```

## Limits

- The default video quality (65) is not tuned to the source: a low-bit-rate source can come out larger as H.264 at the default;
  `--quality 40` or `--codec hevc` brings it down.
- HDR video is converted to standard range, and subtitles, chapters and extra tracks are not carried when a video is encoded again.
- `strip` of a WebP is refused (macOS cannot write WebP, and encoding it again would lose quality).
- A 100-megapixel photo takes about 400 MB while it is converted. A memory budget (a quarter of the memory) holds pictures back
  when they would not fit together; lower `-j` on a small Mac.
- Videos are converted one at a time (the hardware encoder is the limit).
