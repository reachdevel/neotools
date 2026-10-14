# TODO

Open tasks, by topic. `[ ]` open, `[x]` done. "Who" is a name or a handle; leave it empty if you want the task to be free, write
yours to claim it. Tasks marked **needs hardware** cannot be finished without a particular Mac, device or file. Bigger plans are in
[ROADMAP.md](ROADMAP.md); how to contribute is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Release and distribution

- [x] Homebrew tap `reachdevel/tap` and formula (`brew install reachdevel/tap/neotools`, `brew test`), with the bundle installed next to the commands.
- [x] Bottles (prebuilt packages) for the tap, built by its GitHub Actions: macOS 15 and 26 on Apple silicon, macOS 15 on Intel.
- [ ] Bottles for macOS 14 (Apple silicon) and for Intel on macOS 26 (the first was built by CI but not published; the second has no runner yet); until then those Macs compile from source. Who: maintainer
- [ ] Submit the formula to homebrew-core when the project qualifies. Who: maintainer
- [x] GitHub Actions: build on macOS 14, 15 and 26 (`.github/workflows/build.yml`).
- [ ] GitHub Actions: also run the tests that do not need a particular machine (mark GPU, Trash, iCloud, Spotlight and terminal tests so CI can skip them). Who: maintainer
- [ ] Release notes, a `v0.1.0` tag, checksums. Who: maintainer
- [ ] Decide on prebuilt (notarized) binaries; needs a paid Developer ID. Who: maintainer
- [ ] Test installation on a clean user account: `neo-setup --install`, every command, `neo-setup --uninstall`. Who:

## Testing on other machines (needs hardware)

- [ ] macOS 14 and macOS 15: build, run `swift test`, report failures. Who:
- [ ] An Intel Mac: build, run `swift test`; how does `neotop` behave without performance/efficiency cores? Who:
- [ ] Other Apple silicon chips: is the cluster order in `neotop` (E cores first, then P cores) the same on M2/M3/M4/Pro/Max? Who:
- [ ] `sudo neotop`: the derived row for root processes disappears and every process is read directly. Who:
- [ ] `neodf` with a real local snapshot (`tmutil localsnapshot`): the snapshot line on the data volume. Who:
- [ ] `neotrash`: Finder's "Put Back" on items moved with it, on several macOS versions. Who:
- [ ] `neomedia`: HDR video, a real iPhone Live Photo, a GoPro or Insta360 file (is the 360 mark kept?), iCloud-only photos. Who:
- [ ] `neotop`: GPU and device power under a real load (a video, a game) against the charger's reading. Who:
- [ ] `neolsof`: the camera (IOKit user clients). Who:

## Commands: small gaps

- [ ] `neodu`: probe and cover directory hard links, the `ELOOP` message, `fd` on devfs, `-h` with `BLOCKSIZE` and `-t`. Who:
- [ ] `neonet`: UNIX sockets system-wide; Wi-Fi details (SSID, signal) through CoreWLAN. Who:
- [ ] `neotree`: test the iCloud mark with a real evicted file. Who:
- [ ] `neodocs strip` of a PDF does not touch metadata inside a picture's own bytes (the EXIF of a JPEG on a page). Who:
- [ ] `neodocs shrink`: measure the memory of a 1000-page scan (one `PDFDocument` is kept per page). Who:
- [ ] `neolsof`: a process with more than 20,000 mapped regions loses rows silently; reproduce with a real process, then raise the limit or say so. Who:
- [ ] `neotop`: per-frame costs (the row tree is copied for each sort, root-process identities are not cached), a wide character overflows a line. Measure first. Who:
- [ ] Small repeated work found by reviews (measure before changing): `TreeFold` decodes a name three times, `neotop` computes `labelText` three times per row, a `CVPixelBuffer` per decoded VP8/VP9/AV1 frame instead of the pool. Who:

## Tests

- [ ] Tests that need an unusual failure: a Parquet footer with absurd sizes (needs a crafted file), `getattrlistbulk` on a file system that lies, a `poll` that fails, `getifaddrs` that fails, an Apple app that ignores SIGTERM. Who:
- [ ] Mark machine-dependent tests so they can be skipped by an environment variable. Who:
- [ ] Make timing-sensitive tests (`neotop` measures a busy child) robust under load. Who:

## Documentation

- [x] Set the repository's social preview (Settings > General > Social preview) to `docs/assets/social-preview.png`. Who: maintainer
- [x] Put the repository URL in the README install section.
- [ ] A man page for each command, generated from `--help`. Who:
- [ ] Shell completions (zsh, bash, fish). Who:
- [ ] A short "which command replaces what" cheat sheet. Who:

## Localization

- [ ] A third language (every `Localizable.xcstrings` key plus the `help-*.txt` files; see [docs/TRANSLATING.md](docs/TRANSLATING.md)). Who:
- [ ] Make the localization tests check the help files of every language that is added, not only English and Turkish. Who:
- [ ] Review the Turkish text with a native speaker who is not the author. Who:

## Done

- [x] The twelve commands and `neo-setup`, with differential tests against the originals.
- [x] Benchmarks against the originals, documented in [docs/performance.md](docs/performance.md).
- [x] Five rounds of independent code review: crashes from hostile files, hangs, leaks and silent failures found and fixed.
