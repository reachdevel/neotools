# neofree

**`free` for macOS.** macOS has no `free`; `vm_stat` prints pages. `neofree` is the familiar Linux table (the command line follows
procps-ng `free`) filled with the numbers Activity Monitor uses, plus the memory pressure.

```
neofree [-b | --kilo | --mega | --giga | --tera | --peta | -k | -m | -g | --tebi | --pebi | -h | --si]
        [-t] [-w] [-s N] [-c N] [--plain] [--json] [--pressure]
```

## The table

```
              total        used        free      shared  buff/cache   available
Mem:           16Gi        10Gi       1.0Gi          0B       4.0Gi       5.0Gi
Swap:         3.0Gi       2.1Gi       942Mi
```

| column | what it is |
|---|---|
| total | installed memory |
| used | app + wired + compressed (Activity Monitor's "Memory Used") |
| free | free pages minus speculative ones |
| buff/cache | cached files + purgeable memory (Activity Monitor's "Cached Files") |
| available | free + buff/cache: an estimate of what could be handed out without paging (macOS has no `MemAvailable`) |
| shared | always 0 (no such counter) |

With `-w`, "buffers" is purgeable memory and "cache" is cached files. The parts do not add up to `total`: the kernel keeps about
3 % aside that no counter attributes. All numbers come from Mach (`host_statistics64`) and `sysctl`; no program is run.

## Options

Units: `-b --kilo --mega --giga --tera --peta` (1000-based), `-k -m -g --tebi --pebi` (1024-based), `-h` human readable,
`--si` for powers of 1000. `-t` adds a total row for RAM + swap. `-s N` repeats every N seconds and `-c N` stops after N tables.
`-l` is accepted and has no effect.

Extras: `--json` (exact bytes), `--pressure` (the memory pressure level: normal, warning, critical), `--plain`.

On a terminal without options you get a coloured view with a bar; piped, with `--plain` or with a Linux-style option you get the
Linux table, so scripts written for `free` work.
