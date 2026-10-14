# neodu

**`du` with iCloud awareness.** Disk usage that counts the files "Optimize Mac Storage" moved to iCloud the way Finder does, in a
live table on a terminal and the exact text of `du` in a pipe. Up to 4x faster on big trees.

```
neodu [-AclnSx] [-H | -L | -P] [-g | -h | -k | -m | --si]
      [-a | -s | -d depth] [-B blocksize] [-I mask] [-t threshold]
      [--local] [--plain] [file ...]
```

## Why

macOS `du` reports almost nothing for a file that lives only in iCloud ("dataless"), so `du -sh ~/Library/Mobile\ Documents` says
a few kilobytes for folders that hold gigabytes in the cloud. `neodu` counts such a file by the size it will occupy once downloaded,
the way Finder shows it. It reads metadata only, so it never triggers a download.

## Same as `du`

The options, the output and the exit codes are those of macOS `du`: `-A -B -H -I -L -P -a -c -d -g -h -k -l -m -n -s -t -x -r` and
`--si`, `BLOCKSIZE`, hard links counted once, symlink rules, post-order output in directory order, the messages and the exit
status 64 for usage errors. Piped or redirected, and with `--plain`, the output is plain `du` text. The test suite compares
80+ invocations with the real `du` on stdout, stderr and the exit code.

## Different

- **iCloud aware by default.** `--local` counts only what is stored on this Mac, exactly like `du` (use it when you compare).
- **Faster.** One `getattrlistbulk` call reads a directory and several directories are read at the same time.
  `du -sk /Applications` (597,000 files): 9.0 s, `neodu` 2.3 s.
- **On a terminal:** a spinner while it works, and for `-s`/`-d` a table that fills in live. `--plain` turns it off.
- **`-S`** sorts the lines by size, largest first (with `-r`, smallest first).

## Examples

```sh
neodu -sh ~/Library/Mobile\ Documents      # what iCloud Drive would take if downloaded
neodu --local -sh ~/Library                # what is on this Mac now
neodu -hd 1 ~/Projects | sort -h
neodu -S -h -d 2 /opt/homebrew
```

## Notes

- A file on a volume that is not APFS is counted as `du` counts it.
- Cold-cache runs over small trees are slower than `du` (see [performance](../performance.md)); warm-cache runs are faster.
- Environment: `NEODU_PLAIN=1` is the same as `--plain`.
