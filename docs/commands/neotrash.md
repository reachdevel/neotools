# neotrash

**Delete with an undo.** `rm` with the same options, except that files go to the Trash like when you delete them in Finder, so
"Put Back" works and a typo is not a disaster.

```
neotrash [-f | -i] [-dIPRrvWx] [--plain] file ...
```

## Same as `rm`

Options `-d -f -i -I -P -R -r -v -W -x`, option parsing (options stop at the first operand), the checks for `.`, `..` and `/`,
the prompts of `-i` and `-I`, the messages, and the exit status (`1` as soon as one operand failed; the others are still done).
The tests compare the messages and statuses with `/bin/rm`.

## Different

- Every removal is a **move to the Trash** using the same call as the Finder (`FileManager.trashItem`), so "Put Back" has the
  information it needs. `-f` included.
- A directory moves **as a whole**: `-i` asks once per operand, `-v` lists the operands, `-P` and `-x` have nothing to act on and
  are accepted and ignored. `-W` (whiteouts) is refused with a hint to use `--plain`.
- A volume without a Trash (network shares, some external disks) is an **error** (`there is no Trash on this volume (use
  --plain to delete it for good)`), never a silent delete.
- On a terminal, one dim line on stderr says how much went to the Trash and that the space comes back only when the Trash is
  emptied. It is not printed on a pipe, with `NEOTRASH_PLAIN=1`, or when stderr is not a terminal.
- A directory that cannot be read is not taken for an empty one by `-d`; it is left where it is, with the error.

## `--plain`

`neotrash --plain ...` (or `--permanent`) runs the real `/bin/rm` with your arguments: deletion for good.

## Notes

`neotrash` is not meant to replace `rm` in scripts. `neo-setup` offers it as a shell function for interactive shells only.
Moving one file costs about 40 ms (the Trash call itself); a folder of 2,000 files moves as one and is faster than `rm -r`.
