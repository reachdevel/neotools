# neofind

**`find` for the Mac you actually have.** The `find` you know, plus Finder tags, purgeable files, files evicted to iCloud and
quarantined downloads. Up to 5x faster on large trees.

```
neofind [-H | -L | -P] [-dsx] [-f path] [path ...] [expression]
        [--tag [name]] [--purgeable] [--evicted] [--quarantined]
        [--no-spotlight] [--json] [--plain]
```

## Same as `find`

The options of macOS `find` (`-H -L -P -d -s -x -f`), the primaries `-name -iname -path -ipath -wholename -iwholename -type
-empty -size -mtime -atime -ctime -Btime -mmin -amin -cmin -Bmin -newer -user -group -uid -gid -perm -links -inum -xattr
-xattrname -depth -maxdepth -mindepth -prune -quit -print -print0 -true -false`, the operators `( ) ! -not -a -o`, the
`-size` and `-mtime` suffixes, and the output order. About 140 invocations plus real trees are compared byte for byte with
`/usr/bin/find` on stdout, stderr and status. Primaries and options `neofind` does not have (`-exec`, `-delete`, `-regex`,
`-newerXY`, `-ls`, ...) are **refused** with a hint: run `neofind --plain` with the same arguments, which hands the job to
`/usr/bin/find`.

## Different

- **Faster.** Directories are read with one bulk call, several at a time. `find /Applications` 11.0 s, `neofind` 2.1 s.
- **Without a path it searches `.`** (`find` stops with a usage error).
- **`-mtime` and friends accept units:** `-mtime -1h30m` (`s m h d w`).
- **Extras:**
  - `--tag [name]`: files with a Finder tag. Without a name, all tagged files, with their tags. Asks Spotlight for files under your
    home folder and walks elsewhere; `--no-spotlight` reads every file's tag instead.
  - `--purgeable`: files macOS may remove when it needs space.
  - `--evicted`: iCloud files that are not stored on this Mac (metadata only; nothing is downloaded).
  - `--quarantined`: downloaded files that were not opened yet.
  - `--json`: output as JSON (written as the entries are found).
- The extras combine with every primary: `neofind . -type f -size +100M -mtime +30d --purgeable`.
- `--json`, `--version`, `--help`, `--plain` and `--no-spotlight` may stand anywhere except where `find` would take a word as a
  value: `neofind . -name --json` looks for a file called `--json`.

## Examples

```sh
neofind -name '*.md'
neofind ~/Documents -type f -size +100M
neofind . -mtime -7 -name '*.swift'
neofind ~ --purgeable -size +10M
neofind ~ --tag Red
```

## Notes

A protected regular file that refuses `lstat` is printed (`find` reports it). The index (`--tag`) is a few seconds behind the
file system and does not cover everything; every hit is checked against the file system before it is printed.
