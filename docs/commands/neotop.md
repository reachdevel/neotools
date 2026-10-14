# neotop

**Activity Monitor for the terminal.** A live, sortable table of what runs on your Mac, grouped by application: CPU split into
performance and efficiency cores, GPU, power in watts, memory, network and disk. Built for Apple silicon.

```
neotop [-i seconds] [-n count] [--once] [--sort key] [--top N]
       [--filter system|apps|text] [--expand name] [--processes] [--idle]
       [--describe] [--bytes] [--net|--no-net] [--disk|--no-disk] [--path]
       [--no-system] [--json] [--plain]
```

## The idea

`top` shows one row for each process, and helper processes (Chrome has twenty) hide the application. Activity Monitor groups them
but lives in a window. `neotop` is the Activity Monitor view in the terminal: **one row for each application**, with the roles
inside (`Renderer`, `GPU`, `Utility`...) one key away, live, sortable by any column, and filterable. It works over SSH and `--once`
and `--json` make it scriptable.

On Apple silicon it adds what neither `top` nor Activity Monitor puts in one table: the CPU is split into **performance (P) and
efficiency (E) cores**, which cost very different amounts of energy. Two busy loops measured **199.7 % on performance cores =
6.75 W**, while Chrome with 20 processes measured **33 % on efficiency cores = 0.06 W**. A GPU column and the **watts** each
application drew (CPU plus its share of the GPU) answer "what is draining my battery?" at once.

Read-only: it has no kill, no renice. It reads metadata only and uses Apple libraries (the public APIs, plus IOReport for the
power of the hardware). No `powermetrics`, no `sudo` for your own processes.

## Columns

`P CORES` and `E CORES` (time on that kind of core, in percent of one core), `GPU` (time the process kept the GPU busy, in
percent of the whole GPU), `WATT` (CPU + the process's share of the GPU), `MEMORY` (physical footprint), `NET` (received + sent
per second, in bits; `--bytes` for bytes), `DISK`. A header shows the clusters, GPU, memory, network and, on a MacBook, what the
whole machine draws.

## Running

| option | meaning |
|---|---|
| `-i seconds` | sample interval, 0.1 to 60 |
| `-n count` | print that many tables, then stop |
| `--once` | print one table instead of the live view |
| `--sort key` | `watt p e gpu cpu mem net disk name` |
| `--top N` | only the first N rows |
| `--filter x` | `system`, `apps`, or text in the name |
| `--expand name` | show the roles inside an application |
| `--processes` | show every process |
| `--idle` | open the idle rows |
| `--no-system` | leave out System (macOS) |
| `--net/--no-net`, `--disk/--no-disk` | always / never show these columns |
| `--path` | full paths instead of names |
| `--describe` | a description of what a process is, where one is known |
| `--json`, `--plain` | JSON; no colours or bars |

## Live view keys

`q` quit, `up/down` or `k/j` move, `space` expand, `/` filter, `?` help, `s` path, `d` disk, `b` bits/bytes, `f` freeze,
`+ -` interval, `W` save settings, and `w p e g c m t i n` to sort by watt, P, E, GPU, CPU, memory, network, disk, name. `W` saves to
`~/.config/neotop/config` (or `$XDG_CONFIG_HOME/neotop/config`); the file is read only by the live view, so `--once` and `--json` never change
with a person's habits.

## Root and kernel processes

Without `sudo` the counters of root's processes (about a third) and of the kernel cannot be read. They appear in
`System (macOS)` by count, name and owner. Their share of P/E time and power is **derived** from the totals (the load of all
cores minus the time of the readable processes), and the row says so. Run as root, every process is read directly.

## Examples

```sh
neotop                                  # live view
neotop --once --top 5                   # the five applications that use the most power
neotop --once --expand "Google Chrome"
neotop --json --once | jq '.rows[0]'
```

## Notes

- Percentages are time on a core, not work done: a P core does more in the same time.
- The power of the hardware comes from IOReport (`libIOReport.dylib`), which is Apple's own library but undocumented. If it is
  missing or answers differently, the hardware figures are not shown and nothing else changes.
- The first run measures how many bytes the kernel counts per byte on the loopback (to turn socket counters into network rates)
  and stores two numbers in `~/Library/Caches/neotools/`.
