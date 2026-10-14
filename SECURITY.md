# Security policy

## Supported versions

neotools has not had a stable release yet. Security fixes go to the `main` branch and to the latest release once there is one.

## What counts as a security problem

neotools reads files that other people write: PDFs, Word, Excel and PowerPoint files, Parquet files, photos, videos (including
MKV and WebM), zip archives, Matroska subtitles, and the output of the kernel. A problem in any of these paths is a vulnerability if
a crafted input can make a command:

- crash, trap or hang (a denial of service for a script or a person who only wanted to look at a file),
- use unbounded memory or disk (a small file that asks for gigabytes),
- read or write a file it was not asked to (path traversal, a symlink followed where it must not be),
- run a program or script it was not meant to (the commands that drive Pages, Numbers or Keynote pass file names as arguments,
  never as part of a script's text),
- delete or overwrite data it should have left alone (the commands that write files never overwrite a file that exists).

Memory-safety bugs in the compiled-in C libraries (libwebp, libvpx, dav1d, libvorbis, dr_flac, carquet, lz4, zstd) count too if they
can be reached through a neotools command; please also report them to the upstream project.

Not security problems: needing `sudo` to see other users' processes, the limits of System Integrity Protection, or a result that is
wrong without any of the above (open a normal issue for those).

## How to report

Please do not open a public issue for a vulnerability. Report it privately:

- use the repository's **private vulnerability reporting** (GitHub: Security > Report a vulnerability), or
- write to **reachdevel@gmail.com** with "neotools security" in the subject.

Include the command and its arguments, the macOS version and chip, what you expected and what happened, and a file that shows it
(or how to make one). A short script that generates the file is best.

## What to expect

This is a small project. You will get an answer within about a week, and a fix or a clear "this is not a vulnerability" as soon as
it can be done. Credit is given in the release notes unless you prefer not.

## Design choices that limit the damage

- The commands read metadata and never open a file they were not asked to read; they never download an evicted iCloud file by accident.
- Sizes and counts that come from a file are checked before they size a buffer; there are ceilings for pages, cells, nesting depth and
  archive sizes, and tests that feed hostile files (a spreadsheet with two cells at the corners, a 20,000-level nested document,
  deflate bombs, damaged footers, a fuzz run over the PDF reader).
- No `!`, `try!` or `fatalError` on anything that depends on input or the system.
- Temporary files are removed when a run is stopped (SIGINT, SIGTERM, SIGHUP); output is written to a hidden file first and moved
  into place without replacing anything.
- Nothing is sent over the network. `neotop` talks to the loopback once to calibrate its network counters.
