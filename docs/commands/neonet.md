# neonet

**The network at a glance.** Interfaces, sockets with the programs that own them, routes and DNS in one read-only command, with
the flags Linux users know (`neonet -tulpn`). Replaces the everyday uses of `ifconfig` and `netstat`.

```
neonet [-tuxla46pn] [-r] [-i] [-b] [--all] [--json] [--plain]
```

`neonet` is not a wrapper and has no original to match. It takes the read-only parts of `ifconfig` and `netstat` and gives them one
clear command. It never changes anything (no addresses, no up/down), and no `ifconfig`, `netstat`, `scutil` or `networksetup` is
run: every number comes from Apple's APIs. Flag names follow Linux habits (`-tulpn`), because macOS `netstat -p` means a protocol
and here it means a program.

## Without options

The active interfaces with their names (`Wi-Fi`, `Thunderbolt 1`...), addresses, MAC, bytes received and sent, link state and the
default gateway. `--all` adds inactive and virtual interfaces (`utun`, `awdl`, `llw`...).

## Interfaces

| option | meaning |
|---|---|
| `--all` | also inactive and virtual interfaces |
| `-i` | packet, error and byte counters of every interface |
| `-b` | exact byte counts |

Byte counters are the 64-bit ones of the interface MIB (the 32-bit counters of `getifaddrs` wrap after 4 GiB).

## Sockets (any of these lists sockets)

| option | meaning |
|---|---|
| `-t -u -x` | TCP, UDP, UNIX sockets |
| `-4 -6` | IPv4 only / IPv6 only |
| `-l` | listening sockets only |
| `-a` | listening sockets and connections |
| `-p` | the program: `PID/PROGRAM` |
| `-n` | port numbers instead of service names |

Every TCP and UDP socket of the system is read without privilege; the owner is found for processes you may read (the others show
`-`, and a dim line says how many).

## Routes

`-r` prints the routing table and the DNS servers.

## Output

`--json` prints the same as JSON. Host names are never looked up.

## Examples

```sh
neonet -tulpn     # listening TCP and UDP ports with their programs
neonet -tp        # TCP connections with their programs
neonet -r         # routes and DNS servers
neonet -i         # counters of every interface
```

## What it is not

Not live: rates, traffic per process and refreshing tables belong to `neotop`. No driver settings (`rxcsum`, `tso`, `stp`). UNIX
sockets are listed only for processes you may read.
