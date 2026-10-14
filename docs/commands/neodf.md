# neodf

**`df` that understands APFS.** Free disk space with the volumes of a container grouped, purgeable space, local snapshots and the
Trash counted, so the numbers match what Finder shows. In a pipe it prints exactly what `df` prints.

```
neodf [-b | -g | -H | -h | -k | -m | -P] [-acIilnY] [-,] [-T type]
      [--plain] [--json] [file | filesystem ...]
```

## Why

On APFS every volume of a container shares one pool of space, so classic `df` prints a column of numbers that mean little (the
system volume, `Data`, `VM`, `Preboot`... all "free" at once). It also cannot tell you about purgeable space (what Finder counts
as available), local snapshots, or what is in the Trash.

## The modern view (default on a terminal)

- Volumes of an APFS container are grouped: size, used, free, a bar and a percentage, then the volumes of the container.
- **Purgeable space** is a row under the volume that holds your files: what macOS can give back when it needs it.
  `available_in_finder` in `--json` is the figure Finder shows.
- **Local snapshots** of the data volume, with the date of the oldest.
- **The Trash** of each local volume is a row with its size. Listing `~/.Trash` needs Full Disk Access; `neodf --access` explains
  and opens the right pane of System Settings.
- Helper volumes (VM, Preboot, Update, Recovery...) are folded into one line; `-a` shows everything.
- Other volumes (HFS+, exFAT, network) get their own block.
- Sizes are GiB-style (`-h`) or GB-style (`-H`).

## The classic view

Piped output, `--plain`, `NEODF_PLAIN=1`, `CI`, and the classic-only flags (`-P -b -k -m -g -,`) print exactly what macOS `df`
prints: the same columns, widths, rounding, messages and exit codes (about 240 invocations are compared with the real `df`).
`df --libxo` is not supported.

## JSON

`neodf --json` prints `{"filesystems":[...]}`. A container has `size`, `used`, `free`, `purgeable`, `available_in_finder`,
`snapshots` and `volumes`; a plain volume has its device, mount point, type, byte counts and inode counts; the Trash is a `trash`
object on the volume. All numbers are exact bytes.

## Examples

```sh
neodf                  # the modern view
neodf -h /             # the volume that holds /
neodf --json | jq '.filesystems[] | select(.kind=="apfs-container") | .available_in_finder'
neodf --plain -i       # the classic table, with inodes
```
