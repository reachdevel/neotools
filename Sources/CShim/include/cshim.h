#ifndef NEO_CSHIM_H
#define NEO_CSHIM_H
#include <stddef.h>
#include <errno.h>
#include <mach/mach.h>

/// Names of the APFS snapshots of the volume mounted at `mountPoint`, NUL-separated into `out`.
/// Returns how many there are, or -1 with errno set.
int neo_snapshot_names(const char *mountPoint, char *out, size_t capacity);

/// One Internet socket of the system, as the kernel lists it (no privilege needed).
typedef struct {
    int v6;                       // 1: IPv6 (a dual-stack socket counts as IPv6), 0: IPv4
    int tcp;                      // 1: TCP, 0: UDP
    unsigned char local[16];      // IPv4: the first 4 bytes
    unsigned char remote[16];
    unsigned localPort, remotePort;
    int state;                    // TCP: 0 CLOSED, 1 LISTEN, 2 SYN_SENT, ... 10 TIME_WAIT
    unsigned recvQueue, sendQueue;
    unsigned long long socket;    // the kernel's handle for the socket (matches libproc's soi_so)
    unsigned uid;
} neo_inet_socket;

/// All TCP (tcp != 0) or UDP sockets. Returns how many, or -1 with errno set. Free `*out` with free().
int neo_inet_sockets(int tcp, neo_inet_socket **out);

/// Bytes a socket has carried so far, with the process that used it last. Counters of the sockets that are open (no privilege needed).
typedef struct {
    unsigned long long socket;    // the kernel's handle for the socket
    int pid;
    int tcp;                      // 1: TCP, 0: UDP
    unsigned long long rx, tx;    // received / sent, as the kernel counts them (the received count is a multiple of the bytes: see docs/commands/neotop.md)
} neo_traffic;

/// TCP and UDP together. Returns how many, or -1 with errno set. Free `*out` with free().
int neo_socket_traffic(neo_traffic **out);

/// 1: the link is active (cable in, Wi-Fi joined), 0: not, -1: the interface has no media status.
int neo_link_active(const char *name);

/// One routing table entry.
typedef struct {
    int family;                   // AF_INET, AF_INET6
    unsigned char dst[16];
    int prefix;                   // -1: a host route
    int gatewayKind;              // 0 none, 1 an address, 2 a link-level address (interface or MAC)
    unsigned char gateway[16];
    unsigned char mac[6];
    int macLength;
    int flags;                    // RTF_*
    unsigned interfaceIndex;
    long expire;                  // seconds since the epoch, 0: never
} neo_route;

/// The routing table (NET_RT_DUMP2). Returns how many entries, or -1 with errno set. Free `*out` with free().
int neo_routes(neo_route **out);

/// Counters of one interface, 64 bits wide (getifaddrs' own counters are 32 bits and wrap at 4 GiB).
typedef struct {
    unsigned index;
    char name[16];
    unsigned long long inputBytes, outputBytes, inputPackets, outputPackets, inputErrors, outputErrors;
    unsigned mtu;
} neo_interface_stats;

/// All interfaces with their counters (NET_RT_IFLIST2). Returns how many, or -1 with errno set. Free `*out` with free().
int neo_interface_stats_list(neo_interface_stats **out);

/// This process's own task port. Swift 6.0 refuses the imported variable `mach_task_self_` (shared mutable state) and has no function for it.
static inline mach_port_t neo_task_self(void) { return mach_task_self(); }

#endif
