# Changelog

All notable changes to neotools are written here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project intends to follow [Semantic Versioning](https://semver.org/) once it has a first release.

## [Unreleased]

### Changed

- **`neodocs`**: a Markdown list is separated from the paragraph under it by a blank line (the line was read as part of the last item).
- **`neosweep`**: Disk clean is the first entry of the menu and This Mac the last; connected disks are no longer menu entries (they are under `/Volumes` in This Mac); the descriptions of the menu are rewritten in English and Turkish; in This Mac the Applications and Homebrew rows and the data of installed applications are grey and are not opened; the pane on the right greys links and what cannot be deleted; the confirmation lists every place of a thing; two copies of one application are chosen separately; the list of what is not sure whose no longer holds names that an installed application, a command-line tool or macOS owns.

### Added

- **`neofind`**: a word with `*`, `?` or `[` that is not an existing path is read as `-name`: `neofind '*.md' -type f` and `neofind -type f '*.md'` (without a path the search starts in `.`).
- **`neodocs convert`**: a PDF becomes `docx rtf odt html md` (the words, headings, lists and paragraphs, not the layout; a scan is told to go through `ocr` first); Word, text and table files and a PDF's text become `.pages`, `.numbers` and `.key` files (`docx rtf odt html md txt pdf` to `pages`, `xlsx csv tsv json jsonl parquet` to `numbers`, `pptx` to `key`) through the Apple apps; `pptx` and `key` become `txt` or `md`; `numbers` becomes `parquet`. `--help` shows what turns into what.
- **`neosweep`**, a full-screen disk cleaner: This Mac (the disk from the top, with what is unknown said out loud), Disk clean (caches, logs,
  package-manager stores, model downloads, emulators, the Trash, iPhone backups, Xcode, simulators, virtual machines, old installers),
  Applications (with what they left in the Library, and what is left of applications that are gone), Homebrew (packages, apps, old versions,
  data left behind, removed through `brew`), Large files, iCloud, and every connected disk. It shows what deleting something really frees (the private size, so clones and snapshots are counted right),
  deletes for good after you type a word, warns about running applications and about your own data, and only reports what needs
  administrator rights. `--scan`, `--list`, `--detail` and `--json` give the same as reports for scripts.
  Sizes are shown as Finder shows them (decimal GB, figures lined up with the unit in its own column), a dash stands for what cannot be said, rows are sorted while they are
  added up, `f` shows a row in Finder, the system and hidden entries are one row, and an item lists its folders with what each takes. Disk clean also knows about
  developer tools (caches, downloads, installed versions of about a hundred tools, listed only when they are on the Mac). What removed applications and packages left behind (Library folders, Homebrew data and settings) is in Disk clean. Sizes always have two decimals (0,86 GB, 0,13 KB). `n` chooses nothing, `A` everything (`a` what is safe), on a terminal of 120 columns a pane on the right shows what is in the row under the cursor (`v` switches it), names lose their middle instead of pushing the sizes away, the width of letters written with a separate accent (and wide characters) is counted right, opening a folder of the disk does not add it up again, deleting is real: no category is held back any more, and `NEO_TRASH=1` moves to the Trash instead (for trying it), "Not sure whose they are" lists what the careful leftover search leaves out, with the reason beside each (nothing chosen, not looked at by default), the rebuildable folders of your projects (`node_modules`, `.venv`, `target`, caches) are a category of Disk clean, `--leftovers file` writes why each name of the Library is or is not taken for a leftover, Homebrew places are named by what they are, `o` opens the parts of an application, an application is chosen with everything it left (also in `~/.cache` and `~/.config`) and applications in folders of Applications are listed, the confirmation says where each thing is, links in the disk view are shown as links, the Turkish word to type is `silelim` and the column `KAZAN`, what was added up in the last 15 minutes (the biggest files too) is remembered (in `~/.cache/neosweep`) so that going back to a page does not add it up again, `r` adds it up again, a row that is still being added up is not opened, and iCloud is browsed like Finder's iCloud Drive, folder by folder.
- `neo-setup` offers the short name `sweep` for `neosweep`.

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
