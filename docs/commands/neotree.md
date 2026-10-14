# neotree

**A folder tree with sizes.** macOS has no `tree`. `neotree` shows the structure of a folder with the size of every entry and
folds `node_modules`, `.git`, virtualenvs and build output into one line each, so the part you care about stays readable.

```
neotree [PATH...] [options]
```

There is no `tree` on macOS. `neotree` does not use one, and does not need one.

## What it shows

```
$ neotree --plain -L 2 app
320 KiB  app
304 KiB  |-- node_modules > 2 directories, 2 files
4.0 KiB  |-- package.json
 12 KiB  `-- src
4.0 KiB      |-- index.ts
4.0 KiB      `-- util.ts

1 directory, 3 files
folded: 3 directories, 2 files, 304 KiB
```

(On a terminal that speaks UTF-8 the branches are drawn with box characters and the sizes are coloured.)

Every entry has its size. Folders that nobody wants to read are one line with their total: `node_modules`, `.git`, Python
virtual environments and caches, Rust `target`, `build` and `dist` next to the file that says they are output, Xcode and Gradle
caches, Unity and Unreal folders, and more. The full table is in `Sources/NeoCore/TreeFold.swift`. A name that is also used for
real content (`build`, `target`, `dist`) is folded only when the file beside it says it is generated.

## Options

| option | meaning |
|---|---|
| `-a` | also hidden entries (a hidden folded folder is listed, folded) |
| `-d` | folders only |
| `-L n` | at most n levels |
| `-f` | the whole path of each entry |
| `-x` | stay on one file system |
| `--no-size` | no sizes |
| `--local` | files that exist only in iCloud count as nothing |
| `-I pattern` | leave out names that match (`a\|b`) |
| `-P pattern` | only files that match (a folder is shown when something below it matches) |
| `--sort name\|size\|time`, `-r` | the order (default: name, numbers by value), reversed |
| `--dirsfirst` | folders before files |
| `--show[=list]` | open all folded folders, or only these names |
| `--fold list` | fold these names too |
| `--json`, `--plain` | JSON output; no colours |

By default files that live only in iCloud are counted by the size they will have once downloaded (the mark `◌` follows
them; `NEOTREE_CLOUD` changes the mark).

## Examples

```sh
neotree
neotree -L 2 ~/Projects
neotree --sort size --dirsfirst src
neotree --show=node_modules app
neotree -I '*.log|tmp' -P '*.swift' .
```

## Notes

Folded folders are measured while they are read and not kept, so the memory is that of the visible tree: 94 MiB for 308,000
entries. `neotree` is 2.4x faster than `tree --du` on a large tree and as fast on a small one.
