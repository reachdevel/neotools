# neolsof

**Who has it open?** `lsof` for macOS: which program holds a file, a port or the microphone, plus deleted files that still use
space. Up to 6.8x faster than `lsof`, and it never waits for DNS.

```
neolsof [-?abClnPRtUw] [-c c] [+c w] [-d d] [-F f] [-i i] [-o] [-p s]
        [-r t] [-s p:s] [-u s] [+L [n]] [+D D] [+d d] [names]
        [--deleted] [--listening] [--mic] [--json] [--plain]
```

## Same as `lsof` (for the options it implements)

Names (files, directories, mount points), `+D`, `+d`, `-p`, `-c` (with `^` and `/regex/`), `-u`, `-i [46][TCP|UDP][:port]`,
`-s p:s`, `-d`, `-U`, `-a`, `-t`, `-l`, `-n`, `-P`, `-R`, `-o`, `+c w`, `+L [n]`, `-r`/`+r`, `-F fields` (`p c u L R f a t s o i P n`,
`-F0`), `-w -b -C -?`. On the queries covered by the tests the output is byte-identical to `lsof` 4.91.

Options neolsof does not implement are **refused** with a message, never guessed: run `neolsof --plain <the same arguments>`,
which hands the job to `/usr/sbin/lsof`.

## Different

- **Fast.** One `proc_pidinfo` call lists the descriptors of a process, processes are read side by side, and a question about the
  network does not read the files. `lsof -n -i`: 64 ms, `neolsof -i`: 9.4 ms.
- **Host names are never looked up.** Plain `lsof` waits for DNS (seconds on some networks); `neolsof` never does.
- **Extras.** `--deleted` (files deleted but still open: they hold space), `--listening` (TCP ports somebody listens on),
  `--mic` (processes that are recording audio right now, with their bundle ids), `--json`.
- **On a terminal:** a dim header, names cut to the window, and a last line that says how many processes could not be listed.

## Repeat mode

`-r [t]` lists again every `t` seconds (15 without a number), each listing followed by a line of `=======`, until stopped.
`+r [t]` does the same and ends by itself when a listing is empty.

## Examples

```sh
neolsof -i :8080                # who uses port 8080
neolsof -iTCP -sTCP:LISTEN -P -n
neolsof +L1                     # deleted files that are still open
neolsof -p $$ -d cwd
neolsof --mic
```

## Notes

Processes of other users need `sudo`, as for `lsof`. `neolsof` says how many it could not read.
A few differences are known: a protected mapped file whose attributes the kernel withholds is listed with size 0 and device `0,0`.
