#include "cshim.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/snapshot.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/socketvar.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <net/route.h>
#include <net/if_mib.h>
#include <net/ndrv.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp_var.h>

int neo_snapshot_names(const char *mountPoint, char *out, size_t capacity) {
    int fd = open(mountPoint, O_RDONLY);
    if (fd < 0) return -1;
    struct attrlist list;
    memset(&list, 0, sizeof list);
    list.bitmapcount = ATTR_BIT_MAP_COUNT;
    list.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME;
    static char buffer[64 * 1024];
    int total = 0;
    size_t used = 0;
    for (;;) {
        int n = fs_snapshot_list(fd, &list, buffer, sizeof buffer, 0);
        if (n < 0) { int e = errno; close(fd); errno = e; return -1; }
        if (n == 0) break;
        char *p = buffer;
        for (int i = 0; i < n; i++) {
            uint32_t length;
            memcpy(&length, p, sizeof length);
            char *field = p + sizeof(uint32_t) + sizeof(attribute_set_t);
            attrreference_t ref;
            memcpy(&ref, field, sizeof ref);
            const char *name = field + ref.attr_dataoffset;
            size_t len = strlen(name);
            if (used + len + 1 < capacity) { memcpy(out + used, name, len + 1); used += len + 1; }
            total++;
            p += length;
        }
    }
    close(fd);
    return total;
}

int neo_inet_sockets(int tcp, neo_inet_socket **out) {
    const char *name = tcp ? "net.inet.tcp.pcblist64" : "net.inet.udp.pcblist64";
    size_t length = 0;
    char *buffer = NULL;
    // the list can grow between the two calls: ask again with room to spare
    for (int attempt = 0; attempt < 5; attempt++) {
        if (sysctlbyname(name, NULL, &length, NULL, 0) != 0) return -1;
        length += length / 4 + 4096;
        buffer = malloc(length);
        if (!buffer) return -1;
        if (sysctlbyname(name, buffer, &length, NULL, 0) == 0) break;
        int e = errno;
        free(buffer); buffer = NULL;
        if (e != ENOMEM) { errno = e; return -1; }
    }
    if (!buffer) { errno = ENOMEM; return -1; }
    struct xinpgen *header = (struct xinpgen *)buffer;
    size_t capacity = header->xig_count + 16, count = 0;
    neo_inet_socket *list = calloc(capacity, sizeof *list);
    if (!list) { free(buffer); return -1; }
    // a record that is shorter than its structure, or that does not lie inside what the kernel gave us, ends the list (nothing is read past the buffer)
    size_t need = tcp ? sizeof(struct xtcpcb64) : sizeof(struct xinpcb64);
    if (header->xig_len > length) { free(list); free(buffer); errno = EINVAL; return -1; }
    char *p = buffer + header->xig_len;
    while (p < buffer + length && ((struct xinpgen *)p)->xig_len > sizeof(struct xinpgen)) {
        struct xinpgen *record = (struct xinpgen *)p;
        if (record->xig_len < need || (size_t)(p - buffer) + record->xig_len > length) break;
        struct xinpcb64 *inp = tcp ? &((struct xtcpcb64 *)p)->xt_inpcb : (struct xinpcb64 *)p;
        if (count == capacity) {
            capacity *= 2;
            neo_inet_socket *bigger = realloc(list, capacity * sizeof *list);
            if (!bigger) { free(list); free(buffer); return -1; }
            list = bigger;
            memset(list + count, 0, (capacity - count) * sizeof *list);
        }
        neo_inet_socket *s = &list[count++];
        s->tcp = tcp;
        s->v6 = (inp->inp_vflag & INP_IPV6) != 0;
        if (s->v6) {
            memcpy(s->local, &inp->inp_dependladdr.inp6_local, 16);
            memcpy(s->remote, &inp->inp_dependfaddr.inp6_foreign, 16);
        } else {
            memcpy(s->local, &inp->inp_dependladdr.inp46_local.ia46_addr4, 4);
            memcpy(s->remote, &inp->inp_dependfaddr.inp46_foreign.ia46_addr4, 4);
        }
        s->localPort = ntohs(inp->inp_lport);
        s->remotePort = ntohs(inp->inp_fport);
        s->state = tcp ? ((struct xtcpcb64 *)p)->t_state : 0;
        s->recvQueue = inp->xi_socket.so_rcv.sb_cc;
        s->sendQueue = inp->xi_socket.so_snd.sb_cc;
        s->socket = inp->xi_socket.xso_so;
        s->uid = inp->xi_socket.so_uid;
        p += record->xig_len;
    }
    free(buffer);
    *out = list;
    return (int)count;
}

int neo_link_active(const char *name) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    struct ifmediareq media;
    memset(&media, 0, sizeof media);
    strlcpy(media.ifm_name, name, sizeof media.ifm_name);
    int rc = ioctl(s, SIOCGIFMEDIA, &media);
    close(s);
    if (rc != 0 || !(media.ifm_status & IFM_AVALID)) return -1;
    return (media.ifm_status & IFM_ACTIVE) ? 1 : 0;
}

#define NEO_ALIGN(len) ((len) ? (((len) + 3) & ~3) : 4)

int neo_routes(neo_route **out) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP2, 0 };
    size_t length = 0;
    char *buffer = NULL;
    for (int attempt = 0; attempt < 5; attempt++) {
        if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0) return -1;
        length += length / 4 + 4096;
        buffer = malloc(length);
        if (!buffer) return -1;
        if (sysctl(mib, 6, buffer, &length, NULL, 0) == 0) break;
        int e = errno;
        free(buffer); buffer = NULL;
        if (e != ENOMEM) { errno = e; return -1; }
    }
    if (!buffer) { errno = ENOMEM; return -1; }
    size_t capacity = 256, count = 0;
    neo_route *list = calloc(capacity, sizeof *list);
    if (!list) { free(buffer); return -1; }
    for (char *p = buffer; p < buffer + length; ) {
        struct rt_msghdr2 *m = (struct rt_msghdr2 *)p;
        if (m->rtm_msglen == 0) break;
        char *next = p + m->rtm_msglen;
        if (m->rtm_type == RTM_GET2) {
            struct sockaddr *sa[RTAX_MAX];
            memset(sa, 0, sizeof sa);
            char *q = (char *)(m + 1);
            for (int i = 0; i < RTAX_MAX && q < next; i++) {
                if (!(m->rtm_addrs & (1 << i))) continue;
                sa[i] = (struct sockaddr *)q;
                q += NEO_ALIGN(sa[i]->sa_len);
            }
            struct sockaddr *dst = sa[RTAX_DST];
            if (dst && (dst->sa_family == AF_INET || dst->sa_family == AF_INET6)) {
                if (count == capacity) {
                    capacity *= 2;
                    neo_route *bigger = realloc(list, capacity * sizeof *list);
                    if (!bigger) { free(list); free(buffer); return -1; }
                    list = bigger;
                    memset(list + count, 0, (capacity - count) * sizeof *list);
                }
                neo_route *r = &list[count++];
                r->family = dst->sa_family;
                int v6 = dst->sa_family == AF_INET6;
                size_t offset = v6 ? 8 : 4, size = v6 ? 16 : 4;
                memcpy(r->dst, (char *)dst + offset, size);
                // the kernel keeps the interface scope of a link-local address in bytes 2 and 3
                if (v6 && r->dst[0] == 0xfe && (r->dst[1] & 0xc0) == 0x80) { r->dst[2] = 0; r->dst[3] = 0; }
                r->prefix = -1;
                struct sockaddr *mask = sa[RTAX_NETMASK];
                if (mask && !(m->rtm_flags & RTF_HOST)) {
                    int bits = 0;
                    size_t have = mask->sa_len > offset ? mask->sa_len - offset : 0;
                    if (have > size) have = size;
                    for (size_t i = 0; i < have; i++) {
                        unsigned char b = ((unsigned char *)mask)[offset + i];
                        for (int k = 7; k >= 0 && (b >> k) & 1; k--) bits++;
                    }
                    r->prefix = bits;
                } else if (!mask && !(m->rtm_flags & RTF_HOST)) {
                    r->prefix = 0;
                }
                struct sockaddr *gw = sa[RTAX_GATEWAY];
                if (gw && (gw->sa_family == AF_INET || gw->sa_family == AF_INET6)) {
                    r->gatewayKind = 1;
                    int g6 = gw->sa_family == AF_INET6;
                    memcpy(r->gateway, (char *)gw + (g6 ? 8 : 4), g6 ? 16 : 4);
                    if (g6 && r->gateway[0] == 0xfe && (r->gateway[1] & 0xc0) == 0x80) { r->gateway[2] = 0; r->gateway[3] = 0; }
                } else if (gw && gw->sa_family == AF_LINK) {
                    struct sockaddr_dl *dl = (struct sockaddr_dl *)gw;
                    r->gatewayKind = 2;
                    r->macLength = dl->sdl_alen > 6 ? 6 : dl->sdl_alen;
                    memcpy(r->mac, LLADDR(dl), r->macLength);
                }
                r->flags = m->rtm_flags;
                r->interfaceIndex = m->rtm_index;
                r->expire = (long)m->rtm_rmx.rmx_expire;
            }
        }
        p = next;
    }
    free(buffer);
    *out = list;
    return (int)count;
}

int neo_interface_stats_list(neo_interface_stats **out) {
    // NET_RT_IFLIST2 and getifaddrs hand out byte counters cut to 32 bits; the interface MIB (what netstat reads) has all 64.
    // The interfaces are asked for by their real indexes (if_nameindex): the numbers have gaps once an interface (a VPN's utun) has come and gone,
    // and the last interfaces lie beyond "the number of interfaces".
    struct if_nameindex *names = if_nameindex();
    if (!names) return -1;
    size_t total = 0;
    while (names[total].if_index != 0) total++;
    neo_interface_stats *list = calloc(total + 1, sizeof *list);
    if (!list) { if_freenameindex(names); return -1; }
    int count = 0;
    for (size_t k = 0; k < total; k++) {
        unsigned index = names[k].if_index;
        int mib[6] = { CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)index, IFDATA_GENERAL };
        struct ifmibdata data;
        size_t length = sizeof data;
        if (sysctl(mib, 6, &data, &length, NULL, 0) != 0) continue;       // gone between the two calls
        neo_interface_stats *s = &list[count++];
        s->index = index;
        strlcpy(s->name, data.ifmd_name, sizeof s->name);
        s->inputBytes = data.ifmd_data.ifi_ibytes;
        s->outputBytes = data.ifmd_data.ifi_obytes;
        s->inputPackets = data.ifmd_data.ifi_ipackets;
        s->outputPackets = data.ifmd_data.ifi_opackets;
        s->inputErrors = data.ifmd_data.ifi_ierrors;
        s->outputErrors = data.ifmd_data.ifi_oerrors;
        s->mtu = data.ifmd_data.ifi_mtu;
    }
    if_freenameindex(names);
    *out = list;
    return count;
}

// net.<proto>.pcblist_n: a sequence of records, each starting with {u32 length, u32 kind}. The layout is not in the SDK (xnu's private
// socketvar.h); the offsets below were found by comparing with lsof, nettop and known transfers (docs/commands/neotop.md).
static int neo_traffic_of(int tcp, const char *name, neo_traffic **list, size_t *count, size_t *capacity) {
    size_t length = 0;
    char *buffer = NULL;
    for (int attempt = 0; attempt < 5; attempt++) {
        if (sysctlbyname(name, NULL, &length, NULL, 0) != 0) return -1;
        length += length / 4 + 4096;
        buffer = malloc(length);
        if (!buffer) return -1;
        if (sysctlbyname(name, buffer, &length, NULL, 0) == 0) break;
        int e = errno;
        free(buffer); buffer = NULL;
        if (e != ENOMEM) { errno = e; return -1; }
    }
    if (!buffer) { errno = ENOMEM; return -1; }
    unsigned long long socket = 0;
    int pid = 0;
    for (size_t o = 0; o + 8 <= length;) {
        unsigned int l, kind;
        memcpy(&l, buffer + o, 4); memcpy(&kind, buffer + o + 4, 4);
        if (l == 0 || o + l > length) break;
        if (kind == 1 && l >= 72) {                       // XSO_SOCKET: the handle at 8, the last user's pid at 68
            memcpy(&socket, buffer + o + 8, 8); memcpy(&pid, buffer + o + 68, 4);
        } else if (kind == 8 && l >= 32) {                // XSO_STATS: rx packets, rx bytes, tx packets, tx bytes
            if (*count == *capacity) {
                *capacity = *capacity ? *capacity * 2 : 256;
                neo_traffic *bigger = realloc(*list, *capacity * sizeof **list);
                if (!bigger) { free(buffer); return -1; }
                *list = bigger;
            }
            neo_traffic *t = &(*list)[(*count)++];
            t->socket = socket; t->pid = pid; t->tcp = tcp;
            memcpy(&t->rx, buffer + o + 16, 8); memcpy(&t->tx, buffer + o + 32, 8);
        }
        o += (l + 7) & ~7u;
    }
    free(buffer);
    return 0;
}

int neo_socket_traffic(neo_traffic **out) {
    neo_traffic *list = NULL;
    size_t count = 0, capacity = 0;
    if (neo_traffic_of(1, "net.inet.tcp.pcblist_n", &list, &count, &capacity) != 0 || neo_traffic_of(0, "net.inet.udp.pcblist_n", &list, &count, &capacity) != 0) {
        free(list);
        return -1;
    }
    *out = list;
    return (int)count;
}
