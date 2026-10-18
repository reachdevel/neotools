# neo-setup

**Type `du`, get `neodu`.** Optional shell functions that make `du` run `neodu`, `df` run `neodf` and so on (for `find`, `lsof`,
`tree`, `top`, `ps`, `rm`, `ifconfig` and `netstat` too), in every interactive shell. One command puts them in, one takes them out.

```
neo-setup [--install | --uninstall | --status]
```

`/usr/bin` is protected by System Integrity Protection, so neotools cannot replace the system commands and does not try.
`neo-setup` puts **shell functions** in front of them, in the startup file of each shell, between marker lines. Nothing outside
the markers is touched.

## Commands

| command | does |
|---|---|
| `neo-setup` | three pages on a terminal: which shells, which commands, which short names; the last page applies the choice |
| `--install` | every command in every shell, no questions (the flag is the consent) |
| `--uninstall` | takes every block out again |
| `--status` | what is set up, per shell; which neo commands are not on the `PATH` |

Without a terminal the pages are not offered. `q`, Ctrl-C and end of input leave without changing anything.

## What is written

For each shell one block between `# >>> neotools >>>` and `# <<< neotools <<<`:

| shell | file |
|---|---|
| zsh | `$ZDOTDIR/.zshrc`, else `~/.zshrc` |
| bash | `~/.bash_profile` |
| fish | `$XDG_CONFIG_HOME/fish/conf.d/neotools.fish`, else `~/.config/fish/conf.d/neotools.fish` |

A backup of a file is written once (`<file>.neo-setup-backup`) before the first change, and every action is logged in
`~/Library/Logs/neo-setup.log`.

- **Same-name functions:** `du`, `df`, `lsof`, `find`, `tree`, `top`, `ps`, `rm` run the neo command if it is installed and the
  original if it is not, so removing neotools never breaks `du`.
- **Short names:** `free`, `media`, `docs`, `sweep` (there is no original behind them).
- **`ifconfig`** runs `neonet` only when called without arguments; **`netstat`** runs `neonet` only in the Linux-style forms it
  answers (`-tulpn`, `-an`, `-r`, `-i`...); everything else goes to the originals.

## Know before you install

- The functions exist **in interactive shells only**. Scripts, cron and IDE tasks keep the system commands.
- `ps` speaks the options of Linux, not macOS `ps`; a script that needs the real one writes `/bin/ps`.
- `rm` moves to the Trash and does not free space; `/bin/rm` deletes.
- `neo-setup --uninstall` takes everything out again.
