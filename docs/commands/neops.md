# neops

**`ps aux`, `ps -ef` and `--forest` on macOS.** The process list with the options Linux users type from memory. macOS `ps` speaks
BSD, so those commands fail on it.

```
neops [options]
```

`ps aux`, `ps -ef`, `ps -eo pid,ppid,%cpu,cmd --sort=-%cpu`, `ps --forest`: the commands Linux users type from memory, on macOS.
The processes and their numbers are those of `/bin/ps` (neops reads one table from it and the rest from the kernel).

## Which processes

`-e`/`-A` all, `-p list` by id, `-C list` by program name, `-u list` / `-U list` by user, `--ppid list` by parent, `-t list` by
terminal, `-a` with a terminal and not session leaders, `-N` all the others. BSD letters work without a dash: `aux`, `ax`, `x`
(and `-x`, `-ax`).

## What to show

`-f` (UID PID PPID C STIME TTY TIME CMD), `u` (USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND), `-o list` (`pid,ppid,cmd`
or `pid=ID`), `-O list`, `--forest`/`f` (children under their parents), `-H` (indented), `--no-headers`, `w`/`ww` (wider command).

Columns for `-o` and `--sort`: `pid ppid pgid tpgid uid ruid gid user ruser group tty stat s pri ni %cpu %mem vsz rss time etime
etimes lstart start stime c f comm cmd args`.

## Order

`--sort key,-key` (a minus sorts downwards) and `k key` (BSD style).

## What it does not do

Options of the macOS `ps` that Linux does not have (`-M`, `-L`, ...) are refused with a hint. `neops --plain args` runs the macOS
`ps` with those arguments. `neops -aux` means `-a -u x` (a user named x), like `ps -aux`.

## Examples

```sh
neops aux
neops -ef
neops auxf
neops -eo pid,ppid,%cpu,cmd --sort=-%cpu
neops -C nginx
neops -p 1,$$ -o pid,ppid,etime,cmd
```

## Performance

`neops aux` takes 62 ms where `ps aux` takes 60 ms; `neops -p 1` takes 10 ms where `ps -p 1` takes 1.3 ms. It is not faster
than `ps`; it speaks another dialect.
