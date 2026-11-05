#import "IBServices.h"
#import "IBHTTP.h"
#import <CommonCrypto/CommonCryptor.h>

// Decides whether the iPhone 4 can play an HLS stream before handing it to AVPlayer:
// master playlist -> the variant iOS will start with -> its segment format -> the
// MPEG-TS stream types and H.264 header (SPS) of a real segment. iOS 6's HLS stack
// plays MPEG-TS segments with H.264 Baseline/Main up to level 3.1 and AAC/MP3 audio.

typedef struct {
    int videoType, audioTypes[4], audioCount;  // MPEG-TS stream_type values
    int profile, level;                         // from the first H.264 SPS, 0 if not found
} IBTSInfo;

static void ParseTS(const unsigned char *buf, size_t len, IBTSInfo *info) {
    memset(info, 0, sizeof *info);
    size_t start = 0;
    while (start < 188 && start < len && buf[start] != 0x47) start++;
    int pmtPid = -1, videoPid = -1;
    unsigned char es[4096];
    size_t esLen = 0;
    for (size_t off = start; off + 188 <= len; off += 188) {
        const unsigned char *p = buf + off;
        if (p[0] != 0x47) break;
        int pusi = p[1] & 0x40, pid = ((p[1] & 0x1F) << 8) | p[2], afc = (p[3] >> 4) & 3;
        size_t pos = 4;
        if (afc & 2) pos += 1 + p[4];
        if (!(afc & 1) || pos >= 188) continue;
        if (pid == 0 && pusi && pmtPid < 0) {  // PAT
            size_t s = pos + 1 + p[pos];
            int sectionLen = ((p[s + 1] & 0x0F) << 8) | p[s + 2];
            for (size_t i = s + 8; i + 4 <= s + 3 + sectionLen - 4 && i + 4 <= 188; i += 4) {
                int program = (p[i] << 8) | p[i + 1];
                if (program != 0) { pmtPid = ((p[i + 2] & 0x1F) << 8) | p[i + 3]; break; }
            }
        } else if (pid == pmtPid && pusi && videoPid < 0 && !info->videoType) {  // PMT
            size_t s = pos + 1 + p[pos];
            int sectionLen = ((p[s + 1] & 0x0F) << 8) | p[s + 2];
            int progInfoLen = ((p[s + 10] & 0x0F) << 8) | p[s + 11];
            size_t i = s + 12 + progInfoLen, end = MIN((size_t)188, s + 3 + sectionLen - 4);
            while (i + 5 <= end) {
                int type = p[i], epid = ((p[i + 1] & 0x1F) << 8) | p[i + 2];
                int esInfo = ((p[i + 3] & 0x0F) << 8) | p[i + 4];
                if ((type == 0x1B || type == 0x24 || type == 0x02 || type == 0x01 || type == 0x10) && !info->videoType) {
                    info->videoType = type;
                    videoPid = epid;
                } else if ((type == 0x0F || type == 0x11 || type == 0x03 || type == 0x04 || type == 0x81 || type == 0x87) && info->audioCount < 4) {
                    info->audioTypes[info->audioCount++] = type;
                }
                i += 5 + esInfo;
            }
        } else if (pid == videoPid && info->videoType == 0x1B && esLen < sizeof es - 188) {
            if (pusi && pos + 9 <= 188 && p[pos] == 0 && p[pos + 1] == 0 && p[pos + 2] == 1) pos += 9 + p[pos + 8];  // PES header
            if (pos < 188) {
                memcpy(es + esLen, p + pos, 188 - pos);
                esLen += 188 - pos;
            }
        }
    }
    for (size_t i = 0; i + 6 < esLen; i++) {  // first SPS: 00 00 01 | nal_type 7 | profile | constraints | level
        if (es[i] == 0 && es[i + 1] == 0 && es[i + 2] == 1 && (es[i + 3] & 0x1F) == 7) {
            info->profile = es[i + 4];
            info->level = es[i + 6];
            break;
        }
    }
}

static IBHTTPResponse *Fetch(NSString *url, NSDictionary *headers, NSUInteger maxBytes, NSError **error) {
    NSMutableData *data = [NSMutableData data];
    IBHTTPResponse *r = [IBHTTP syncRequest:url method:@"GET" headers:headers body:nil onHeaders:nil
                                     onData:^BOOL(const void *bytes, size_t n) {
        [data appendBytes:bytes length:n];
        return data.length < maxBytes;
    } error:error];
    r.body = data;
    return r;
}

static NSString *Absolute(NSString *uri, NSURL *base) {
    return [NSURL URLWithString:uri relativeToURL:base].absoluteString ?: uri;
}

static NSString *const kNeeds = @"which the iPhone 4 can't decode (it needs H.264 Main/Baseline up to 720p)";

static IBStreamVerdict CodecVerdict(IBTSInfo ts, NSString **reason);

// Not an .m3u8 URL: look at what the server actually sends.
static IBStreamVerdict ProbeOther(NSString *url, NSDictionary *headers, NSString **reason, NSString **hlsText) {
    NSError *error = nil;
    IBHTTPResponse *r = Fetch(url, headers, 262144, &error);
    if (!r) { *reason = [NSString stringWithFormat:@"the channel can't be reached (%@)", error.localizedDescription ?: @"no response"]; return IBStreamUnreachable; }
    if (r.status >= 400) { *reason = [NSString stringWithFormat:@"the channel is offline or blocked (HTTP %ld)", (long)r.status]; return IBStreamBlocked; }
    const unsigned char *b = r.body.bytes;
    NSUInteger n = r.body.length;
    NSString *head = [[NSString alloc] initWithData:[r.body subdataWithRange:NSMakeRange(0, MIN(n, (NSUInteger)64))] encoding:NSISOLatin1StringEncoding] ?: @"";
    if ([head rangeOfString:@"#EXTM3U"].location != NSNotFound) {  // HLS without the extension
        *hlsText = [r text];
        return IBStreamPlayable;
    }
    if (n >= 376 && (b[0] == 0x47 || b[188] == 0x47)) {
        IBTSInfo ts;
        ParseTS(b, n, &ts);
        IBStreamVerdict v = CodecVerdict(ts, reason);
        if (v != IBStreamPlayable) return v;
        *reason = @"this channel is a raw MPEG-TS stream (not HLS), which iOS can't play";
        return IBStreamIncompatible;
    }
    return IBStreamPlayable;  // MP4, MP3, AAC…: AVPlayer will try
}

static IBStreamVerdict ProbeSync(NSString *url, NSDictionary *headers, NSString **reason) {
    NSString *lower = [url lowercaseString];
    if ([lower rangeOfString:@".m3u8"].location == NSNotFound) {
        NSString *hls = nil;
        IBStreamVerdict v = ProbeOther(url, headers, reason, &hls);
        if (v != IBStreamPlayable || !hls) return v;
    }

    NSError *error = nil;
    IBHTTPResponse *master = Fetch(url, headers, 4 * 1024 * 1024, &error);
    NSInteger status = master.status;
    if (status == 401 || status == 403 || status == 451) {
        *reason = [NSString stringWithFormat:@"the channel refused the connection (HTTP %ld): it is geo-blocked, protected or offline", (long)status];
        return IBStreamBlocked;
    }
    if (status >= 400) { *reason = [NSString stringWithFormat:@"the channel is offline (HTTP %ld)", (long)status]; return IBStreamBlocked; }
    if (!master) { *reason = [NSString stringWithFormat:@"the channel can't be reached (%@)", error.localizedDescription ?: @"no response"]; return IBStreamUnreachable; }
    NSString *text = [master text] ?: @"";
    if ([text rangeOfString:@"#EXTM3U"].location == NSNotFound) { *reason = @"the channel didn't send a video playlist"; return IBStreamBlocked; }

    // 1. Master playlist: iOS starts with the first variant the proxy leaves in.
    NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *chosen = nil, *firstProblem = nil;
    BOOL isMaster = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (![lines[i] hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
        isMaster = YES;
        NSString *problem = IBVariantProblem(lines[i]);
        NSString *uri = nil;
        for (NSUInteger j = i + 1; j < lines.count && !uri; j++) {
            NSString *l = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (l.length && ![l hasPrefix:@"#"]) uri = l;
        }
        if (problem) { if (!firstProblem) firstProblem = problem; continue; }
        if (uri && !chosen) chosen = Absolute(uri, master.url);
    }
    if (isMaster && !chosen) {
        *reason = [NSString stringWithFormat:@"this channel only sends %@, %@", firstProblem ?: @"unsupported video", kNeeds];
        return IBStreamIncompatible;
    }

    // 2. Media playlist.
    IBHTTPResponse *media = master;
    NSString *mediaText = text;
    if (isMaster) {
        media = Fetch(chosen, headers, 4 * 1024 * 1024, &error);
        if (!media) { *reason = @"the channel's stream can't be reached"; return IBStreamUnreachable; }
        if (media.status >= 400) {
            *reason = [NSString stringWithFormat:@"the channel's stream is offline or blocked (HTTP %ld)", (long)media.status];
            return IBStreamBlocked;
        }
        mediaText = [media text] ?: @"";
        if ([mediaText rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound) return IBStreamPlayable;  // nested master: give up checking
    }
    if ([mediaText rangeOfString:@"#EXT-X-MAP"].location != NSNotFound) {
        *reason = [NSString stringWithFormat:@"this channel uses fragmented-MP4 (CMAF) segments, which need iOS 10 or later"];
        return IBStreamIncompatible;
    }
    if ([mediaText rangeOfString:@"METHOD=SAMPLE-AES"].location != NSNotFound) {
        *reason = @"this channel is DRM-protected (SAMPLE-AES)";
        return IBStreamIncompatible;
    }
    NSMutableArray *segments = [NSMutableArray array];
    for (NSString *raw in [mediaText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length && ![l hasPrefix:@"#"]) [segments addObject:l];
    }
    if (segments.count == 0) { *reason = @"the channel's playlist is empty (off air)"; return IBStreamBlocked; }
    BOOL vod = [mediaText rangeOfString:@"#EXT-X-ENDLIST"].location != NSNotFound;
    NSString *segment = Absolute(vod ? segments.firstObject : segments.lastObject, media.url);
    NSString *segPath = [[[NSURL URLWithString:segment].path lowercaseString] ?: @"" copy];
    for (NSString *ext in @[@".m4s", @".mp4", @".cmfv", @".m4v", @".cmfa"]) {
        if ([segPath hasSuffix:ext]) {
            *reason = @"this channel uses fragmented-MP4 (CMAF) segments, which need iOS 10 or later";
            return IBStreamIncompatible;
        }
    }
    for (NSString *ext in @[@".aac", @".mp3", @".ac3"]) {
        if ([segPath hasSuffix:ext]) return [ext isEqualToString:@".ac3"] ? IBStreamIncompatible : IBStreamPlayable;
    }

    // AES-128 segments: find the key and IV in effect for the chosen segment, like a
    // player would (the IV defaults to the segment's media sequence number).
    NSString *keyURI = nil, *ivHex = nil;
    long long sequence = 0, index = -1, chosenIndex = vod ? 0 : (long long)segments.count - 1;
    NSRegularExpression *keyRe = [NSRegularExpression regularExpressionWithPattern:@"METHOD=([A-Z0-9-]+)(?:.*?URI=\"([^\"]+)\")?(?:.*?IV=0[xX]([0-9a-fA-F]+))?" options:0 error:NULL];
    for (NSString *raw in [mediaText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) sequence = [[l substringFromIndex:22] longLongValue];
        else if ([l hasPrefix:@"#EXT-X-KEY:"]) {
            NSTextCheckingResult *m = [keyRe firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
            BOOL aes = m && [[l substringWithRange:[m rangeAtIndex:1]] isEqualToString:@"AES-128"];
            keyURI = aes && [m rangeAtIndex:2].location != NSNotFound ? [l substringWithRange:[m rangeAtIndex:2]] : nil;
            ivHex = aes && [m rangeAtIndex:3].location != NSNotFound ? [l substringWithRange:[m rangeAtIndex:3]] : nil;
        } else if (l.length && ![l hasPrefix:@"#"] && ++index == chosenIndex) {
            break;
        }
    }
    NSData *key = nil;
    if (keyURI) {
        IBHTTPResponse *k = Fetch(Absolute(keyURI, media.url), headers, 64, &error);
        if (!k || k.status >= 400 || k.body.length < 16) return IBStreamPlayable;  // can't peek: let AVPlayer try
        key = [k.body subdataWithRange:NSMakeRange(0, 16)];
    }

    // 3. A real segment: stream types and the H.264 profile/level.
    NSMutableDictionary *segHeaders = [headers ?: @{} mutableCopy];
    segHeaders[@"Range"] = @"bytes=0-262143";
    IBHTTPResponse *seg = Fetch(segment, segHeaders, 262144, &error);
    if (!seg) { *reason = @"the channel's video can't be reached"; return IBStreamUnreachable; }
    if (seg.status >= 400) {
        *reason = [NSString stringWithFormat:@"the channel's video is offline or blocked (HTTP %ld)", (long)seg.status];
        return IBStreamBlocked;
    }
    NSData *body = seg.body;
    if (key) {
        unsigned char iv[16] = {0};
        if (ivHex.length) {
            NSString *hex = ivHex.length > 32 ? [ivHex substringFromIndex:ivHex.length - 32] : ivHex;
            hex = [[@"" stringByPaddingToLength:32 - hex.length withString:@"0" startingAtIndex:0] stringByAppendingString:hex];
            for (int i = 0; i < 16; i++) {
                unsigned v = 0;
                [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i * 2, 2)]] scanHexInt:&v];
                iv[i] = (unsigned char)v;
            }
        } else {
            unsigned long long n = (unsigned long long)(sequence + MAX(index, 0));
            for (int i = 0; i < 8; i++) iv[15 - i] = (unsigned char)(n >> (8 * i));
        }
        size_t len = body.length & ~(size_t)15, moved = 0;  // CBC decrypts any 16-byte-aligned prefix
        NSMutableData *plain = [NSMutableData dataWithLength:len];
        if (CCCrypt(kCCDecrypt, kCCAlgorithmAES128, 0, key.bytes, 16, iv, body.bytes, len,
                    plain.mutableBytes, len, &moved) != kCCSuccess) return IBStreamPlayable;
        body = plain;
    }
    IBTSInfo ts;
    ParseTS(body.bytes, body.length, &ts);
    return CodecVerdict(ts, reason);
}

static IBStreamVerdict CodecVerdict(IBTSInfo ts, NSString **reason) {
    if (ts.videoType == 0x24) { *reason = [NSString stringWithFormat:@"this channel sends HEVC video, %@", kNeeds]; return IBStreamIncompatible; }
    if (ts.videoType == 0x01 || ts.videoType == 0x02) { *reason = [NSString stringWithFormat:@"this channel sends MPEG-2 video, %@", kNeeds]; return IBStreamIncompatible; }
    if (ts.videoType == 0x10) { *reason = [NSString stringWithFormat:@"this channel sends MPEG-4 Part 2 video, %@", kNeeds]; return IBStreamIncompatible; }
    if (ts.profile && ts.profile != 66 && ts.profile != 77) {
        *reason = [NSString stringWithFormat:@"this channel only sends %@, %@",
                   ts.profile == 100 ? @"H.264 High profile video" : [NSString stringWithFormat:@"H.264 profile %d video", ts.profile], kNeeds];
        return IBStreamIncompatible;
    }
    if (ts.level > 31) {
        *reason = [NSString stringWithFormat:@"this channel only sends H.264 level %.1f video, %@", ts.level / 10.0, kNeeds];
        return IBStreamIncompatible;
    }
    if (ts.audioCount) {
        BOOL usable = NO;
        for (int i = 0; i < ts.audioCount; i++) if (ts.audioTypes[i] != 0x81 && ts.audioTypes[i] != 0x87) usable = YES;
        if (!usable) { *reason = @"this channel only sends Dolby Digital audio, which the iPhone 4 can't decode"; return IBStreamIncompatible; }
    }
    return IBStreamPlayable;
}

void IBProbeStream(NSString *url, NSDictionary *headers, void (^done)(IBStreamVerdict verdict, NSString *reason)) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reason = nil;
        IBStreamVerdict v;
        @autoreleasepool { v = ProbeSync(url, headers, &reason); }
        dispatch_async(dispatch_get_main_queue(), ^{ done(v, reason); });
    });
}
