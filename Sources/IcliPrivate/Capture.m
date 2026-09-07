#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <poll.h>
#include <sys/ioccom.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

// The iOS SDK ships no <net/bpf.h>; these are XNU's stable definitions.
struct bpf_hdr {
    struct { int32_t tv_sec; int32_t tv_usec; } bh_tstamp;
    uint32_t bh_caplen;
    uint32_t bh_datalen;
    unsigned short bh_hdrlen;
};
#define BPF_WORDALIGN(x) (((x) + 3) & ~3)
#define BIOCGBLEN _IOR('B', 102, unsigned)
#define BIOCGDLT _IOR('B', 106, unsigned)
#define BIOCSETIF _IOW('B', 108, struct ifreq)
#define BIOCIMMEDIATE _IOW('B', 112, unsigned)
enum { DLT_NULL = 0, DLT_EN10MB = 1, DLT_RAW = 12 };

// Packet capture straight from a BPF device, written as a classic pcap file.
// Filters are a small subset of tcpdump syntax evaluated in user space:
//   [tcp|udp|icmp] [src|dst] port N ... [src|dst] host A ... joined by "and".

typedef struct {
    int protocol;         // -1 any, IPPROTO_*
    int port, srcPort, dstPort;
    char host[64], srcHost[64], dstHost[64];
} CaptureFilter;

typedef struct {
    int family;           // 0 unparsed, AF_INET, AF_INET6
    int protocol;
    char src[64], dst[64];
    int srcPort, dstPort;
} PacketSummary;

static char *captureJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static bool parseFilter(const char *text, CaptureFilter *filter) {
    memset(filter, 0, sizeof(*filter));
    filter->protocol = -1;
    filter->port = filter->srcPort = filter->dstPort = -1;
    if (!text || !*text) return true;
    NSArray *tokens = [[@(text) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    int direction = 0; // 0 either, 1 src, 2 dst
    for (NSUInteger i = 0; i < tokens.count; i++) {
        NSString *token = [tokens[i] lowercaseString];
        if ([token isEqualToString:@"and"]) { direction = 0; continue; }
        if ([token isEqualToString:@"tcp"]) { filter->protocol = IPPROTO_TCP; continue; }
        if ([token isEqualToString:@"udp"]) { filter->protocol = IPPROTO_UDP; continue; }
        if ([token isEqualToString:@"icmp"]) { filter->protocol = IPPROTO_ICMP; continue; }
        if ([token isEqualToString:@"src"]) { direction = 1; continue; }
        if ([token isEqualToString:@"dst"]) { direction = 2; continue; }
        if (i + 1 >= tokens.count) return false;
        NSString *value = tokens[++i];
        if ([token isEqualToString:@"port"]) {
            int port = value.intValue;
            if (port <= 0 || port > 65535) return false;
            *(direction == 1 ? &filter->srcPort : direction == 2 ? &filter->dstPort : &filter->port) = port;
        } else if ([token isEqualToString:@"host"]) {
            if (value.length >= 64) return false;
            strlcpy(direction == 1 ? filter->srcHost : direction == 2 ? filter->dstHost : filter->host, value.UTF8String, 64);
        } else {
            return false;
        }
        direction = 0;
    }
    return true;
}

static void parsePacket(const unsigned char *bytes, size_t length, unsigned dlt, PacketSummary *summary) {
    memset(summary, 0, sizeof(*summary));
    size_t offset = 0;
    if (dlt == DLT_NULL) {
        if (length < 4) return;
        uint32_t family;
        memcpy(&family, bytes, 4);
        summary->family = family == AF_INET ? AF_INET : family == AF_INET6 ? AF_INET6 : 0;
        offset = 4;
    } else if (dlt == DLT_EN10MB) {
        if (length < 14) return;
        uint16_t type = (uint16_t)((bytes[12] << 8) | bytes[13]);
        summary->family = type == 0x0800 ? AF_INET : type == 0x86dd ? AF_INET6 : 0;
        offset = 14;
    } else if (dlt == DLT_RAW) {
        summary->family = length > 0 && (bytes[0] >> 4) == 6 ? AF_INET6 : AF_INET;
    } else {
        return;
    }
    if (!summary->family) return;
    size_t transport = 0;
    if (summary->family == AF_INET) {
        if (length < offset + sizeof(struct ip)) { summary->family = 0; return; }
        const struct ip *header = (const struct ip *)(bytes + offset);
        inet_ntop(AF_INET, &header->ip_src, summary->src, sizeof(summary->src));
        inet_ntop(AF_INET, &header->ip_dst, summary->dst, sizeof(summary->dst));
        summary->protocol = header->ip_p;
        transport = offset + (size_t)header->ip_hl * 4;
    } else {
        if (length < offset + sizeof(struct ip6_hdr)) { summary->family = 0; return; }
        const struct ip6_hdr *header = (const struct ip6_hdr *)(bytes + offset);
        inet_ntop(AF_INET6, &header->ip6_src, summary->src, sizeof(summary->src));
        inet_ntop(AF_INET6, &header->ip6_dst, summary->dst, sizeof(summary->dst));
        summary->protocol = header->ip6_nxt;
        transport = offset + sizeof(struct ip6_hdr);
    }
    if ((summary->protocol == IPPROTO_TCP || summary->protocol == IPPROTO_UDP) && length >= transport + 4) {
        summary->srcPort = (bytes[transport] << 8) | bytes[transport + 1];
        summary->dstPort = (bytes[transport + 2] << 8) | bytes[transport + 3];
    }
}

static bool matchesFilter(const PacketSummary *summary, const CaptureFilter *filter) {
    bool any = filter->protocol < 0 && filter->port < 0 && filter->srcPort < 0 && filter->dstPort < 0 && !filter->host[0] && !filter->srcHost[0] && !filter->dstHost[0];
    if (any) return true;
    if (!summary->family) return false;
    if (filter->protocol >= 0 && summary->protocol != filter->protocol) return false;
    if (filter->port >= 0 && summary->srcPort != filter->port && summary->dstPort != filter->port) return false;
    if (filter->srcPort >= 0 && summary->srcPort != filter->srcPort) return false;
    if (filter->dstPort >= 0 && summary->dstPort != filter->dstPort) return false;
    if (filter->host[0] && strcmp(summary->src, filter->host) != 0 && strcmp(summary->dst, filter->host) != 0) return false;
    if (filter->srcHost[0] && strcmp(summary->src, filter->srcHost) != 0) return false;
    if (filter->dstHost[0] && strcmp(summary->dst, filter->dstHost) != 0) return false;
    return true;
}

static NSDictionary *summaryDictionary(const PacketSummary *summary, uint32_t length) {
    if (!summary->family) return @{@"protocol": @"other", @"bytes": @(length)};
    NSString *protocol = summary->protocol == IPPROTO_TCP ? @"tcp" : summary->protocol == IPPROTO_UDP ? @"udp" : summary->protocol == IPPROTO_ICMP ? @"icmp" : summary->protocol == IPPROTO_ICMPV6 ? @"icmpv6" : [NSString stringWithFormat:@"ip-%d", summary->protocol];
    return @{@"protocol": protocol, @"src": @(summary->src), @"dst": @(summary->dst), @"src_port": @(summary->srcPort), @"dst_port": @(summary->dstPort), @"bytes": @(length)};
}

char *icli_capture_packets_json(const char *interface, const char *filter_text, double seconds, const char *output_path) {
    CaptureFilter filter;
    if (!parseFilter(filter_text, &filter)) return captureJSON(@{@"error": @"unsupported filter; use [tcp|udp|icmp] [src|dst] port N [src|dst] host A joined by and"});
    int fd = -1;
    for (int i = 0; i < 256 && fd < 0; i++) {
        char device[32];
        snprintf(device, sizeof(device), "/dev/bpf%d", i);
        fd = open(device, O_RDWR);
        if (fd < 0 && errno != EBUSY) break;
    }
    if (fd < 0) return captureJSON(@{@"error": [NSString stringWithFormat:@"no BPF device available: %s (root required)", strerror(errno)]});
    struct ifreq request = {0};
    strlcpy(request.ifr_name, interface, sizeof(request.ifr_name));
    unsigned immediate = 1, bufferLength = 0, dlt = 0;
    if (ioctl(fd, BIOCSETIF, &request) < 0 || ioctl(fd, BIOCIMMEDIATE, &immediate) < 0 || ioctl(fd, BIOCGBLEN, &bufferLength) < 0 || ioctl(fd, BIOCGDLT, &dlt) < 0) {
        int error = errno;
        close(fd);
        return captureJSON(@{@"error": [NSString stringWithFormat:@"BPF setup failed for %s: %s", interface, strerror(error)]});
    }
    FILE *output = fopen(output_path, "wb");
    if (!output) { int error = errno; close(fd); return captureJSON(@{@"error": [NSString stringWithFormat:@"cannot write %s: %s", output_path, strerror(error)]}); }
    uint32_t header[6] = {0xa1b2c3d4, 0x00040002, 0, 0, 65535, dlt};
    header[1] = 2 | (4 << 16);
    fwrite(header, sizeof(header), 1, output);
    unsigned char *buffer = malloc(bufferLength);
    NSMutableArray *packets = [NSMutableArray array];
    uint64_t count = 0, bytes = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        struct pollfd poller = {fd, POLLIN, 0};
        if (poll(&poller, 1, 200) <= 0) continue;
        ssize_t got = read(fd, buffer, bufferLength);
        if (got <= 0) { if (got < 0 && errno != EINTR && errno != EAGAIN) break; continue; }
        for (size_t offset = 0; offset + sizeof(struct bpf_hdr) <= (size_t)got;) {
            const struct bpf_hdr *record = (const struct bpf_hdr *)(buffer + offset);
            const unsigned char *packet = buffer + offset + record->bh_hdrlen;
            if (offset + record->bh_hdrlen + record->bh_caplen > (size_t)got) break;
            PacketSummary summary;
            parsePacket(packet, record->bh_caplen, dlt, &summary);
            if (matchesFilter(&summary, &filter)) {
                uint32_t recordHeader[4] = {(uint32_t)record->bh_tstamp.tv_sec, (uint32_t)record->bh_tstamp.tv_usec, record->bh_caplen, record->bh_datalen};
                fwrite(recordHeader, sizeof(recordHeader), 1, output);
                fwrite(packet, record->bh_caplen, 1, output);
                count++;
                bytes += record->bh_caplen;
                if (packets.count < 50) [packets addObject:summaryDictionary(&summary, record->bh_datalen)];
            }
            offset += BPF_WORDALIGN(record->bh_hdrlen + record->bh_caplen);
        }
    }
    free(buffer);
    close(fd);
    bool flushed = fclose(output) == 0;
    NSString *linkType = dlt == DLT_NULL ? @"null" : dlt == DLT_EN10MB ? @"ethernet" : dlt == DLT_RAW ? @"raw" : [NSString stringWithFormat:@"dlt-%u", dlt];
    if (!flushed) return captureJSON(@{@"error": @"capture file could not be written"});
    return captureJSON(@{@"path": @(output_path), @"interface": @(interface), @"link_type": linkType, @"filter": filter_text ? @(filter_text) : @"", @"packets": @(count), @"bytes": @(bytes), @"summary": packets});
}
