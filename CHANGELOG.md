# Changelog

All notable changes to neotools are written here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project intends to follow [Semantic Versioning](https://semver.org/) once it has a first release.

## [Unreleased]

## [0.1.1] - 2026-10-14

### Fixed

- Table headers and notes printed as `[net.col.interface]`, `[net.hidden]` and so on when the program was built with the Command Line
  Tools only (no Xcode app), which is what a Homebrew bottle built on a CI runner gets: the String Catalog was copied into the bundle
  uncompiled and was not read. The commands now read the catalog directly when the compiled files are missing, and a test covers it.

## [0.1.0] - 2026-10-14

First public version.

### Added

- **Twelve commands and a setup tool**, one executable each:
  - `neodu`: `du` with iCloud awareness; counts files evicted to iCloud as Finder does (`--local` for plain `du` numbers), a live table on a terminal.
  - `neodf`: `df` that understands APFS containers, purgeable space, local snapshots and the Trash; `--json`.
  - `neotop`: Activity Monitor for the terminal; applications with performance and efficiency cores, GPU, watts, memory, network and disk.
  - `neofree`: `free` for macOS, with the numbers of Activity Monitor and the memory pressure.
  - `neotrash`: `rm` with an undo; moves to the Trash like Finder.
  - `neofind`: `find` with Finder tags, purgeable, evicted and quarantined files.
  - `neolsof`: a fast `lsof`, with `--deleted`, `--listening`, `--mic`, `-r`/`+r` and `--json`.
  - `neotree`: a tree with sizes that folds `node_modules`, `.git`, virtual environments and build output.
  - `neops`: `ps aux`, `ps -ef` and `--forest` on macOS.
  - `neonet`: interfaces, sockets with their programs, routes and DNS, read-only (`neonet -tulpn`).
  - `neomedia`: `info`, `convert`, `shrink` and `strip` for photos and videos (HEIC, RAW, MKV, WebM, AVIF, WebP...).
  - `neodocs`: `info`, `text`, `convert`, `merge`, `split`, `images`, `strip`, `ocr` and `shrink` for PDF, Word, Excel, CSV,
    Parquet, Pages, Numbers and Keynote files.
  - `neo-setup`: optional shell functions so that typing `du` runs `neodu`, `df` runs `neodf`, and so on; removable.
- **Differential tests** that run the real command and the neo command side by side and compare stdout, stderr and exit status.
- Messages and help in English and Turkish; a translation guide for new languages ([docs/TRANSLATING.md](docs/TRANSLATING.md)).
- Performance measurements against the originals ([docs/performance.md](docs/performance.md)).
- README, per-command pages in `docs/commands/`, CONTRIBUTING, SECURITY, ROADMAP, TODO and third-party notices.

### Fixed

Five rounds of independent review before the first release found and fixed, among others:

- crashes and unbounded memory from hostile files (a spreadsheet with two cells at its corners, a document nested 20,000 levels deep,
  table cells asking for billions of columns, list levels outside what Word has, Matroska files with absurd sizes, damaged PDF and
  Parquet files, zip and deflate bombs);
- hangs (a pattern that searched a part from every open tag, a PDF reader that searched the whole file for every stream, writers that
  waited for the stall limit instead of reporting their own error);
- temporary files left behind when a run was stopped, and a limit of 64 of them;
- silent failures (sound or pictures that stopped early, subtitles that were not saved, interfaces that could not be read).

### Known limits

- Tested on one machine (Apple silicon, macOS 26). macOS 14 and 15 and Intel Macs are untested.
- See each command page in `docs/commands/` and [TODO.md](TODO.md).
