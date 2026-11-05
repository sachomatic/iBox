#import "IBMSE.h"
#include <math.h>

static const double kSegment = 6.0;       // nominal HLS segment length (segments are cut on the next keyframe)
static const double kPTSBase = 10.0;      // keeps MPEG-TS timestamps positive
static const NSTimeInterval kWait = 60;   // a segment the player hasn't appended yet: wait this long

/* ================= byte helpers ================= */

static inline uint32_t BE16(const uint8_t *p) { return (uint32_t)p[0] << 8 | p[1]; }
static inline uint32_t BE24(const uint8_t *p) { return (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2]; }
static inline uint32_t BE32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static inline uint64_t BE64(const uint8_t *p) { return (uint64_t)BE32(p) << 32 | BE32(p + 4); }
static inline BOOL IsType(const uint8_t *t, const char *s) { return memcmp(t, s, 4) == 0; }

// Reads a box header at p (n bytes available). Returns NO if incomplete.
static BOOL BoxAt(const uint8_t *p, size_t n, uint64_t *size, size_t *header) {
    if (n < 8) return NO;
    uint64_t s = BE32(p);
    size_t h = 8;
    if (s == 1) {
        if (n < 16) return NO;
        s = BE64(p + 8);
        h = 16;
    } else if (s == 0) {
        s = n;
    }
    if (s < h) s = h;  // malformed: skip the header
    *size = s;
    *header = h;
    return YES;
}

/* ================= model ================= */

@interface IBMSESample : NSObject {
@public
    double dts, pts, dur;
    BOOL key;
    int nalLength;
}
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSArray *sps, *pps;  // the init segment this frame belongs to
@end
@implementation IBMSESample
@end

@interface IBMSETrack : NSObject {
@public
    BOOL video, audio, hasInit;
    uint32_t timescale, trackId;
    int64_t editMediaTime;
    uint32_t defDuration, defSize, defFlags;
    int nalLength;
    int aacObject, aacFreq, aacChannels;
    double offset;           // SourceBuffer.timestampOffset
    uint64_t streamPos;      // bytes of this SourceBuffer consumed so far
    uint64_t moofPos;
}
@property (nonatomic, strong) NSMutableArray *sps, *pps;
@property (nonatomic, strong) NSMutableData *pending;
@property (nonatomic, strong) NSData *moof;
@property (nonatomic, strong) NSMutableArray *samples;  // sorted by dts
@property (nonatomic, copy) NSString *codec;
@end
@implementation IBMSETrack
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _sps = [NSMutableArray array];
    _pps = [NSMutableArray array];
    _pending = [NSMutableData data];
    _samples = [NSMutableArray array];
    timescale = 90000;
    nalLength = 4;
    return self;
}
- (double)editShift { return timescale ? (double)editMediaTime / timescale : 0; }
@end

@interface IBMSESession : NSObject
@property (nonatomic, copy) NSString *sid;
@property (nonatomic) double duration;
@property (nonatomic) BOOL ended;
@property (nonatomic, strong) NSMutableDictionary *buffers;  // SourceBuffer id -> track
@property (nonatomic, strong) NSCondition *cond;
@property (nonatomic, strong) NSDate *created;
@property (nonatomic, strong) NSMutableArray *log;
@property (nonatomic) double readPosition;  // start of the last segment the <video> fetched
@property (nonatomic) double anchor;        // first keyframe time when the playlist was made
@property (nonatomic) NSInteger lead;       // segments before the anchor
@end
@implementation IBMSESession
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _buffers = [NSMutableDictionary dictionary];
    _cond = [NSCondition new];
    _created = [NSDate date];
    _log = [NSMutableArray array];
    return self;
}
- (void)note:(NSString *)line {
    [self.log addObject:[NSString stringWithFormat:@"%.1f %@", -[self.created timeIntervalSinceNow], line]];
    if (self.log.count > 60) [self.log removeObjectAtIndex:0];
}
- (IBMSETrack *)trackOfKind:(BOOL)video {
    for (IBMSETrack *t in self.buffers.allValues) if (t->hasInit && (video ? t->video : t->audio)) return t;
    return nil;
}
@end

static NSMutableDictionary *gSessions;   // sid -> session
static NSMutableArray *gSessionOrder;

/* ================= init segment ================= */

static void ParseESDS(IBMSETrack *t, const uint8_t *p, size_t n) {
    // Walks ES_Descriptor (3) -> DecoderConfigDescriptor (4) -> DecoderSpecificInfo (5).
    while (n > 2) {
        uint8_t tag = p[0];
        size_t i = 1, len = 0;
        for (int k = 0; k < 4 && i < n; k++) {
            uint8_t b = p[i++];
            len = len << 7 | (b & 0x7F);
            if (!(b & 0x80)) break;
        }
        if (i + len > n) len = n - i;
        const uint8_t *b = p + i;
        if (tag == 3 && len >= 3) {
            size_t skip = 3;
            uint8_t flags = b[2];
            if (flags & 0x80) skip += 2;
            if ((flags & 0x40) && len > skip) skip += 1 + b[skip];
            if (flags & 0x20) skip += 2;
            if (skip < len) ParseESDS(t, b + skip, len - skip);
        } else if (tag == 4 && len > 13) {
            ParseESDS(t, b + 13, len - 13);
        } else if (tag == 5 && len >= 2) {
            t->aacObject = b[0] >> 3;
            t->aacFreq = (b[0] & 7) << 1 | b[1] >> 7;
            t->aacChannels = (b[1] >> 3) & 0xF;
        }
        p += i + len;
        n -= i + len;
    }
}

static void WalkInit(IBMSETrack *t, const uint8_t *p, size_t n) {
    while (n >= 8) {
        uint64_t size;
        size_t h;
        if (!BoxAt(p, n, &size, &h) || size > n) break;
        const uint8_t *type = p + 4, *b = p + h;
        size_t bl = (size_t)size - h;
        if (IsType(type, "moov") || IsType(type, "trak") || IsType(type, "mdia") || IsType(type, "minf") ||
            IsType(type, "stbl") || IsType(type, "edts") || IsType(type, "mvex")) {
            WalkInit(t, b, bl);
        } else if (IsType(type, "tkhd") && bl >= 24) {
            t->trackId = BE32(b + (b[0] == 1 ? 20 : 12));
        } else if (IsType(type, "mdhd") && bl >= 24) {
            t->timescale = BE32(b + (b[0] == 1 ? 20 : 12));
        } else if (IsType(type, "hdlr") && bl >= 12) {
            if (IsType(b + 8, "vide")) t->video = YES;
            if (IsType(b + 8, "soun")) t->audio = YES;
        } else if (IsType(type, "elst") && bl >= 8) {
            uint32_t count = BE32(b + 4);
            size_t off = 8, entry = b[0] == 1 ? 20 : 12;
            for (uint32_t i = 0; i < count && off + entry <= bl; i++, off += entry) {
                int64_t mediaTime = b[0] == 1 ? (int64_t)BE64(b + off + 8) : (int32_t)BE32(b + off + 4);
                if (mediaTime >= 0) { t->editMediaTime = mediaTime; break; }
            }
        } else if (IsType(type, "stsd") && bl > 8) {
            WalkInit(t, b + 8, bl - 8);
        } else if ((IsType(type, "avc1") || IsType(type, "avc3")) && bl > 78) {
            t->video = YES;
            WalkInit(t, b + 78, bl - 78);
        } else if (IsType(type, "avcC") && bl >= 7) {
            t->nalLength = (b[4] & 3) + 1;
            t.codec = [NSString stringWithFormat:@"avc1.%02X%02X%02X", b[1], b[2], b[3]];
            [t.sps removeAllObjects];
            [t.pps removeAllObjects];
            size_t off = 6;
            for (int i = 0, ns = b[5] & 0x1F; i < ns && off + 2 <= bl; i++) {
                size_t len = BE16(b + off);
                if (off + 2 + len > bl) break;
                [t.sps addObject:[NSData dataWithBytes:b + off + 2 length:len]];
                off += 2 + len;
            }
            if (off < bl) {
                int np = b[off++];
                for (int i = 0; i < np && off + 2 <= bl; i++) {
                    size_t len = BE16(b + off);
                    if (off + 2 + len > bl) break;
                    [t.pps addObject:[NSData dataWithBytes:b + off + 2 length:len]];
                    off += 2 + len;
                }
            }
        } else if (IsType(type, "mp4a") && bl > 28) {
            t->audio = YES;
            t.codec = @"mp4a";
            WalkInit(t, b + 28, bl - 28);
        } else if (IsType(type, "esds") && bl > 4) {
            ParseESDS(t, b + 4, bl - 4);
        } else if (IsType(type, "trex") && bl >= 24) {
            t->defDuration = BE32(b + 12);
            t->defSize = BE32(b + 16);
            t->defFlags = BE32(b + 20);
        }
        p += size;
        n -= (size_t)size;
    }
}

/* ================= media segments ================= */

// Inserts samples (sorted by dts) into the track, replacing what they overlap
// (MSE semantics for re-appended ranges).
static void InsertSamples(IBMSETrack *t, NSArray *add) {
    if (!add.count) return;
    IBMSESample *first = add.firstObject, *last = add.lastObject;
    double from = first->dts - 0.0005, to = last->dts + last->dur - 0.0005;
    NSMutableArray *s = t.samples;
    IBMSESample *tail = s.lastObject;
    if (!tail || tail->dts < from) {
        [s addObjectsFromArray:add];
        return;
    }
    NSIndexSet *overlap = [s indexesOfObjectsPassingTest:^BOOL(IBMSESample *x, NSUInteger i, BOOL *stop) {
        return x->dts >= from && x->dts < to;
    }];
    [s removeObjectsAtIndexes:overlap];
    NSUInteger lo = 0, hi = s.count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (((IBMSESample *)s[mid])->dts < first->dts) lo = mid + 1; else hi = mid;
    }
    [s insertObjects:add atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(lo, add.count)]];
}

static void ParseFragment(IBMSETrack *t, NSData *moof, uint64_t moofPos, NSData *mdat, uint64_t mdatPayloadPos) {
    const uint8_t *m = moof.bytes;
    size_t mn = moof.length;
    NSMutableArray *added = [NSMutableArray array];
    // moof children
    uint64_t size; size_t h;
    if (!BoxAt(m, mn, &size, &h)) return;
    const uint8_t *p = m + h;
    size_t n = mn - h;
    while (n >= 8 && BoxAt(p, n, &size, &h) && size <= n) {
        if (IsType(p + 4, "traf")) {
            const uint8_t *q = p + h;
            size_t qn = (size_t)size - h;
            uint32_t dDur = t->defDuration, dSize = t->defSize, dFlags = t->defFlags;
            uint64_t base = moofPos, decode = 0;
            BOOL haveBase = NO;
            uint64_t nextData = 0;
            BOOL haveNext = NO;
            uint64_t s2; size_t h2;
            while (qn >= 8 && BoxAt(q, qn, &s2, &h2) && s2 <= qn) {
                const uint8_t *b = q + h2;
                size_t bl = (size_t)s2 - h2;
                if (IsType(q + 4, "tfhd") && bl >= 8) {
                    uint32_t flags = BE24(b + 1);
                    size_t off = 8;
                    if ((flags & 0x01) && off + 8 <= bl) { base = BE64(b + off); haveBase = YES; off += 8; }
                    if (flags & 0x02) off += 4;
                    if ((flags & 0x08) && off + 4 <= bl) { dDur = BE32(b + off); off += 4; }
                    if ((flags & 0x10) && off + 4 <= bl) { dSize = BE32(b + off); off += 4; }
                    if ((flags & 0x20) && off + 4 <= bl) { dFlags = BE32(b + off); off += 4; }
                    if (!haveBase) base = moofPos;
                } else if (IsType(q + 4, "tfdt") && bl >= 8) {
                    decode = b[0] == 1 && bl >= 12 ? BE64(b + 4) : BE32(b + 4);
                } else if (IsType(q + 4, "trun") && bl >= 8) {
                    uint32_t flags = BE24(b + 1), count = BE32(b + 4);
                    size_t off = 8;
                    uint64_t data = haveNext ? nextData : base;
                    if (flags & 0x01) { data = base + (int32_t)BE32(b + off); off += 4; }
                    uint32_t firstFlags = 0;
                    BOOL haveFirst = NO;
                    if (flags & 0x04) { firstFlags = BE32(b + off); haveFirst = YES; off += 4; }
                    for (uint32_t i = 0; i < count; i++) {
                        uint32_t dur = dDur, sz = dSize, sf = (i == 0 && haveFirst) ? firstFlags : dFlags;
                        int64_t cts = 0;
                        if (flags & 0x100) { if (off + 4 > bl) break; dur = BE32(b + off); off += 4; }
                        if (flags & 0x200) { if (off + 4 > bl) break; sz = BE32(b + off); off += 4; }
                        if (flags & 0x400) { if (off + 4 > bl) break; sf = BE32(b + off); off += 4; }
                        if (flags & 0x800) { if (off + 4 > bl) break; cts = b[0] ? (int32_t)BE32(b + off) : BE32(b + off); off += 4; }
                        if (data < mdatPayloadPos || data + sz > mdatPayloadPos + mdat.length) { data += sz; decode += dur; continue; }
                        IBMSESample *x = [IBMSESample new];
                        double ts = t->timescale ? t->timescale : 90000;
                        x->dts = decode / ts + t->offset;
                        x->pts = (decode + cts) / ts - [t editShift] + t->offset;
                        x->dur = dur / ts;
                        x->key = t->audio || !(sf & 0x00010000);
                        if (t->video) {
                            x->nalLength = t->nalLength;
                            x.sps = [t.sps copy];
                            x.pps = [t.pps copy];
                        }
                        x.data = [mdat subdataWithRange:NSMakeRange((NSUInteger)(data - mdatPayloadPos), sz)];
                        [added addObject:x];
                        data += sz;
                        decode += dur;
                    }
                    nextData = data;
                    haveNext = YES;
                }
                q += s2;
                qn -= (size_t)s2;
            }
        }
        p += size;
        n -= (size_t)size;
    }
    [added sortUsingComparator:^NSComparisonResult(IBMSESample *a, IBMSESample *b) {
        return a->dts < b->dts ? NSOrderedAscending : a->dts > b->dts ? NSOrderedDescending : NSOrderedSame;
    }];
    InsertSamples(t, added);
}

// Feeds appended bytes; complete top-level boxes are parsed, the rest waits.
static void Append(IBMSETrack *t, NSData *bytes) {
    [t.pending appendData:bytes];
    for (;;) {
        const uint8_t *p = t.pending.bytes;
        size_t n = t.pending.length;
        uint64_t size; size_t h;
        if (!BoxAt(p, n, &size, &h) || size > n) break;
        if (IsType(p + 4, "moov")) {
            WalkInit(t, p + h, (size_t)size - h);
            t->hasInit = t->video || t->audio;
        } else if (IsType(p + 4, "moof")) {
            t.moof = [NSData dataWithBytes:p length:(size_t)size];
            t->moofPos = t->streamPos;
        } else if (IsType(p + 4, "mdat") && t.moof) {
            NSData *payload = [NSData dataWithBytes:p + h length:(size_t)size - h];
            ParseFragment(t, t.moof, t->moofPos, payload, t->streamPos + h);
            t.moof = nil;
        }
        t->streamPos += size;
        [t.pending replaceBytesInRange:NSMakeRange(0, (size_t)size) withBytes:NULL length:0];
    }
}

static NSArray *Buffered(IBMSETrack *t) {
    NSMutableArray *ranges = [NSMutableArray array];
    double start = -1, end = -1;
    for (IBMSESample *s in t.samples) {
        double a = s->dts, b = s->dts + s->dur;
        if (start < 0) { start = a; end = b; continue; }
        if (a - end > 0.25) {
            [ranges addObject:@[@(start), @(end)]];
            start = a;
        }
        end = MAX(end, b);
    }
    if (start >= 0) [ranges addObject:@[@(start), @(end)]];
    return ranges;
}

static double BufferedEnd(IBMSETrack *t) {
    IBMSESample *s = t.samples.lastObject;
    return s ? s->dts + s->dur : -1;
}

/* ================= MPEG-TS ================= */

static uint32_t CRC32(const uint8_t *p, size_t n) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < n; i++) {
        crc ^= (uint32_t)p[i] << 24;
        for (int k = 0; k < 8; k++) crc = crc & 0x80000000 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
    }
    return crc;
}

enum { kPidPMT = 0x1000, kPidVideo = 0x100, kPidAudio = 0x101 };

typedef struct { uint8_t pat, pmt, video, audio; } CC;

static void WritePSI(NSMutableData *out, uint16_t pid, uint8_t *cc, const uint8_t *section, size_t len) {
    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof pkt);
    pkt[0] = 0x47;
    pkt[1] = 0x40 | (pid >> 8 & 0x1F);
    pkt[2] = pid & 0xFF;
    pkt[3] = 0x10 | (*cc & 0xF);
    *cc = (*cc + 1) & 0xF;
    pkt[4] = 0;  // pointer field
    memcpy(pkt + 5, section, len);
    [out appendBytes:pkt length:188];
}

static void WriteTables(NSMutableData *out, CC *cc, BOOL hasAudio) {
    uint8_t pat[16] = {0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0 | (kPidPMT >> 8), kPidPMT & 0xFF};
    uint32_t c = CRC32(pat, 12);
    pat[12] = c >> 24; pat[13] = c >> 16; pat[14] = c >> 8; pat[15] = c;
    WritePSI(out, 0, &cc->pat, pat, 16);

    uint8_t pmt[32];
    size_t n = 0;
    int streams = hasAudio ? 2 : 1;
    int sectionLength = 9 + 5 * streams + 4;
    uint8_t head[] = {0x02, 0xB0, (uint8_t)sectionLength, 0x00, 0x01, 0xC1, 0x00, 0x00,
                      0xE0 | (kPidVideo >> 8), kPidVideo & 0xFF, 0xF0, 0x00};
    memcpy(pmt, head, sizeof head);
    n = sizeof head;
    uint8_t v[] = {0x1B, 0xE0 | (kPidVideo >> 8), kPidVideo & 0xFF, 0xF0, 0x00};
    memcpy(pmt + n, v, 5); n += 5;
    if (hasAudio) {
        uint8_t a[] = {0x0F, 0xE0 | (kPidAudio >> 8), kPidAudio & 0xFF, 0xF0, 0x00};
        memcpy(pmt + n, a, 5); n += 5;
    }
    c = CRC32(pmt, n);
    pmt[n++] = c >> 24; pmt[n++] = c >> 16; pmt[n++] = c >> 8; pmt[n++] = c;
    WritePSI(out, kPidPMT, &cc->pmt, pmt, n);
}

static void PutTS(uint8_t *p, uint8_t prefix, uint64_t ts) {
    p[0] = (uint8_t)(prefix << 4 | ((ts >> 29) & 0x0E) | 1);
    p[1] = (uint8_t)(ts >> 22);
    p[2] = (uint8_t)(((ts >> 14) & 0xFE) | 1);
    p[3] = (uint8_t)(ts >> 7);
    p[4] = (uint8_t)(((ts << 1) & 0xFE) | 1);
}

static void WritePES(NSMutableData *out, uint16_t pid, uint8_t *cc, NSData *pes, int64_t pcr, BOOL randomAccess) {
    const uint8_t *d = pes.bytes;
    size_t len = pes.length, pos = 0;
    BOOL first = YES;
    while (pos < len) {
        uint8_t pkt[188];
        pkt[0] = 0x47;
        pkt[1] = (first ? 0x40 : 0) | (pid >> 8 & 0x1F);
        pkt[2] = pid & 0xFF;
        size_t remaining = len - pos;
        BOOL withPCR = first && pcr >= 0;
        size_t af = withPCR ? 8 : 0;  // adaptation field bytes, length byte included
        if (remaining < 184 - af) af = 184 - remaining;
        pkt[3] = (af ? 0x30 : 0x10) | (*cc & 0xF);
        *cc = (*cc + 1) & 0xF;
        size_t i = 4;
        if (af) {
            pkt[i++] = (uint8_t)(af - 1);
            if (af > 1) {
                uint8_t flags = (withPCR ? 0x10 : 0) | (first && randomAccess ? 0x40 : 0);
                pkt[i++] = flags;
                if (withPCR) {
                    uint64_t base = (uint64_t)pcr;
                    pkt[i++] = (uint8_t)(base >> 25);
                    pkt[i++] = (uint8_t)(base >> 17);
                    pkt[i++] = (uint8_t)(base >> 9);
                    pkt[i++] = (uint8_t)(base >> 1);
                    pkt[i++] = (uint8_t)((base & 1) << 7 | 0x7E);
                    pkt[i++] = 0;
                }
                while (i < 4 + af) pkt[i++] = 0xFF;
            }
        }
        size_t take = 188 - i;
        memcpy(pkt + i, d + pos, take);
        pos += take;
        first = NO;
        [out appendBytes:pkt length:188];
    }
}

static uint64_t Ticks(double seconds) { return (uint64_t)llround((seconds + kPTSBase) * 90000.0); }

static NSData *VideoPES(IBMSETrack *v, IBMSESample *s) {
    NSMutableData *es = [NSMutableData dataWithCapacity:s.data.length + 64];
    static const uint8_t sc[4] = {0, 0, 0, 1}, aud[2] = {0x09, 0xF0};
    [es appendBytes:sc length:4];
    [es appendBytes:aud length:2];
    if (s->key) {
        for (NSData *x in s.sps ?: v.sps) { [es appendBytes:sc length:4]; [es appendData:x]; }
        for (NSData *x in s.pps ?: v.pps) { [es appendBytes:sc length:4]; [es appendData:x]; }
    }
    const uint8_t *p = s.data.bytes;
    size_t n = s.data.length, off = 0;
    int L = s->nalLength ?: v->nalLength;
    while (off + L <= n) {
        size_t len = 0;
        for (int i = 0; i < L; i++) len = len << 8 | p[off + i];
        off += L;
        if (len == 0 || off + len > n) break;
        uint8_t type = p[off] & 0x1F;
        if (type != 9) {  // our own access unit delimiter is already there
            [es appendBytes:sc length:4];
            [es appendBytes:p + off length:len];
        }
        off += len;
    }
    uint64_t pts = Ticks(s->pts), dts = Ticks(s->dts);
    BOOL both = pts != dts;
    uint8_t head[19] = {0, 0, 1, 0xE0, 0, 0, 0x80, both ? 0xC0 : 0x80, both ? 10 : 5};
    PutTS(head + 9, both ? 3 : 2, pts);
    if (both) PutTS(head + 14, 1, dts);
    NSMutableData *pes = [NSMutableData dataWithBytes:head length:both ? 19 : 14];
    [pes appendData:es];
    return pes;
}

static NSData *AudioPES(IBMSETrack *a, NSArray *frames) {
    NSMutableData *es = [NSMutableData data];
    int profile = MAX(1, a->aacObject) - 1;
    for (IBMSESample *f in frames) {
        size_t len = f.data.length + 7;
        uint8_t h[7] = {0xFF, 0xF1,
                        (uint8_t)((profile & 3) << 6 | (a->aacFreq & 0xF) << 2 | (a->aacChannels >> 2 & 1)),
                        (uint8_t)((a->aacChannels & 3) << 6 | (len >> 11 & 3)),
                        (uint8_t)(len >> 3), (uint8_t)((len & 7) << 5 | 0x1F), 0xFC};
        [es appendBytes:h length:7];
        [es appendData:f.data];
    }
    IBMSESample *first = frames.firstObject;
    size_t pesLen = 3 + 5 + es.length;
    uint8_t head[14] = {0, 0, 1, 0xC0, (uint8_t)(pesLen > 0xFFFF ? 0 : pesLen >> 8), (uint8_t)(pesLen > 0xFFFF ? 0 : pesLen), 0x80, 0x80, 5};
    PutTS(head + 9, 2, Ticks(first->pts));
    NSMutableData *pes = [NSMutableData dataWithBytes:head length:14];
    [pes appendData:es];
    return pes;
}

/* ================= segments ================= */

// Segment layout of a session, fixed when the <video> first reads the playlist. A stream
// that starts mid-video (resume, quality switch, ad break) is anchored on its first
// keyframe T0: the stretch before it is split into "lead" segments, so the real segments
// start exactly at T0 and iOS's timeline has no gap to trip on.
static double SegStart(IBMSESession *s, NSInteger k) {
    if (k < s.lead) return k * s.anchor / s.lead;
    return s.anchor + (k - s.lead) * kSegment;
}

static NSInteger SegmentCount(IBMSESession *s) {
    if (s.duration <= 0) return 0;
    return s.lead + MAX(1, (NSInteger)ceil((s.duration - s.anchor) / kSegment - 0.001));
}

static double SegEnd(IBMSESession *s, NSInteger k) {
    return k + 1 >= SegmentCount(s) ? s.duration : SegStart(s, k + 1);
}

// Index of the first video keyframe with pts >= t (in decode order), NSNotFound if none yet.
static NSUInteger KeyAtOrAfter(IBMSETrack *v, double t) {
    NSArray *s = v.samples;
    NSUInteger lo = 0, hi = s.count;  // samples are sorted by dts: binary search a bit before t
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (((IBMSESample *)s[mid])->dts < t - 2) lo = mid + 1; else hi = mid;
    }
    for (NSUInteger i = lo; i < s.count; i++) {
        IBMSESample *x = s[i];
        if (x->key && x->pts >= t - 0.02) return i;
    }
    return NSNotFound;
}

// Samples cover [from, to] without a hole (the player removes ranges when it seeks or
// switches quality, then appends them again).
static BOOL Continuous(IBMSETrack *t, double from, double to, double tolerance) {
    double covered = from;
    for (IBMSESample *x in t.samples) {
        if (x->dts + x->dur <= from) continue;
        if (x->dts >= to) break;
        if (x->dts > covered + tolerance) return NO;
        covered = MAX(covered, x->dts + x->dur);
    }
    return covered >= to - tolerance;
}

static BOOL HasVideoIn(IBMSETrack *v, double from, double to) {
    for (IBMSESample *x in v.samples) {
        if (x->pts >= from && x->pts < to) return YES;
        if (x->dts >= to + 2) break;
    }
    return NO;
}

// A lead segment the player never appended anything for: silence only.
static BOOL IsFiller(IBMSESession *s, IBMSETrack *v, NSInteger k) {
    return k < s.lead && !HasVideoIn(v, SegStart(s, k) - 0.02, SegEnd(s, k) - 0.02);
}

// What a segment needs before it can be cut: video up to the keyframe that starts the
// next one (or the end), audio up to the same time.
static BOOL SegmentReady(IBMSESession *s, NSInteger k) {
    if (s.ended) return YES;
    IBMSETrack *v = [s trackOfKind:YES], *a = [s trackOfKind:NO];
    if (!v || !v.samples.count) return NO;
    if (IsFiller(s, v, k)) return YES;
    double start = SegStart(s, k), end = SegEnd(s, k);
    // There must be data in or just before this stretch; a gap (data appended further
    // on, after a seek) is waited for.
    BOOL near = NO;
    for (IBMSESample *x in v.samples) {
        if (x->dts >= start - 12 && x->dts < end) { near = YES; break; }
        if (x->dts >= end) break;
    }
    if (!near) return NO;
    BOOL last = k + 1 >= SegmentCount(s);
    double vEnd;
    if (last) {
        vEnd = s.duration - 0.3;
        if (BufferedEnd(v) < vEnd) return NO;
    } else {
        NSUInteger i = KeyAtOrAfter(v, end);
        if (i == NSNotFound) return NO;
        vEnd = ((IBMSESample *)v.samples[i])->pts;
    }
    NSUInteger first = KeyAtOrAfter(v, start);
    if (first == NSNotFound) return NO;
    if (((IBMSESample *)v.samples[first])->pts >= end - 0.02) {
        // Long keyframe interval: the segment repeats the group from the keyframe before.
        NSUInteger back = first;
        while (back > 0 && !(((IBMSESample *)v.samples[back])->key && ((IBMSESample *)v.samples[back])->pts <= start + 0.02)) back--;
        if (((IBMSESample *)v.samples[back])->key && ((IBMSESample *)v.samples[back])->pts <= start + 0.02) first = back;
    }
    double from = ((IBMSESample *)v.samples[first])->dts;
    if (!Continuous(v, from, vEnd - 0.1, 1.0)) return NO;
    return !a || Continuous(a, MAX(((IBMSESample *)v.samples[first])->pts, a.samples.count ? ((IBMSESample *)a.samples[0])->pts : 0), vEnd - 0.1, 0.5);
}

// Silent AAC frames covering [from, to).
static NSArray *Silence(IBMSETrack *a, double from, double to) {
    NSMutableArray *frames = [NSMutableArray array];
    if (!a || a->aacChannels < 1 || a->aacChannels > 2) return frames;
    static const uint8_t mono[] = {0x00, 0xC8, 0x00, 0x80, 0x23, 0x80};
    static const uint8_t stereo[] = {0x21, 0x00, 0x49, 0x90, 0x02, 0x19, 0x00, 0x23, 0x80};
    static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
    double rate = a->aacFreq < 13 ? rates[a->aacFreq] : 44100, frame = 1024.0 / rate;
    NSData *silent = a->aacChannels == 1 ? [NSData dataWithBytes:mono length:sizeof mono] : [NSData dataWithBytes:stereo length:sizeof stereo];
    for (double t = from; t < to - frame / 2; t += frame) {
        IBMSESample *f = [IBMSESample new];
        f->dts = f->pts = t;
        f->dur = frame;
        f->key = YES;
        f.data = silent;
        [frames addObject:f];
    }
    return frames;
}

static void WriteAudio(NSMutableData *out, IBMSETrack *a, CC *cc, NSArray *frames) {
    for (NSUInteger i = 0; i < frames.count; i += 6) {
        WritePES(out, kPidAudio, &cc->audio, AudioPES(a, [frames subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)6, frames.count - i))]), -1, NO);
    }
}

static NSData *BuildSegment(IBMSESession *s, NSInteger k, NSString **why) {
    IBMSETrack *v = [s trackOfKind:YES], *a = [s trackOfKind:NO];
    if (!v) { *why = @"no video track"; return nil; }
    double start = SegStart(s, k), end = SegEnd(s, k);
    if (IsFiller(s, v, k)) {
        NSMutableData *filler = [NSMutableData data];
        CC cc = {0, 0, 0, 0};
        WriteTables(filler, &cc, a != nil);
        WriteAudio(filler, a, &cc, Silence(a, start, end));
        [s note:[NSString stringWithFormat:@"seg%ld: silence %.2f-%.2f (stream starts at %.2f)", (long)k, start, end, s.anchor]];
        return filler;
    }
    BOOL last = k + 1 >= SegmentCount(s);
    NSUInteger from = KeyAtOrAfter(v, start);
    if (k == 0 && from != NSNotFound) {  // the very first frames, even before the first keyframe time
        NSUInteger first = 0;
        while (first < v.samples.count && !((IBMSESample *)v.samples[first])->key) first++;
        from = MIN(from, first);
    }
    if (from == NSNotFound || from >= v.samples.count) { *why = @"no keyframe yet"; return nil; }
    NSUInteger to = last ? v.samples.count : KeyAtOrAfter(v, end);
    if (to == NSNotFound) to = v.samples.count;
    if (to <= from) {
        // No keyframe in this stretch (long keyframe interval): repeat the group of
        // pictures that covers it, from its keyframe, so a seek landing here has a
        // picture to start from (in normal playback iOS drops what it already showed).
        NSUInteger back = from;
        while (back > 0 && !(((IBMSESample *)v.samples[back])->key && ((IBMSESample *)v.samples[back])->pts <= start + 0.02)) back--;
        if (((IBMSESample *)v.samples[back])->key && ((IBMSESample *)v.samples[back])->pts <= start + 0.02) {
            from = back;
            [s note:[NSString stringWithFormat:@"seg%ld: inside a long keyframe interval, repeating it from %.2f", (long)k,
                     ((IBMSESample *)v.samples[back])->pts]];
        } else {
            NSMutableData *empty = [NSMutableData data];
            CC cc = {0, 0, 0, 0};
            WriteTables(empty, &cc, a != nil);
            [s note:[NSString stringWithFormat:@"seg%ld: empty (long keyframe interval)", (long)k]];
            return empty;
        }
    }
    for (NSUInteger i = from + 1; i < to; i++) {  // never across a hole in the data
        IBMSESample *p = v.samples[i - 1], *x = v.samples[i];
        if (x->dts - (p->dts + p->dur) > 1.0) { to = i; break; }
    }
    double tStart = ((IBMSESample *)v.samples[from])->pts;
    double tEnd = 1e12;
    if (to < v.samples.count) {
        IBMSESample *next = v.samples[to], *prev = v.samples[to - 1];
        tEnd = next->key && next->dts - (prev->dts + prev->dur) <= 1.0 ? next->pts : prev->dts + prev->dur;
    }
    double aFrom = k == 0 ? -1e9 : tStart;

    NSMutableArray *audio = [NSMutableArray array];
    for (IBMSESample *x in a.samples) {
        if (x->pts >= aFrom - 0.0005 && x->pts < tEnd - 0.0005) [audio addObject:x];
    }
    // Audio that starts after the picture (first segment of a stream): pad with silence.
    double audioStart = audio.count ? ((IBMSESample *)audio[0])->pts : tEnd;
    if (a && (k == s.lead || k == 0) && audioStart > tStart + 0.05) {
        NSArray *pad = Silence(a, tStart, MIN(audioStart, tEnd));
        [audio insertObjects:pad atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, pad.count)]];
    }

    NSMutableData *out = [NSMutableData dataWithCapacity:3 * 1024 * 1024];
    CC cc = {0, 0, 0, 0};
    WriteTables(out, &cc, a != nil);
    NSUInteger ai = 0;
    for (NSUInteger i = from; i < to; i++) {
        IBMSESample *x = v.samples[i];
        // Audio that should be out before this video frame (by decode time), ~6 frames per PES.
        while (ai < audio.count && ((IBMSESample *)audio[ai])->pts <= x->dts + 0.1) {
            NSUInteger n = MIN((NSUInteger)6, audio.count - ai);
            WritePES(out, kPidAudio, &cc.audio, AudioPES(a, [audio subarrayWithRange:NSMakeRange(ai, n)]), -1, NO);
            ai += n;
        }
        int64_t pcr = (int64_t)Ticks(x->dts) - 9000;  // 100 ms before decode time
        WritePES(out, kPidVideo, &cc.video, VideoPES(v, x), MAX(0, pcr), x->key);
    }
    WriteAudio(out, a, &cc, [audio subarrayWithRange:NSMakeRange(ai, audio.count - ai)]);
    s.readPosition = tStart;
    [s note:[NSString stringWithFormat:@"seg%ld: video %.2f-%.2f (%lu frames), audio %lu frames, %lu KB", (long)k,
             tStart, tEnd < 1e11 ? tEnd : BufferedEnd(v), (unsigned long)(to - from), (unsigned long)audio.count,
             (unsigned long)out.length / 1024]];
    return out;
}

/* ================= routes ================= */

@implementation IBMSE

+ (IBMSESession *)session:(NSString *)sid create:(BOOL)create {
    @synchronized (self) {
        if (!gSessions) { gSessions = [NSMutableDictionary dictionary]; gSessionOrder = [NSMutableArray array]; }
        IBMSESession *s = gSessions[sid];
        if (!s && create) {
            s = [IBMSESession new];
            s.sid = sid;
            gSessions[sid] = s;
            [gSessionOrder addObject:sid];
            while (gSessionOrder.count > 2) {  // only the newest players are alive; free the rest
                IBMSESession *old = gSessions[gSessionOrder[0]];
                [old.cond lock];
                old.ended = YES;
                [old.buffers removeAllObjects];
                [old.cond broadcast];
                [old.cond unlock];
                [gSessions removeObjectForKey:gSessionOrder[0]];
                [gSessionOrder removeObjectAtIndex:0];
            }
        }
        return s;
    }
}

+ (void)installRoutes:(IBHTTPServer *)server {
    [server route:@"*" path:@"/mse/*" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSArray *parts = [r.path componentsSeparatedByString:@"/"];  // "", "mse", sid, action
        if (parts.count < 4) return [c sendText:@"bad path" status:400];
        NSString *sid = parts[2], *action = parts[3];
        BOOL post = [r.method isEqualToString:@"POST"];
        IBMSESession *s = [self session:sid create:YES];  // the <video> may ask before the first append
        if (!s) return [c sendText:@"no such session" status:404];
        NSString *sb = r.query[@"sb"] ?: @"0";

        if (post) {
            [s.cond lock];
            IBMSETrack *t = s.buffers[sb];
            if (!t && ([action isEqualToString:@"append"] || [action isEqualToString:@"remove"])) {
                t = [IBMSETrack new];
                s.buffers[sb] = t;
            }
            if ([action isEqualToString:@"append"]) {
                if (r.query[@"off"]) t->offset = [r.query[@"off"] doubleValue];
                NSUInteger before = t.samples.count;
                @try {
                    Append(t, r.body ?: [NSData data]);
                } @catch (NSException *e) {
                    [s note:[NSString stringWithFormat:@"append error: %@", e.reason]];
                }
                if (!before && t.samples.count) [s note:[NSString stringWithFormat:@"sb%@ first samples (%@)", sb, t.codec ?: @"?"]];
                // Free what the <video> has played (the player rarely removes anything
                // itself, and a long 720p video would not fit in the iPhone's memory).
                if (s.readPosition > 90) {
                    double keepFrom = s.readPosition - 60;
                    NSUInteger drop = 0;
                    while (drop < t.samples.count && ((IBMSESample *)t.samples[drop])->pts < keepFrom) drop++;
                    if (drop > 200) [t.samples removeObjectsInRange:NSMakeRange(0, drop)];
                }
            } else if ([action isEqualToString:@"remove"]) {
                double from = [r.query[@"s"] doubleValue], to = [r.query[@"e"] doubleValue];
                NSIndexSet *gone = [t.samples indexesOfObjectsPassingTest:^BOOL(IBMSESample *x, NSUInteger i, BOOL *stop) {
                    return x->dts >= from && x->dts < to;
                }];
                [t.samples removeObjectsAtIndexes:gone];
            } else if ([action isEqualToString:@"abort"]) {
                if (t) { [t.pending setLength:0]; t.moof = nil; }
            } else if ([action isEqualToString:@"duration"]) {
                double d = [r.query[@"d"] doubleValue];
                if (d > 0 && isfinite(d)) s.duration = d;
                [s note:[NSString stringWithFormat:@"duration %.2f", d]];
            } else if ([action isEqualToString:@"eos"]) {
                s.ended = YES;
                [s note:@"end of stream"];
            }
            NSArray *buffered = t ? Buffered(t) : @[];
            [s.cond broadcast];
            [s.cond unlock];
            return [c sendJSON:@{@"buffered": buffered}];
        }

        // GET: the page's <video> reading the HLS stream.
        if ([action isEqualToString:@"index.m3u8"]) {
            // Needs the duration, and the first keyframe to anchor the segments on.
            [s.cond lock];
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:30];
            for (;;) {
                IBMSETrack *v = [s trackOfKind:YES];
                if ((s.duration > 0 && v && KeyAtOrAfter(v, -1) != NSNotFound) || s.ended) break;
                if (![s.cond waitUntilDate:limit]) break;
            }
            if (s.duration > 0 && !s.lead) {
                IBMSETrack *v = [s trackOfKind:YES];
                NSUInteger key = v ? KeyAtOrAfter(v, -1) : NSNotFound;
                double t0 = key != NSNotFound ? ((IBMSESample *)v.samples[key])->pts : 0;
                if (t0 > 1 && t0 < s.duration - 1) {
                    s.anchor = t0;
                    s.lead = (NSInteger)ceil(t0 / kSegment - 0.001);
                }
                [s note:[NSString stringWithFormat:@"playlist: %.2f s, anchored at %.2f (%ld lead segments)", s.duration, s.anchor, (long)s.lead]];
            }
            double duration = s.duration;
            NSInteger count = SegmentCount(s);
            NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n"
                                  "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n", (int)ceil(kSegment * 2)];
            for (NSInteger k = 0; k < count; k++) {
                [m appendFormat:@"#EXTINF:%.3f,\nseg%ld.ts\n", MAX(0.1, SegEnd(s, k) - SegStart(s, k)), (long)k];
            }
            [s.cond unlock];
            if (duration <= 0) return [c sendText:@"no duration" status:503];
            [m appendString:@"#EXT-X-ENDLIST\n"];
            return [c sendData:[m dataUsingEncoding:NSUTF8StringEncoding] type:@"application/vnd.apple.mpegurl" status:200];
        }
        if ([action hasPrefix:@"seg"] && [action hasSuffix:@".ts"]) {
            NSInteger k = [[action substringWithRange:NSMakeRange(3, action.length - 6)] integerValue];
            [s.cond lock];
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:kWait];
            BOOL waited = NO;
            while (!SegmentReady(s, k)) {
                waited = YES;
                if (![s.cond waitUntilDate:limit]) break;
            }
            NSString *why = nil;
            NSData *seg = nil;
            @try {
                seg = BuildSegment(s, k, &why);
            } @catch (NSException *e) {
                why = e.reason;
            }
            if (!seg) [s note:[NSString stringWithFormat:@"seg%ld unavailable: %@%@", (long)k, why, waited ? @" (after waiting)" : @""]];
            [s.cond unlock];
            if (!seg) return [c sendText:why ?: @"unavailable" status:503];
            return [c sendData:seg type:@"video/mp2t" status:200];
        }
        [c sendText:@"unknown" status:404];
    }];

    [server route:@"GET" path:@"/api/debug/mse" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [c sendJSON:[self debugState]];
    }];
}

+ (void)closeAll {
    NSArray *sids;
    @synchronized (self) { sids = [gSessionOrder copy]; }
    for (NSString *sid in sids) {
        IBMSESession *s = [self session:sid create:NO];
        [s.cond lock];
        s.ended = YES;
        [s.buffers removeAllObjects];
        [s.cond broadcast];
        [s.cond unlock];
    }
    @synchronized (self) {
        [gSessions removeAllObjects];
        [gSessionOrder removeAllObjects];
    }
}

+ (NSDictionary *)debugState {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *order;
    @synchronized (self) { order = [gSessionOrder copy]; }
    for (NSString *sid in order) {
        IBMSESession *s = [self session:sid create:NO];
        if (!s) continue;
        [s.cond lock];
        NSMutableDictionary *bufs = [NSMutableDictionary dictionary];
        for (NSString *k in s.buffers) {
            IBMSETrack *t = s.buffers[k];
            NSUInteger bytes = 0, keys = 0;
            for (IBMSESample *x in t.samples) { bytes += x.data.length; keys += x->key; }
            bufs[k] = @{@"kind": t->video ? @"video" : t->audio ? @"audio" : @"?", @"codec": t.codec ?: @"",
                        @"samples": @(t.samples.count), @"keyframes": @(keys), @"KB": @(bytes / 1024),
                        @"buffered": Buffered(t), @"timescale": @(t->timescale), @"edit": @([t editShift]),
                        @"aac": @[@(t->aacObject), @(t->aacFreq), @(t->aacChannels)]};
        }
        [out addObject:@{@"sid": sid, @"duration": @(s.duration), @"ended": @(s.ended), @"buffers": bufs, @"log": [s.log copy]}];
        [s.cond unlock];
    }
    return @{@"sessions": out};
}

@end
