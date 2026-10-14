# Performance

Measured, not claimed. Every number below was taken with [hyperfine](https://github.com/sharkdp/hyperfine) on one machine, with the
originals called by their full path, and the places where neotools **loses** are listed with the reasons. Treat the figures as
the shape of the result, not as a promise for your Mac.

## How to measure again

```sh
swift build -c release
hyperfine -N --warmup 2 --output null --ignore-failure \
  '/usr/bin/du -sk /usr' '.build/release/neodu --local -sk /usr'
```

`-N` runs the commands without a shell, `--output null` throws the output away, so the time is the command's own. For a cold cache
run `sudo purge` before each run (`hyperfine --prepare 'sudo purge'`). Compare like with like: `neodu --local` with `du` (the
iCloud-aware default counts more), `lsof -n` with `neolsof` (plain `lsof` waits for DNS), and check that the machine is idle.

## Setup

- Machine: Apple M1 (MacBookAir10,1), 8 cores, 16 GiB, macOS 26.6.2 (25G83), APFS, on mains power, no low-power mode.
- A release build of this source tree; hyperfine 2.0.0. Measured on 14 October 2026.
- An ordinary working Mac (browsers and mail open). Every case started only when the CPU had been at least 75% idle for a second
  (checked just before the case; the idle share seen was 76% to 89%), and a case that could not get that quiet was measured again
  later. The median and the minimum are the figures to read, not the mean.
- The originals are called by their full path (`/usr/bin/du`, `/usr/bin/find`, `/bin/ps`, `/usr/sbin/lsof`, ...; `tree` is Homebrew's 2.2.1). `neodu` and `neotree` run with `--local`, so that they count what `du` and `tree` count and nothing about iCloud.
- Commands run without a shell, output thrown away (`hyperfine -N --output null`), so the time is the command's own. Warm: 2 warm-up runs, then 5 to 40 runs. Cold: `sudo -n /usr/sbin/purge` before each of 5 runs.
- Trees: `/usr` (38,138 files, 2.0 GB), `/opt/homebrew` (224,764 files, 19.6 GB), `/Applications` (597,073 files, 47.0 GB).
- "x faster" is the original's median divided by the neo tool's; "x slower" the other way round. Peak memory is the resident set size hyperfine reports (median of the runs).
- The media and document cases use files generated for the test: a 12 megapixel photo with noise (JPEG and HEIC), 24 photos of 6 megapixels, 10 s of synthetic 1080p video, two PDFs of 149 pages of text, a scan of 6 pages, a CSV of 300,000 rows.

## Starting up (tiny input, warm)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| df / | 1.2 ms (min 1.2 ms) | 3.8 ms (min 3.4 ms) | 3.1x slower | 1.3 MiB / 6.1 MiB |
| du -s /etc/hosts | 1.2 ms (min 1.1 ms) | 4.0 ms (min 3.4 ms) | 3.3x slower | 1.3 MiB / 6.2 MiB |
| find /etc/hosts | 1.2 ms (min 1.2 ms) | 3.9 ms (min 3.6 ms) | 3.2x slower | 1.3 MiB / 6.5 MiB |
| neofree (macOS has no free) | - | 3.8 ms (min 3.4 ms) |  | - / 6.0 MiB |
| ifconfig -a / neonet --all | 2.2 ms (min 2.2 ms) | 13.4 ms (min 13.1 ms) | 6.0x slower | 1.3 MiB / 11 MiB |
| lsof -p 1 | 10.2 ms (min 10.0 ms) | 3.8 ms (min 3.4 ms) | **2.7x faster** | 1.3 MiB / 6.3 MiB |
| netstat -rn / neonet -r | 2.9 ms (min 2.8 ms) | 15.3 ms (min 14.9 ms) | 5.3x slower | 1.5 MiB / 11 MiB |
| ps -p 1 | 1.3 ms (min 1.2 ms) | 10.1 ms (min 9.7 ms) | 7.7x slower | 1.3 MiB / 9.3 MiB |
| top -l 1 -n 0 / neotop --once -i 0.1 | 440.3 ms (min 435.6 ms) | 268.0 ms (min 251.8 ms) | **1.6x faster** | 7.4 MiB / 27 MiB |
| tree /etc/ssh | 1.6 ms (min 1.5 ms) | 7.5 ms (min 7.3 ms) | 4.8x slower | 1.5 MiB / 9.5 MiB |
| neodu --version (no original equivalent) | - | 3.5 ms (min 3.4 ms) |  | - / 5.9 MiB |

## The system views (warm)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| df -h | 1.4 ms (min 1.3 ms) | 3.7 ms (min 3.6 ms) | 2.7x slower | 1.4 MiB / 6.2 MiB |
| lsof -n (every open file you may see) | 157.3 ms (min 156.6 ms) | 85.6 ms (min 84.7 ms) | **1.8x faster** | 10 MiB / 46 MiB |
| lsof -n -i | 63.6 ms (min 63.3 ms) | 9.4 ms (min 9.2 ms) | **6.8x faster** | 3.9 MiB / 10.0 MiB |
| netstat -an / neonet -an | 2.4 ms (min 2.2 ms) | 8.9 ms (min 8.4 ms) | 3.7x slower | 1.6 MiB / 9.8 MiB |
| ps aux | 60.1 ms (min 58.8 ms) | 62.3 ms (min 62.1 ms) | same | 4.2 MiB / 12 MiB |
| ps -ef | 39.2 ms (min 38.8 ms) | 60.0 ms (min 59.8 ms) | 1.5x slower | 3.9 MiB / 12 MiB |
| top -l 2 -s 1 / neotop --once -i 1 (about a second of sampling each) | 1.52 s (min 1.49 s) | 1.20 s (min 1.20 s) | **1.3x faster** | 7.4 MiB / 27 MiB |

## neodu against du (warm cache)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| du -ak /opt/homebrew (a line for every file) | 1.56 s (min 1.55 s) | 796.4 ms (min 774.3 ms) | **2.0x faster** | 5.4 MiB / 79 MiB |
| du -ak /usr (a line for every file) | 177.2 ms (min 176.1 ms) | 110.9 ms (min 108.8 ms) | **1.6x faster** | 2.2 MiB / 18 MiB |
| du -k -d 1 /Applications | 9.08 s (min 8.91 s) | 2.26 s (min 2.20 s) | **4.0x faster** | 13 MiB / 35 MiB |
| du -k -d 1 /opt/homebrew | 1.53 s (min 1.52 s) | 725.6 ms (min 715.7 ms) | **2.1x faster** | 5.3 MiB / 20 MiB |
| du -k -d 1 /usr | 172.5 ms (min 171.6 ms) | 100.9 ms (min 98.1 ms) | **1.7x faster** | 2.1 MiB / 10 MiB |
| du -sk /Applications | 8.96 s (min 8.83 s) | 2.28 s (min 2.21 s) | **3.9x faster** | 13 MiB / 35 MiB |
| du -sk /opt/homebrew | 1.52 s (min 1.52 s) | 727.8 ms (min 684.7 ms) | **2.1x faster** | 5.3 MiB / 20 MiB |
| du -sk /usr | 172.4 ms (min 171.6 ms) | 100.6 ms (min 98.0 ms) | **1.7x faster** | 2.1 MiB / 10 MiB |

## neofind against find (warm cache)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| find /Applications (every path) | 11.03 s (min 10.99 s) | 2.14 s (min 2.06 s) | **5.2x faster** | 7.7 MiB / 47 MiB |
| find /opt/homebrew (every path) | 2.25 s (min 2.25 s) | 764.7 ms (min 732.6 ms) | **2.9x faster** | 3.5 MiB / 25 MiB |
| find /usr (every path) | 237.8 ms (min 237.0 ms) | 86.4 ms (min 77.9 ms) | **2.8x faster** | 1.9 MiB / 13 MiB |
| find /Applications -type f -mtime +365 | 11.09 s (min 11.03 s) | 2.25 s (min 2.16 s) | **4.9x faster** | 13 MiB / 46 MiB |
| find /opt/homebrew -type f -mtime +365 | 2.28 s (min 2.27 s) | 743.3 ms (min 735.0 ms) | **3.1x faster** | 5.3 MiB / 25 MiB |
| find /usr -type f -mtime +365 | 240.8 ms (min 239.8 ms) | 87.4 ms (min 75.4 ms) | **2.8x faster** | 2.1 MiB / 13 MiB |
| find /Applications -type f -name '*.dylib' | 11.33 s (min 11.20 s) | 2.18 s (min 2.15 s) | **5.2x faster** | 13 MiB / 47 MiB |
| find /opt/homebrew -type f -name '*.dylib' | 2.34 s (min 2.33 s) | 734.7 ms (min 723.4 ms) | **3.2x faster** | 5.3 MiB / 25 MiB |
| find /usr -type f -name '*.dylib' | 250.3 ms (min 250.0 ms) | 93.4 ms (min 84.7 ms) | **2.7x faster** | 2.1 MiB / 13 MiB |
| find -s /usr (sorted) | 242.7 ms (min 241.7 ms) | 87.6 ms (min 82.1 ms) | **2.8x faster** | 2.0 MiB / 14 MiB |
| find /Applications -type f -size +10M | 11.11 s (min 11.02 s) | 2.26 s (min 2.18 s) | **4.9x faster** | 13 MiB / 46 MiB |
| find /opt/homebrew -type f -size +10M | 2.27 s (min 2.27 s) | 737.6 ms (min 730.1 ms) | **3.1x faster** | 5.2 MiB / 23 MiB |
| find /usr -type f -size +10M | 241.0 ms (min 240.2 ms) | 89.8 ms (min 87.7 ms) | **2.7x faster** | 2.1 MiB / 12 MiB |

## neotree against tree (warm cache)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| tree -a /opt/homebrew (names only) | 3.82 s (min 3.79 s) | 1.56 s (min 1.55 s) | **2.5x faster** | 6.8 MiB / 101 MiB |
| tree -a /usr (names only) | 291.7 ms (min 289.6 ms) | 248.5 ms (min 247.1 ms) | **1.2x faster** | 2.7 MiB / 30 MiB |
| tree --du -h -a /opt/homebrew (with sizes) | 3.93 s (min 3.90 s) | 1.66 s (min 1.64 s) | **2.4x faster** | 71 MiB / 100 MiB |
| tree --du -h -a /usr (with sizes) | 300.6 ms (min 298.6 ms) | 269.4 ms (min 266.8 ms) | **1.1x faster** | 11 MiB / 28 MiB |

## neodu against du (cold cache: `purge` before every run)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| du -k -d 1 /opt/homebrew | 1.45 s (min 1.42 s) | 875.8 ms (min 855.2 ms) | **1.7x faster** | 5.3 MiB / 20 MiB |
| du -sk /opt/homebrew | 1.56 s (min 1.43 s) | 1.00 s (min 976.8 ms) | **1.6x faster** | 5.3 MiB / 20 MiB |
| du -sk /usr | 262.0 ms (min 256.5 ms) | 437.6 ms (min 404.2 ms) | 1.7x slower | 2.1 MiB / 10 MiB |

## neofind against find (cold cache)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| find /usr (every path) | 354.5 ms (min 290.6 ms) | 415.2 ms (min 349.4 ms) | 1.2x slower | 1.9 MiB / 13 MiB |
| find /opt/homebrew -type f -name '*.dylib' | 2.47 s (min 2.25 s) | 1.01 s (min 897.0 ms) | **2.5x faster** | 5.3 MiB / 25 MiB |
| find /opt/homebrew -type f -size +10M | 2.24 s (min 2.14 s) | 945.4 ms (min 927.8 ms) | **2.4x faster** | 5.2 MiB / 25 MiB |

## neotree against tree (cold cache)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| tree --du -h -a /opt/homebrew (with sizes) | 4.08 s (min 4.02 s) | 2.07 s (min 2.01 s) | **2.0x faster** | 71 MiB / 101 MiB |
| tree --du -h -a /usr (with sizes) | 403.8 ms (min 394.9 ms) | 668.0 ms (min 637.7 ms) | 1.7x slower | 11 MiB / 28 MiB |

## neomedia against the usual tools

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| HEIC (12 MP) to JPEG | 152.9 ms (min 151.8 ms) | 159.1 ms (min 156.2 ms) | same | 31 MiB / 35 MiB |
| what is in a 12 MP photo | 53.2 ms (min 52.8 ms) | 12.1 ms (min 12.0 ms) | **4.4x faster** | 20 MiB / 15 MiB |
| 12 MP JPEG to HEIC | 130.0 ms (min 127.9 ms) | 130.7 ms (min 129.6 ms) | same | 53 MiB / 56 MiB |
| 12 MP JPEG to a 1600 px JPEG, quality 85 | 106.9 ms (min 105.7 ms) | 107.4 ms (min 105.6 ms) | same | 52 MiB / 57 MiB |
| 12 MP JPEG to WebP, quality 80 | 1.19 s (min 1.19 s) | 1.17 s (min 1.17 s) | same | 106 MiB / 232 MiB |
| a folder of 24 JPEGs (6 MP) to WebP, quality 80 | 3.00 s (min 2.91 s) | 2.96 s (min 2.87 s) | same | 50 MiB / 1,189 MiB |
| 10 s of 1080p H.264 to 720p H.264 | 1.62 s (min 1.61 s) | 618.4 ms (min 615.0 ms) | **2.6x faster** | 384 MiB / 55 MiB |
| MKV to MP4 without re-encoding | 37.7 ms (min 37.0 ms) | 40.0 ms (min 39.6 ms) | 1.1x slower | 22 MiB / 53 MiB |

## neodocs against the usual tools

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| a CSV of 300,000 rows to JSON | - | 908.8 ms (min 907.9 ms) |  | - / 234 MiB |
| a CSV of 300,000 rows to Parquet | - | 494.8 ms (min 493.5 ms) |  | - / 146 MiB |
| a CSV of 300,000 rows to XLSX | - | 1.62 s (min 1.61 s) |  | - / 382 MiB |
| the pictures of a 6-page scan | 4.17 s (min 4.16 s) | 575.6 ms (min 573.4 ms) | **7.2x faster** | 10 MiB / 111 MiB |
| what is in a 149-page PDF | 3.6 ms (min 3.3 ms) | 8.3 ms (min 8.0 ms) | 2.3x slower | 3.1 MiB / 12 MiB |
| merge two 149-page PDFs | 13.7 ms (min 13.6 ms) | 20.4 ms (min 20.2 ms) | 1.5x slower | 7.5 MiB / 15 MiB |
| OCR of a one-page scan | 1.80 s (min 1.80 s) | 1.59 s (min 1.49 s) | **1.1x faster** | 97 MiB / 266 MiB |
| pages 10-40 of a PDF to a new PDF | 7.6 ms (min 7.4 ms) | 12.9 ms (min 12.7 ms) | 1.7x slower | 5.7 MiB / 14 MiB |
| pages 1-10 of a PDF to PNG, 100 dpi | 2.23 s (min 2.23 s) | 293.9 ms (min 292.7 ms) | **7.6x faster** | 15 MiB / 28 MiB |
| a 6-page scan sampled again at 150 dpi | - | 432.7 ms (min 431.0 ms) |  | - / 110 MiB |
| split a 149-page PDF into one file per page | 41.1 ms (min 33.2 ms) | 54.6 ms (min 53.1 ms) | 1.3x slower | 6.0 MiB / 19 MiB |
| a PDF without its metadata | 100.1 ms (min 99.4 ms) | 15.5 ms (min 15.3 ms) | **6.5x faster** | 37 MiB / 14 MiB |
| the text of a 149-page PDF | 103.2 ms (min 102.8 ms) | 138.8 ms (min 136.2 ms) | 1.3x slower | 11 MiB / 76 MiB |

## neotrash against rm (what neotrash moves stays in the Trash)

| case | original | neo | | peak memory (original / neo) |
|---|---:|---:|---|---:|
| one file of 50 MB: rm / neotrash | 2.5 ms (min 2.4 ms) | 49.6 ms (min 47.1 ms) | 19.6x slower | 1.3 MiB / 26 MiB |
| one small file: rm / neotrash | 1.6 ms (min 1.4 ms) | 46.4 ms (min 45.0 ms) | 28.9x slower | 1.3 MiB / 26 MiB |
| a folder of 2,000 files in 20 folders: rm -r / neotrash -r | 116.9 ms (min 114.8 ms) | 47.3 ms (min 45.8 ms) | **2.5x faster** | 1.3 MiB / 26 MiB |

## Memory (one run of each, `/usr/bin/time -l`)

The footprint is what the process really held at its peak. The resident size also counts memory that was freed and not yet taken back, which an image decoder leaves in the hundreds of MiB; it is the figure in the tables above, the footprint is the one to read for memory.

| case | original: resident / footprint | neo: resident / footprint |
|---|---:|---:|
| a CSV of 300,000 rows to Parquet | - | 146 MiB / 136 MiB |
| a CSV of 300,000 rows to XLSX | - | 382 MiB / 354 MiB |
| du -sk /opt/homebrew | 5.3 MiB / 5.0 MiB | 20 MiB / 15 MiB |
| find /opt/homebrew (every path) | 3.5 MiB / 3.2 MiB | 24 MiB / 19 MiB |
| lsof -n (every open file you may see) | 11 MiB / 10 MiB | 46 MiB / 42 MiB |
| the pictures of a 6-page scan | 10 MiB / 3.5 MiB | 111 MiB / 95 MiB |
| merge two 149-page PDFs | 7.5 MiB / 4.1 MiB | 15 MiB / 5.3 MiB |
| OCR of a one-page scan | 97 MiB / 1.1 MiB | 267 MiB / 203 MiB |
| a 6-page scan sampled again at 150 dpi | - | 111 MiB / 36 MiB |
| the text of a 149-page PDF | 11 MiB / 4.3 MiB | 74 MiB / 60 MiB |
| 12 MP JPEG to WebP, quality 80 | 106 MiB / 105 MiB | 232 MiB / 144 MiB |
| a folder of 24 JPEGs (6 MP) to WebP, quality 80 | 50 MiB / 1.1 MiB | 1,199 MiB / 634 MiB |
| ps aux | 4.3 MiB / 0.0 MiB | 12 MiB / 4.9 MiB |
| tree -a /opt/homebrew (names only) | 6.8 MiB / 6.3 MiB | 101 MiB / 94 MiB |
| tree --du -h -a /opt/homebrew (with sizes) | 71 MiB / 71 MiB | 100 MiB / 94 MiB |
| 10 s of 1080p H.264 to 720p H.264 | 384 MiB / 370 MiB | 55 MiB / 36 MiB |

## Reading the numbers

### Where the neo tools win

- **Walking a tree** (`neodu`, `neofind`): 1.6x to 4.0x faster than `du` and 2.7x to 5.2x faster than `find` on a warm cache (`/Applications`, 597,000 files: `du` 9.0 s, `neodu` 2.3 s; `find` 11.0 s, `neofind` 2.1 s). The scanner reads a directory with one `getattrlistbulk` call and several directories at a time; the originals call `lstat` once for each file, one thread. On a cold cache the bigger trees are still 1.6x to 2.5x faster; the small one (`/usr`) is not (see below). They pay with memory: 10 to 79 MiB against 2 to 13 MiB.
- **`neotree`**: 2.4x to 2.5x faster than `tree` on `/opt/homebrew` (1.7 s against 3.9 s with sizes), 2.0x on a cold cache, and about as fast on `/usr` (1.1x to 1.2x). Its memory is 94 MiB for 308,000 entries (`tree --du` 71 MiB; `tree` without sizes streams its output and holds 6 MiB).
- **`neolsof`**: `lsof -n -i` 64 ms, `neolsof -i` 9.4 ms (6.8x); every open file `lsof -n` 157 ms, `neolsof` 86 ms (1.8x). Plain `lsof` looks up the name of every host it meets and can wait seconds for the resolver (5 s on the test Mac one day, 6 to 7 s on another Mac); `neolsof` never looks hosts up ([neolsof](commands/neolsof.md)). The comparison above is with `-n`, so that both do the same job.
- **`neotop`**: 1.3x to 1.6x faster than `top -l` for one table.
- **Pictures** (`neomedia`): as fast as the tool that is closest to the job (`cwebp` for WebP, `sips` for JPEG and HEIC; both use the same code underneath). Video: 2.6x faster than `ffmpeg` with libx264 for a 1080p to 720p H.264 conversion, with a tenth of the memory (36 MiB against 370); the outputs are not the same size (see the end). `neomedia info` is 4.4x faster than `exiftool`.
- **PDF to pictures** (`neodocs convert --to png`): 7.6x faster than `pdftoppm` for ten pages. **Pictures out of a PDF** (`images`): 7.2x faster than `pdfimages -all` on a 6-page scan (576 ms against 4.17 s). **Strip** (`strip`): 6.5x faster than `exiftool -all=` (15 ms against 100), and it takes everything out of the file (see the [command page](commands/neodocs.md): `exiftool -all=` leaves the original in the file's earlier revision). **OCR** of one page: 1.1x faster than `tesseract` (1.59 s against 1.80); most of the time is Vision loading its model (12 pages take 3.7 s). **Shrink** of a 6-page scan sampled again at 150 dpi: 433 ms (no original does this).
- **`neotrash -r`** on a folder of 2,000 files: 2.5x faster than `rm -r` (a folder moves as one: 47 ms; `rm` unlinks each file: 117 ms).

### Where they lose, and why

- **Starting up.** A C program starts in about 1.2 ms; a neo command in 3.4 to 4.0 ms. That is the floor of every neo command: the Swift runtime and the frameworks loading. A Swift test program that only imports Foundation needed about 2.7 ms in an earlier test (not repeated in this run), so going below that would mean no Foundation in the hot commands.
- **`neops`** is as fast as `ps aux` (62 ms against 60) and 1.5x slower than `ps -ef` (60 against 39), and answers `ps -p 1` in 10 ms where `ps` needs 1.3. It runs `/bin/ps` once for everything it needs (the table of all the processes, with the fields that cost `ps` itself 35 ms) and reads the rest itself. `ps -ef` has less to print than the table `neops` asks for, so it is cheaper for `ps`.
- **`neonet`** takes 9 to 15 ms where `ifconfig` and `netstat` take 2.2 to 2.9 ms. The start is 4 ms; SystemConfiguration (a conversation with `configd`) names the interfaces and finds the router and the DNS servers, about 10 ms.
- **Small trees on a cold cache** (`/usr`, 38,000 files): `neodu` 1.7x slower than `du`, `neofind` 1.2x, `neotree` 1.7x. After `purge` the runtime and Foundation are read from the disk again before anything starts, which is about 150 ms that the originals (in the system's shared cache, used all the time) do not pay. With a warm cache the same trees are won.
- **`neodocs` on PDFs** is within 1.3x to 2.3x of `qpdf` and `pdftotext` (merge 20 ms against 14, pages 13 against 7.6, split into pages 55 against 41, `info` 8.3 against `qpdf --show-npages` 3.6): merging, splitting and counting read the structure of the file themselves and copy the pages as they are (PDFKit is used only for files the reader does not take). The text of a document is PDFKit's, read by several copies of it at once: 139 ms against 103. What is left over `qpdf` is the start (about 5 ms for the frameworks) and the check that the result is a PDF.
- **`neotrash` on one file** takes 46 ms where `rm` needs 1.6: the call that puts a file in the Trash the way Finder does (`FileManager.trashItem`, which also records where it came from for "Put Back") takes about 40 ms by itself.
- **`neomedia` remux** (MKV to MP4, no re-encoding): 1.1x slower than `ffmpeg -c copy` (40 ms against 38).
- **Memory** of the other PDF verbs (footprint): `images` 95 MiB (`pdfimages` 3.5), `ocr` of a page 203 MiB (`tesseract` 1.1), `shrink` of six pages 36 MiB.
- **Memory** of the folder of 24 photos: 634 MiB held at the peak (1.2 GiB of resident size, which also counts what the image decoder freed and the system has not taken back), eight pictures at a time; `cwebp` takes 50 MiB for one picture, so eight at a time are about 400. A memory budget (a quarter of the memory, 14 bytes a pixel) holds pictures back when they would not fit together. A CSV of 300,000 rows to XLSX takes 354 MiB.

### Things to read the figures with

- One machine, one day, one macOS version. The shape of the result (tree walking and media work win, tiny jobs lose a few milliseconds) is what carries over to other Macs, not the exact figures.
- "Cold" is `purge` before each run: it also throws away the pages of the neo program itself and of the Swift runtime, which the originals do not pay.
- Output sizes are not compared. `neomedia` and `ffmpeg` choose different qualities for the same number; the time of a conversion says nothing about the size of its result.
- Peak memory in the first tables is the resident size that hyperfine reports; the table "Memory" has the footprint, which is the memory the process held.
- `lsof` looks hosts up unless `-n`; the tables compare with `-n`.
- `neotrash` leaves what it moves in the Trash (three items named `one.txt`, `big.bin` and `tree` for every run); the Trash is emptied by hand.
