#import "IBRemoteAPI.h"
#import "IBHTTP.h"
#import "IBTV.h"
#import "IBPlayer.h"
#import "IBMSE.h"
#import "IBServices.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>

static NSString *ProxyURL(NSString *absolute, NSDictionary *headers) {
    return IBPlayableURLWithHeaders(absolute, headers);
}

static NSArray *TagValue(NSString *line, NSString *tag) {  // @[value] when line is "tag:value"
    return [line hasPrefix:tag] ? @[[line substringFromIndex:tag.length]] : nil;
}

// Live media playlists with a long DVR window (some channels publish hours of
// segments) are too big for the A4 to rewrite every few seconds. Keep only the
// newest segments, shifting the sequence numbers and carrying the active key/map.
static NSArray *TrimLivePlaylist(NSArray *lines, NSUInteger keep) {
    BOOL media = NO, ended = NO;
    for (NSString *l in lines) {
        if ([l hasPrefix:@"#EXTINF"]) media = YES;
        if ([l hasPrefix:@"#EXT-X-ENDLIST"]) ended = YES;
    }
    if (!media || ended) return lines;

    NSArray *headerTags = @[@"#EXTM3U", @"#EXT-X-VERSION", @"#EXT-X-TARGETDURATION", @"#EXT-X-MEDIA-SEQUENCE",
                            @"#EXT-X-DISCONTINUITY-SEQUENCE", @"#EXT-X-PLAYLIST-TYPE", @"#EXT-X-ALLOW-CACHE",
                            @"#EXT-X-INDEPENDENT-SEGMENTS", @"#EXT-X-START"];
    NSMutableArray *header = [NSMutableArray array], *segments = [NSMutableArray array], *pending = [NSMutableArray array];
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0) continue;
        BOOL isHeader = NO;
        for (NSString *t in headerTags) if ([l hasPrefix:t]) isHeader = YES;
        if (isHeader) [header addObject:l];
        else if ([l hasPrefix:@"#"]) [pending addObject:l];
        else {
            [pending addObject:l];
            [segments addObject:[pending copy]];
            [pending removeAllObjects];
        }
    }
    if (segments.count <= keep) return lines;

    NSUInteger drop = segments.count - keep, discontinuities = 0;
    NSString *key = nil, *map = nil;
    for (NSUInteger i = 0; i < drop; i++) {
        for (NSString *l in segments[i]) {
            if ([l hasPrefix:@"#EXT-X-KEY"]) key = l;
            if ([l hasPrefix:@"#EXT-X-MAP"]) map = l;
            if ([l hasPrefix:@"#EXT-X-DISCONTINUITY"] && ![l hasPrefix:@"#EXT-X-DISCONTINUITY-SEQUENCE"]) discontinuities++;
        }
    }
    NSMutableArray *out = [NSMutableArray array];
    BOOL sawDiscSeq = NO;
    for (NSString *l in header) {
        NSArray *v;
        if ((v = TagValue(l, @"#EXT-X-MEDIA-SEQUENCE:"))) {
            [out addObject:[NSString stringWithFormat:@"#EXT-X-MEDIA-SEQUENCE:%lld", [v[0] longLongValue] + (long long)drop]];
        } else if ((v = TagValue(l, @"#EXT-X-DISCONTINUITY-SEQUENCE:"))) {
            sawDiscSeq = YES;
            [out addObject:[NSString stringWithFormat:@"#EXT-X-DISCONTINUITY-SEQUENCE:%lld", [v[0] longLongValue] + (long long)discontinuities]];
        } else {
            [out addObject:l];
        }
    }
    if (!sawDiscSeq && discontinuities) [out addObject:[NSString stringWithFormat:@"#EXT-X-DISCONTINUITY-SEQUENCE:%lu", (unsigned long)discontinuities]];
    NSArray *first = segments[drop];
    if (key && ![[first filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '#EXT-X-KEY'"]] count]) [out addObject:key];
    if (map && ![[first filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '#EXT-X-MAP'"]] count]) [out addObject:map];
    for (NSUInteger i = drop; i < segments.count; i++) [out addObjectsFromArray:segments[i]];
    return out;
}

static NSString *AttrValue(NSString *line, NSString *name) {
    NSString *pattern = [NSString stringWithFormat:@"(?<=[:,])%@=(\"[^\"]*\"|[^,]*)", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!m) return nil;
    NSString *v = [line substringWithRange:[m rangeAtIndex:1]];
    return [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

static NSString *RemoveAttrs(NSString *line, NSArray *names) {
    NSMutableString *s = [line mutableCopy];
    for (NSString *name in names) {
        NSString *pattern = [NSString stringWithFormat:@"(?<=[:,])%@=(\"[^\"]*\"|[^,]*),?", name];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
        [re replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }
    while ([s hasSuffix:@","]) [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
    return s;
}

// Makes a modern playlist acceptable to iOS 6's HLS stack (protocol version <= 4),
// without touching the media: relabels the version, drops subtitle / caption /
// I-frame / low-latency / ad-marker lines, and keeps only the audio rendition iOS 6
// can use (muxed audio when there is any, else the default track).
static NSArray *LegacyPlaylist(NSArray *lines, NSString *preferredAudio) {
    NSString *joined = [lines componentsJoinedByString:@"\n"];
    if ([joined rangeOfString:@"#EXT-X-MAP"].location != NSNotFound) return lines;  // fMP4: can't help
    int maxVersion = [joined rangeOfString:@"#EXT-X-BYTERANGE"].location != NSNotFound ? 4 : 3;
    // Some servers (RMC Découverte) announce a target duration shorter than their
    // segments (4 vs 5.76 s); iOS 6 schedules reloads and its timeline from it.
    double longest = 0;
    for (NSString *l in lines) if ([l hasPrefix:@"#EXTINF:"]) longest = MAX(longest, [[l substringFromIndex:8] doubleValue]);

    NSMutableSet *muxedGroups = [NSMutableSet set];
    NSMutableDictionary *keepAudio = [NSMutableDictionary dictionary];  // group -> line
    NSMutableSet *chosenGroups = [NSMutableSet set];  // groups where the user picked a separate rendition
    for (NSString *l in lines) {
        if (![l hasPrefix:@"#EXT-X-MEDIA:"] || ![AttrValue(l, @"TYPE") isEqualToString:@"AUDIO"]) continue;
        NSString *group = AttrValue(l, @"GROUP-ID") ?: @"";
        BOOL preferred = preferredAudio.length && [AttrValue(l, @"NAME") isEqualToString:preferredAudio];
        if (!AttrValue(l, @"URI")) [muxedGroups addObject:group];
        else if (preferred) { keepAudio[group] = l; [chosenGroups addObject:group]; }
        else if (![chosenGroups containsObject:group] && (!keepAudio[group] || [AttrValue(l, @"DEFAULT") isEqualToString:@"YES"])) keepAudio[group] = l;
    }
    // Only one audio rendition per group survives (iOS 6 is fragile with several):
    // the muxed track, unless the user chose another language in the options panel.
    [muxedGroups minusSet:chosenGroups];
    NSArray *dropTags = @[@"#EXT-X-I-FRAME-STREAM-INF", @"#EXT-X-SESSION-DATA", @"#EXT-X-SESSION-KEY", @"#EXT-X-DATERANGE",
                          @"#EXT-X-CONTENT-STEERING", @"#EXT-X-PRELOAD-HINT", @"#EXT-X-PART", @"#EXT-X-SERVER-CONTROL",
                          @"#EXT-X-SKIP", @"#EXT-X-RENDITION-REPORT", @"#EXT-X-INDEPENDENT-SEGMENTS", @"#EXT-X-GAP",
                          @"#EXT-X-BITRATE", @"#EXT-X-DEFINE",
                          // Version 6 tag; iOS 6 reads it as a plain #EXT-X-DISCONTINUITY, so every
                          // reload of a live playlist reset its timeline: the picture jumped back,
                          // segments were fetched twice or skipped (RMC Découverte, MediaTailor).
                          @"#EXT-X-DISCONTINUITY-SEQUENCE"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        BOOL drop = NO;
        for (NSString *t in dropTags) if ([l hasPrefix:t]) drop = YES;
        if (drop) continue;
        if ([l hasPrefix:@"#EXT-X-TARGETDURATION:"] && longest > 0) {
            [out addObject:[NSString stringWithFormat:@"#EXT-X-TARGETDURATION:%d", MAX([[l substringFromIndex:22] intValue], (int)ceil(longest - 0.001))]];
        } else if ([l hasPrefix:@"#EXT-X-VERSION:"]) {
            [out addObject:[NSString stringWithFormat:@"#EXT-X-VERSION:%d", MIN([[l substringFromIndex:15] intValue], maxVersion)]];
        } else if ([l hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSString *type = AttrValue(l, @"TYPE");
            if (![type isEqualToString:@"AUDIO"]) continue;  // subtitles, closed captions, video renditions
            NSString *group = AttrValue(l, @"GROUP-ID") ?: @"";
            if ([muxedGroups containsObject:group] || keepAudio[group] != raw) continue;
            NSString *kept = RemoveAttrs(l, @[@"CHARACTERISTICS", @"CHANNELS", @"ASSOC-LANGUAGE", @"INSTREAM-ID", @"STABLE-RENDITION-ID",
                                              @"DEFAULT", @"AUTOSELECT"]);
            [out addObject:[kept stringByAppendingString:@",DEFAULT=YES,AUTOSELECT=YES"]];
        } else if ([l hasPrefix:@"#EXT-X-STREAM-INF"]) {
            NSMutableArray *strip = [@[@"SUBTITLES", @"CLOSED-CAPTIONS", @"VIDEO-RANGE", @"HDCP-LEVEL", @"ALLOWED-CPC", @"PATHWAY-ID",
                                       @"STABLE-VARIANT-ID", @"SCORE", @"SUPPLEMENTAL-CODECS", @"REQ-VIDEO-LAYOUT"] mutableCopy];
            if ([muxedGroups containsObject:AttrValue(l, @"AUDIO") ?: @"-"]) [strip addObject:@"AUDIO"];
            [out addObject:RemoveAttrs(l, strip)];
        } else {
            [out addObject:raw];
        }
    }
    return out;
}

// Rewrites every URI in an HLS playlist so segments and keys also go through the
// proxy (with the same extra headers), and drops variants the A4 can't decode.
// Last proxied requests (for /api/debug/proxylog): spots re-downloaded segments,
// slow fetches and failed playlist refreshes while a channel plays.
static NSMutableArray *ProxyLog;
static void ProxyLogAdd(NSDictionary *entry) {
    @synchronized ([IBRemoteAPI class]) {
        if (!ProxyLog) ProxyLog = [NSMutableArray array];
        [ProxyLog addObject:entry];
        if (ProxyLog.count > 200) [ProxyLog removeObjectsInRange:NSMakeRange(0, ProxyLog.count - 200)];
    }
}

// Debug switches for live playlist experiments (/api/debug/hls?flags=nopdt,nodiscseq,td=6,keep=6,onevariant).
static NSString *gHLSFlags = @"";
static NSString *HLSFlag(NSString *name) {
    for (NSString *f in [gHLSFlags componentsSeparatedByString:@","]) {
        if ([f isEqualToString:name]) return @"";
        if ([f hasPrefix:[name stringByAppendingString:@"="]]) return [f substringFromIndex:name.length + 1];
    }
    return nil;
}

static NSArray *DebugPlaylist(NSArray *lines) {
    if (!gHLSFlags.length) return lines;
    NSMutableArray *out = [NSMutableArray array];
    BOOL seenVariant = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = lines[i];
        if (HLSFlag(@"nopdt") && [l hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME"]) continue;
        if (HLSFlag(@"nodiscseq") && [l hasPrefix:@"#EXT-X-DISCONTINUITY-SEQUENCE"]) continue;
        if (HLSFlag(@"td") && [l hasPrefix:@"#EXT-X-TARGETDURATION:"]) l = [@"#EXT-X-TARGETDURATION:" stringByAppendingString:HLSFlag(@"td")];
        if (HLSFlag(@"onevariant") && [l hasPrefix:@"#EXT-X-STREAM-INF"]) {
            if (seenVariant) { i++; continue; }
            seenVariant = YES;
        }
        [out addObject:l];
    }
    return out;
}

// What the last rewrite of each master playlist offered (for the player's options
// panel): compatible variant heights and audio rendition names.
static NSMutableDictionary *MasterInfo;
static void RecordMasterInfo(NSString *url, NSArray *lines, NSArray *heights) {
    NSMutableArray *audio = [NSMutableArray array];
    NSString *def = nil;
    for (NSString *l in lines) {
        if (![l hasPrefix:@"#EXT-X-MEDIA:"] || ![AttrValue(l, @"TYPE") isEqualToString:@"AUDIO"]) continue;
        NSString *name = AttrValue(l, @"NAME");
        if (!name.length || [audio containsObject:name]) continue;
        if ([AttrValue(l, @"CHARACTERISTICS") ?: @"" rangeOfString:@"accessibility"].location != NSNotFound) continue;  // audio description
        [audio addObject:name];
        if (!def && (!AttrValue(l, @"URI") || [AttrValue(l, @"DEFAULT") isEqualToString:@"YES"])) def = name;
    }
    @synchronized ([IBRemoteAPI class]) {
        if (!MasterInfo) MasterInfo = [NSMutableDictionary dictionary];
        MasterInfo[url] = @{@"heights": heights ?: @[], @"audio": audio, @"defaultAudio": def ?: audio.firstObject ?: @""};
    }
}

static NSString *RewritePlaylist(NSString *text, NSURL *base, NSDictionary *headers, NSDictionary *choices, NSString *source) {
    NSUInteger keep = HLSFlag(@"keep") ? (NSUInteger)[HLSFlag(@"keep") integerValue] : 15;
    NSArray *original = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSArray *lines = DebugPlaylist(LegacyPlaylist(TrimLivePlaylist(original, keep), choices[@"ib_audio"]));
    NSRegularExpression *uriAttr = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    NSRegularExpression *resAttr = [NSRegularExpression regularExpressionWithPattern:@"RESOLUTION=(\\d+)x(\\d+)" options:0 error:NULL];
    NSRegularExpression *bwAttr = [NSRegularExpression regularExpressionWithPattern:@"BANDWIDTH=(\\d+)" options:0 error:NULL];

    // Collect variants (STREAM-INF + following URI line).
    NSMutableArray *variants = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        NSString *l = lines[i];
        if (![l hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
        NSTextCheckingResult *r = [resAttr firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        NSTextCheckingResult *b = [bwAttr firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        int height = r ? [[l substringWithRange:[r rangeAtIndex:2]] intValue] : 0;
        long long bw = b ? [[l substringWithRange:[b rangeAtIndex:1]] longLongValue] : 0;
        [variants addObject:@{@"line": @(i), @"height": @(height), @"bw": @(bw), @"ok": @(IBVariantProblem(l) == nil)}];
    }
    NSMutableIndexSet *dropped = [NSMutableIndexSet indexSet];
    NSArray *ok = [variants filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ok == YES"]];
    if (ok.count == 0 && variants.count) {
        ok = @[[variants sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"bw" ascending:YES]]].firstObject];
    }
    if (variants.count) {
        NSMutableOrderedSet *heights = [NSMutableOrderedSet orderedSet];
        for (NSDictionary *v in [ok sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:NO]]]) {
            if ([v[@"height"] intValue] > 0) [heights addObject:v[@"height"]];
        }
        RecordMasterInfo(source, original, heights.array);
        int maxH = [choices[@"ib_maxh"] intValue];
        if (maxH > 0) {  // quality cap chosen in the player's options
            NSArray *capped = [ok filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"height <= %d", maxH]];
            if (!capped.count) capped = @[[ok sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:YES]]].firstObject];
            ok = capped;
        }
    }
    for (NSDictionary *v in variants) {
        if (![ok containsObject:v]) {
            NSUInteger at = [v[@"line"] unsignedIntegerValue];
            [dropped addIndex:at];
            [dropped addIndex:at + 1];
        }
    }

    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([dropped containsIndex:i]) continue;
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0) {
            [out appendString:@"\n"];
        } else if ([l hasPrefix:@"#"]) {
            NSMutableString *m = [l mutableCopy];
            NSArray *matches = [uriAttr matchesInString:l options:0 range:NSMakeRange(0, l.length)];
            for (NSTextCheckingResult *r in [matches reverseObjectEnumerator]) {
                NSString *uri = [l substringWithRange:[r rangeAtIndex:1]];
                NSString *abs = [NSURL URLWithString:uri relativeToURL:base].absoluteString ?: uri;
                [m replaceCharactersInRange:[r rangeAtIndex:1] withString:ProxyURL(abs, headers)];
            }
            [out appendFormat:@"%@\n", m];
        } else {
            NSString *abs = [NSURL URLWithString:l relativeToURL:base].absoluteString ?: l;
            [out appendFormat:@"%@\n", ProxyURL(abs, headers)];
        }
    }
    return out;
}

static UIWebView *gDebugWeb;

static id OnMain(id (^block)(void)) {
    __block id result = nil;
    if ([NSThread isMainThread]) return block();
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

@implementation IBRemoteAPI

+ (NSDictionary *)masterInfo:(NSString *)url {
    if (!url) return nil;
    @synchronized ([IBRemoteAPI class]) { return MasterInfo[url]; }
}

+ (void)serveResource:(NSString *)name type:(NSString *)type on:(IBHTTPConnection *)c {
    NSData *d = [NSData dataWithContentsOfFile:IBResourcePath(name)];
    if (d) [c sendData:d type:type status:200];
    else [c sendText:@"missing resource" status:404];
}

+ (void)installRoutes:(IBHTTPServer *)s {
    [IBMSE installRoutes:s];
    [s route:@"GET" path:@"/" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [self serveResource:@"remote.html" type:@"text/html; charset=utf-8" on:c];
    }];
    [s route:@"GET" path:@"/cast" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [self serveResource:@"cast.html" type:@"text/html; charset=utf-8" on:c];
    }];
    [s route:@"GET" path:@"/icon.png" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [self serveResource:@"Icon@2x.png" type:@"image/png" on:c];
    }];

    // Answered on the main thread: the watchdog uses it to detect a frozen app.
    [s route:@"GET" path:@"/api/ping" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [c sendText:OnMain(^{ return @"pong"; }) status:200];
    }];
    // Off the main thread on purpose, so it works even when the app is stuck.
    [s route:@"POST" path:@"/api/restart" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [c sendJSON:@{@"ok": @YES}];
        [self restartApp];
    }];

    [s route:@"POST" path:@"/api/reset" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        OnMain(^{ [[IBTV shared] resetUI]; return (id)nil; });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"GET" path:@"/api/state" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [c sendJSON:OnMain(^{ return [[IBTV shared] stateSnapshot]; })];
    }];

    [s route:@"GET" path:@"/api/screenshot.png" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSData *png = OnMain(^{
            UIView *v = [IBTV shared].view.window ?: [IBTV shared].view;  // the composed window: shows overlaps too
            UIGraphicsBeginImageContextWithOptions(v.bounds.size, YES, 1);
            [v.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIWindow *chrome = [IBTV shared].chromeWindow;
            if (chrome && !chrome.hidden && chrome.screen == [IBTV shared].view.window.screen) [chrome.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            return UIImagePNGRepresentation(img);
        });
        [c sendData:png type:@"image/png" status:200];
    }];

    // Diagnostics: open a page in a web view on the TV, then inspect it with /api/debug/js.
    [s route:@"GET" path:@"/api/debug/web" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *u = r.query[@"u"];
        OnMain(^{
            UIWebView *web = [[UIWebView alloc] init];
            web.allowsInlineMediaPlayback = YES;
            web.mediaPlaybackRequiresUserAction = NO;
            web.scalesPageToFit = YES;
            web.backgroundColor = [UIColor blackColor];
            gDebugWeb = web;
            [[IBTV shared] showOverlay:web keys:nil onClose:^{ if (gDebugWeb == web) gDebugWeb = nil; }];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
            if (r.query[@"ref"]) [req setValue:r.query[@"ref"] forHTTPHeaderField:@"Referer"];
            [web loadRequest:req];
            return (id)nil;
        });
        [c sendJSON:@{@"ok": @YES}];
    }];
    [s route:@"GET" path:@"/api/debug/js" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *code = r.query[@"c"] ?: @"document.title";
        NSString *result = OnMain(^{
            UIWebView *web = gDebugWeb;
            for (UIView *v in [IBTV shared].overlay.subviews) {  // else the YouTube player's web view
                if (!web && [v isKindOfClass:[UIWebView class]]) web = (UIWebView *)v;
            }
            return [web stringByEvaluatingJavaScriptFromString:code] ?: @"(no web view)";
        });
        [c sendText:result status:200];
    }];
    [s route:@"GET" path:@"/api/debug/shim" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *shim = [NSString stringWithContentsOfFile:IBResourcePath(@"ytshim.js") encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        NSString *result = OnMain(^{
            [gDebugWeb stringByEvaluatingJavaScriptFromString:shim];
            return [gDebugWeb stringByEvaluatingJavaScriptFromString:@"(window.ibLog||[]).join(' | ')"] ?: @"(no web view)";
        });
        [c sendText:result status:200];
    }];
    // Test page: YouTube's official IFrame player API, logging its events and errors.
    // Same as /api/debug/shim plus the MediaSource bridge (res/msebridge.js).
    // Video layers inside every web view on screen (is web video really drawing frames?).
    [s route:@"GET" path:@"/api/debug/videolayers" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSArray *found = OnMain(^{
            NSMutableArray *out = [NSMutableArray array];
            __block void (^walk)(CALayer *, int) = nil;
            void (^w)(CALayer *, int) = ^(CALayer *l, int depth) {
                if ([l isKindOfClass:[AVPlayerLayer class]]) {
                    AVPlayerLayer *pl = (AVPlayerLayer *)l;
                    AVPlayerItem *item = pl.player.currentItem;
                    NSMutableArray *tracks = [NSMutableArray array];
                    for (AVPlayerItemTrack *t in item.tracks) [tracks addObject:[NSString stringWithFormat:@"%@%@", t.assetTrack.mediaType, t.enabled ? @"" : @"(off)"]];
                    [out addObject:@{@"ready": @(pl.readyForDisplay), @"frame": NSStringFromCGRect(pl.frame), @"hidden": @(pl.hidden),
                                     @"rate": @(pl.player.rate), @"airplayVideo": @(pl.player.airPlayVideoActive), @"allowsAirplay": @(pl.player.allowsAirPlayVideo), @"usesAirplayWhileScreen": @(pl.player.usesAirPlayVideoWhileAirPlayScreenIsActive), @"time": @(CMTimeGetSeconds(pl.player.currentTime)),
                                     @"size": NSStringFromCGSize(item.presentationSize), @"tracks": tracks,
                                     @"url": [[(AVURLAsset *)item.asset URL] absoluteString] ?: @""}];
                }
                for (CALayer *sub in l.sublayers) walk(sub, depth + 1);
            };
            walk = w;
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                NSUInteger before = out.count;
                walk(win.layer, 0);
                for (NSUInteger i = before; i < out.count; i++) {
                    NSMutableDictionary *d = [out[i] mutableCopy];
                    d[@"window"] = NSStringFromClass([win class]);
                    out[i] = d;
                }
            }
            walk = nil;
            // Every window, including ones iOS adds by itself (TV-out for media), per screen.
            NSMutableArray *wins = [NSMutableArray array];
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                [wins addObject:[NSString stringWithFormat:@"%@ screen=%@ level=%.0f hidden=%d key=%d frame=%@ subviews=%@",
                                 NSStringFromClass([win class]), win.screen == [UIScreen mainScreen] ? @"phone" : @"TV", win.windowLevel,
                                 win.hidden, win.isKeyWindow, NSStringFromCGRect(win.frame),
                                 [[win.subviews valueForKey:@"class"] componentsJoinedByString:@","]]];
            }
            [out addObject:@{@"windows": wins}];
            return (id)out;
        });
        [c sendJSON:found ?: @[]];
    }];
    [s route:@"GET" path:@"/api/debug/bridge" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *shim = [NSString stringWithContentsOfFile:IBResourcePath(@"ytshim.js") encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        NSString *bridge = [NSString stringWithContentsOfFile:IBResourcePath(@"msebridge.js") encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        NSString *result = OnMain(^{
            [gDebugWeb stringByEvaluatingJavaScriptFromString:shim];
            [gDebugWeb stringByEvaluatingJavaScriptFromString:bridge];
            return [gDebugWeb stringByEvaluatingJavaScriptFromString:@"(window.ibLog||[]).join(' | ')"] ?: @"(no web view)";
        });
        [c sendText:result status:200];
    }];
    [s route:@"GET" path:@"/debug/yt" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *video = r.query[@"v"] ?: @"aqz-KE-bpKQ";
        NSString *html = [NSString stringWithFormat:@"<!doctype html><html><head><meta name=viewport content='width=device-width'>"
            "<style>html,body{margin:0;background:#000;height:100%%}#p{width:100%%;height:100%%}</style></head><body><div id=p></div><script>"
            "window.ibLog=[];function L(m){ibLog.push((new Date()).toISOString().substr(11,8)+' '+m);}"
            "window.onerror=function(m,u,l){L('JS error: '+m+' @'+u+':'+l);};"
            "function onYouTubeIframeAPIReady(){L('api ready');window.player=new YT.Player('p',{videoId:'%@',"
            "playerVars:{playsinline:1,autoplay:1,controls:1,origin:location.protocol+'//'+location.host},"
            "events:{onReady:function(e){L('player ready');e.target.playVideo();},"
            "onStateChange:function(e){L('state '+e.data);},onError:function(e){L('error '+e.data);}}});}"
            "L('page loaded');</script><script src='https://www.youtube.com/iframe_api'></script></body></html>", video];
        [c sendData:[html dataUsingEncoding:NSUTF8StringEncoding] type:@"text/html; charset=utf-8" status:200];
    }];

    [s route:@"POST" path:@"/api/debug/play" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        NSString *url = IBString(b[@"url"]);
        NSDictionary *headers = [IBDict(b[@"headers"]) count] ? IBDict(b[@"headers"]) : nil;
        OnMain(^{
            IBMedia *m = [IBMedia mediaWithTitle:IBString(b[@"title"]) ?: @"Test" url:nil];
            m.live = YES;
            m.headers = headers;
            BOOL noCheck = [b[@"noCheck"] boolValue];  // bypass the stream check (to test it)
            m.resolver = ^(IBMedia *media, IBResolveDone done) {
                if (noCheck) done(url, nil);
                else [IBServices checkStream:url headers:headers done:done];
            };
            [[IBTV shared] playMedia:m];
            return (id)nil;
        });
        [c sendJSON:@{@"ok": @YES}];
    }];
    [s route:@"GET" path:@"/api/debug/yt" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *state = OnMain(^{ return [IBYouTube debugState:[r.query[@"release"] isEqual:@"1"]]; });
        [c sendText:state status:200];
    }];
    [s route:@"GET" path:@"/api/debug/ua" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        [IBSettings set:@"debugWebUA" value:r.query[@"ua"] ?: @""];
        [c sendJSON:@{@"ua": r.query[@"ua"] ?: @"", @"note": @"restarting"}];
        [self restartApp];
    }];
    // Subtitle drawing test: /api/debug/captions?u=<WebVTT/SRT url> (empty = off);
    // /debug/sample.vtt is a generated track with a numbered line every 2 s.
    [s route:@"GET" path:@"/api/debug/captions" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *u = r.query[@"u"];
        OnMain(^{ [[IBTV shared].player setCaptionsURL:u.length ? u : nil]; return (id)nil; });
        [c sendJSON:@{@"ok": @YES}];
    }];
    [s route:@"GET" path:@"/debug/sample.vtt" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSMutableString *v = [NSMutableString stringWithString:@"WEBVTT\n\n"];
        for (int i = 0; i < 900; i++) {
            [v appendFormat:@"%02d:%02d:%02d.000 --> %02d:%02d:%02d.800\nSubtitle test line %d\n<i>second line</i>\n\n",
             i * 2 / 3600, i * 2 / 60 % 60, i * 2 % 60, i * 2 / 3600, i * 2 / 60 % 60, i * 2 % 60 + 1, i];
        }
        [c sendData:[v dataUsingEncoding:NSUTF8StringEncoding] type:@"text/vtt" status:200];
    }];
    [s route:@"GET" path:@"/api/debug/hls" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        if (r.query[@"flags"]) gHLSFlags = [r.query[@"flags"] copy];
        @synchronized ([IBRemoteAPI class]) { [ProxyLog removeAllObjects]; }
        [c sendJSON:@{@"flags": gHLSFlags}];
    }];

    [s route:@"GET" path:@"/api/debug/proxylog" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSArray *log;
        @synchronized ([IBRemoteAPI class]) { log = [ProxyLog copy] ?: @[]; }
        [c sendJSON:@{@"now": @(CFAbsoluteTimeGetCurrent()), @"log": log}];
    }];

    [s route:@"POST" path:@"/api/debug/probe" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSDictionary *out = nil;
        IBProbeStream(IBString(b[@"url"]), [IBDict(b[@"headers"]) count] ? IBDict(b[@"headers"]) : nil, ^(IBStreamVerdict v, NSString *reason) {
            out = @{@"verdict": @(v), @"reason": reason ?: @""};
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
        [c sendJSON:out ?: @{@"verdict": @(-1), @"reason": @"timeout"}];
    }];

    // Diagnostics: freeze the main thread for ?s= seconds (tests the watchdog's recovery).
    [s route:@"POST" path:@"/api/debug/freeze" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        int secs = MAX(1, MIN(300, [r.query[@"s"] intValue]));
        [c sendJSON:@{@"freezing": @(secs)}];
        dispatch_async(dispatch_get_main_queue(), ^{ sleep((unsigned)secs); });
    }];

    // Diagnostics: fetch a URL with iBox's own HTTP/TLS stack.
    [s route:@"GET" path:@"/api/debug/fetch" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSError *error = nil;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        IBHTTPResponse *resp = [IBHTTP syncRequest:r.query[@"u"] method:@"GET" headers:nil body:nil onHeaders:nil onData:nil error:&error];
        [c sendJSON:@{@"status": @(resp.status), @"error": error.localizedDescription ?: @"", @"bytes": @(resp.body.length),
                      @"ms": @((int)((CFAbsoluteTimeGetCurrent() - t0) * 1000)), @"headers": resp.headers ?: @{}}];
    }];

    [s route:@"POST" path:@"/api/key" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        BOOL ok = NO;
        IBKey key = IBKeyFromName(IBString(IBDict([r jsonBody])[@"key"]), &ok);
        if (ok) OnMain(^{ [[IBTV shared] handleKey:key]; return (id)nil; });
        [c sendJSON:@{@"ok": @(ok)}];
    }];

    [s route:@"POST" path:@"/api/text" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        NSString *text = IBString(b[@"text"]) ?: @"";
        BOOL submit = [b[@"submit"] boolValue];
        OnMain(^{
            IBTV *tv = [IBTV shared];
            if (submit) [tv submitPrompt:text];
            else [tv updatePromptText:text];
            return (id)nil;
        });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"POST" path:@"/api/cast" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *url = IBString(IBDict([r jsonBody])[@"url"]);
        NSNumber *ok = OnMain(^{ return @([IBServices openLink:url]); });
        [c sendJSON:@{@"ok": ok}];
    }];

    [s route:@"POST" path:@"/api/search" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        NSString *service = IBString(b[@"service"]), *q = IBString(b[@"q"]);
        OnMain(^{
            IBTV *tv = [IBTV shared];
            IBPage *page = [service isEqual:@"jellyfin"] ? [IBJellyfin searchPage:q] : [service isEqual:@"spotify"] ? [IBSpotify searchPage:q]
                         : [service isEqual:@"radio"] ? [IBRadio searchPage:q] : [IBYouTube searchPage:q];
            [tv cancelPrompt];
            [tv dismissOverlay];
            if (tv.player.visible && !tv.player.currentMedia.audioOnly) [tv.player stop];
            [tv showHome];
            [tv pushPage:page];
            return (id)nil;
        });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"POST" path:@"/api/player" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        NSString *action = IBString(b[@"action"]);
        double value = [b[@"value"] doubleValue];
        OnMain(^{
            if ([IBYouTube playerActive]) {
                [IBYouTube playerControl:action value:value];
                return (id)nil;
            }
            IBPlayer *p = [IBTV shared].player;
            if ([action isEqual:@"playpause"]) [p togglePause];
            else if ([action isEqual:@"stop"]) [p stop];
            else if ([action isEqual:@"next"]) [p next];
            else if ([action isEqual:@"prev"]) [p previous];
            else if ([action isEqual:@"seek"]) [p seekTo:value];
            else if ([action isEqual:@"seekby"]) [p seekBy:value];
            else if ([action isEqual:@"show"]) [p show];
            return (id)nil;
        });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"POST" path:@"/api/volume" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        double delta = [IBDict([r jsonBody])[@"delta"] doubleValue];
        NSDictionary *out = OnMain(^{
            MPMusicPlayerController *mp = [MPMusicPlayerController applicationMusicPlayer];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            mp.volume = MAX(0, MIN(1, mp.volume + delta));
            // Through the AV adapter (HDMI or dock line out) iOS sends audio at a fixed
            // level: the system volume changes but nothing is heard. Say so.
            NSString *port = [[[AVAudioSession sharedInstance].currentRoute.outputs firstObject] portType] ?: @"";
            BOOL fixed = [port isEqualToString:AVAudioSessionPortHDMI] || [port isEqualToString:AVAudioSessionPortLineOut];
            return @{@"volume": @(mp.volume), @"output": port, @"fixed": @(fixed)};
#pragma clang diagnostic pop
        });
        [c sendJSON:out];
    }];

    [s route:@"GET" path:@"/api/settings" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *k in [IBServices settingKeys]) {
            NSString *v = [IBSettings get:k] ?: @"";
            BOOL secret = [k rangeOfString:@"Password"].location != NSNotFound || [k rangeOfString:@"Secret"].location != NSNotFound;
            out[k] = secret ? (v.length ? @"__set__" : @"") : v;
        }
        [c sendJSON:out];
    }];

    [s route:@"POST" path:@"/api/settings" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSDictionary *b = IBDict([r jsonBody]);
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (NSString *k in [IBServices settingKeys]) {
            NSString *v = IBString(b[k]);
            if (v && ![v isEqual:@"__set__"]) clean[k] = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (clean[@"jellyfinURL"] || clean[@"jellyfinUser"] || clean[@"jellyfinPassword"]) {
            clean[@"jellyfinToken"] = @"";
            clean[@"jellyfinUserId"] = @"";
        }
        [IBSettings update:clean];
        OnMain(^{ [[IBTV shared] toast:@"Settings saved"]; return (id)nil; });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"POST" path:@"/api/screen/frame" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        if (r.body.length) [IBScreenShare receiveFrame:r.body];
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"POST" path:@"/api/vnc" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *spec = IBString(IBDict([r jsonBody])[@"spec"]);
        OnMain(^{ [IBScreenShare connectVNC:spec]; return (id)nil; });
        [c sendJSON:@{@"ok": @YES}];
    }];

    [s route:@"GET" path:@"/proxy" handler:^(IBHTTPRequest *r, IBHTTPConnection *c) {
        NSString *target = r.query[@"u"];
        if (!target.length) return [c sendText:@"missing u" status:400];
        NSDictionary *extra = IBDict([NSJSONSerialization JSONObjectWithData:[r.query[@"h"] ?: @"" dataUsingEncoding:NSUTF8StringEncoding]
                                                                     options:0 error:NULL]);
        NSMutableDictionary *headers = [extra mutableCopy];
        if (r.headers[@"range"]) headers[@"Range"] = r.headers[@"range"];
        NSString *lowerPath = [[[NSURL URLWithString:target].path lowercaseString] copy] ?: @"";
        __block BOOL playlist = [lowerPath hasSuffix:@".m3u8"] || [lowerPath hasSuffix:@".m3u"];
        __block NSMutableData *buffer = nil;
        __block NSURL *finalURL = nil;
        __block NSString *contentType = nil;
        NSError *error = nil;
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        __block unsigned long long sent = 0;
        IBHTTPResponse *resp = [IBHTTP syncRequest:target method:@"GET" headers:headers body:nil
                                         onHeaders:^BOOL(IBHTTPResponse *up) {
            finalURL = up.url;
            contentType = up.headers[@"content-type"] ?: @"application/octet-stream";
            if ([[contentType lowercaseString] rangeOfString:@"mpegurl"].location != NSNotFound) playlist = YES;
            if (playlist) {
                buffer = [NSMutableData data];
                return YES;
            }
            NSMutableDictionary *h = [NSMutableDictionary dictionaryWithObject:contentType forKey:@"Content-Type"];
            for (NSString *k in @[@"content-length", @"content-range", @"accept-ranges", @"icy-metaint"]) {
                if (up.headers[k]) h[[k capitalizedString]] = up.headers[k];
            }
            return [c sendStatus:up.status headers:h];
        } onData:^BOOL(const void *bytes, size_t length) {
            if (buffer) {
                [buffer appendBytes:bytes length:length];
                return buffer.length < 8 * 1024 * 1024;
            }
            sent += length;
            return [c write:bytes length:length];
        } error:&error];
        NSString *seq = nil, *first = nil;
        NSUInteger segments = 0;
        if (buffer) {
            for (NSString *l in [[[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                if (!l.length || [l hasPrefix:@"#"]) continue;
                if (!first) first = [[[l componentsSeparatedByString:@"?"][0] lastPathComponent] copy];
                segments++;
            }
            NSString *t = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
            NSRange m = [t rangeOfString:@"#EXT-X-MEDIA-SEQUENCE:"];
            if (m.location != NSNotFound) seq = [[t substringFromIndex:NSMaxRange(m)] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]][0];
        }
        ProxyLogAdd(@{@"t": @(round(started * 10) / 10), @"ms": @((int)((CFAbsoluteTimeGetCurrent() - started) * 1000)),
                      @"path": [target lastPathComponent] ?: @"", @"range": r.headers[@"range"] ?: @"",
                      @"status": @(resp.status), @"bytes": @(buffer ? buffer.length : sent), @"seq": seq ?: @"",
                      @"first": first ?: @"", @"segments": @(segments), @"session": r.headers[@"x-playback-session-id"] ?: @"",
                      @"agent": r.headers[@"user-agent"] ?: @"",
                      @"error": error.localizedDescription ?: @""});
        if (!resp) {
            if (!c.headersSent) [c sendText:error.localizedDescription status:502];
            return;
        }
        if (buffer) {
            NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
            NSMutableDictionary *choices = [NSMutableDictionary dictionary];
            for (NSString *k in @[@"ib_audio", @"ib_maxh"]) if (r.query[k]) choices[k] = r.query[k];
            NSData *out = [RewritePlaylist(text, finalURL, extra.count ? extra : nil, choices, target) dataUsingEncoding:NSUTF8StringEncoding];
            [c sendData:out type:@"application/vnd.apple.mpegurl" status:resp.status == 206 ? 200 : resp.status];
        }
    }];
}

static IBHTTPServer *server;

+ (void)restartApp {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // The watchdog (port 8081, outside the app) kills and relaunches iBox right away.
        IBHTTPResponse *r = [IBHTTP syncRequest:@"http://127.0.0.1:8081/restart" method:@"POST" headers:nil
                                           body:[NSData data] onHeaders:nil onData:nil error:NULL];
        if (r.status != 200) {
            sleep(1);
            exit(0);  // no watchdog: quit, the user (or launchd) starts iBox again
        }
    });
}

+ (void)ensureServers {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [server ensureListening]; });
}

+ (void)startServers {
    NSData *pem = [NSData dataWithContentsOfFile:IBResourcePath(@"cacert.pem")];
    int anchors = pem ? ib_tls_load_anchors(pem.bytes, pem.length) : -1;
    NSLog(@"iBox: loaded %d TLS trust anchors", anchors);
    NSData *cert = [NSData dataWithContentsOfFile:IBResourcePath(@"server.crt.der")];
    NSData *key = [NSData dataWithContentsOfFile:IBResourcePath(@"server.key.der")];
    BOOL tlsReady = cert && key && ib_tls_load_server_identity(cert.bytes, cert.length, key.bytes, key.length) == 0;

    server = [IBHTTPServer new];
    [self installRoutes:server];
    if (![server listenOnPort:8080 tls:NO]) NSLog(@"iBox: cannot listen on 8080");
    if (tlsReady && ![server listenOnPort:8443 tls:YES]) NSLog(@"iBox: cannot listen on 8443");
    [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(ensureServers) userInfo:nil repeats:YES];
}

@end
