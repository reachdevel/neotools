# Roadmap

What neotools is working towards. Nothing here is a promise or a date; the order follows how much each item helps, and how clear
its contract can be made. Open tasks, with room for names, are in [TODO.md](TODO.md).

The rule for every new command stays the same: **"behaves exactly like X, plus ..."**, checked against X by tests, or a new tool
with a written contract that says what it reads, what it never changes, and what it does not do.

## Now: a first public release (0.1.0)

- Homebrew: the tap `reachdevel/tap` ships with 0.1.0 (the formula installs the translation bundle next to the commands); a submission to homebrew-core follows when the project qualifies.
- Continuous integration on a macOS runner (build and the tests that do not depend on a particular machine).
- Release notes, a signed tag and checksums.
- Testing on more machines: macOS 14 and 15, Intel, other chips (the order of the P/E clusters in `neotop`).

## Next: finish what exists

- `neodu`: `--evicted` (only the cloud-only part), clone-aware accounting (APFS clones share blocks), compressed files.
- `neonet`: UNIX sockets system-wide, Wi-Fi details through CoreWLAN (rates belong to `neotop`).
- `neolsof`: the camera (IOKit user clients). Screen recording and location have no public per-process API.
- `neotrash`: a Finder-compatible restore check ("Put Back") on more macOS versions.
- `neotop`: tested with `sudo`, on more chips, and under long runs.
- More languages for everything the commands print. English and Turkish are done; the format is a String Catalog and a text file
  per command, so a translator needs no Swift.

## Later: new commands and features

| idea | what it would do |
|---|---|
| dataless-safe filtering | a thin tool (or a mode of `neofind`) that lists local-only or cloud-only paths, so `grep -r`, `tar` and `rsync` can skip evicted files instead of downloading them |
| `neocp` | `cp` that clones on APFS by default and warns before it downloads an evicted file |
| `neols` | `ls` with a readable cloud/local marker and sizes that mean "frees on delete" |
| `neofind --near lat,lon` | search by place (Spotlight latitude/longitude) |
| `neotree --git` | fold what `.gitignore` says |
| `neops` | threads (`-L`, `nlwp`), `sid`, `-l`, `-F` |
| `neomedia` | a scrolling `info` for big folders; a default video quality that follows the source's bit rate |
| `neodocs` | Word headers and footers; `strip` of Excel/PowerPoint comments; a native reader for Pages/Numbers/Keynote (today the Apple apps convert them) |
| a real 360 camera file | check that the 360 mark survives re-encoding on GoPro/Insta360 files and on macOS 14 |

## Not planned

- Coreutils clones (`cat`, `echo`, `head`...): no macOS gain; use GNU coreutils or uutils.
- Replacing files in `/usr/bin`: protected by SIP. `neo-setup` is the way in.
- A multi-call binary, or a Linux port: the value is the macOS-specific knowledge.
- `neotrace` (a `dtruss` replacement): considered and rejected. The supported way to watch other processes is Endpoint Security,
  which needs an entitlement Apple does not give to an open source command line tool; `neotop` (disk I/O per process) and
  `neolsof` (who has this open) answer the same questions.
- Killing processes or changing priorities in `neotop`: it stays read-only.
