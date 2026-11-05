#import "IBServices.h"
#import "IBHTTP.h"
#import "IBTV.h"
#import "IBPlayer.h"
#import "IBRemoteAPI.h"

NSString *IBPlayableURL(NSString *url) {
    return IBPlayableURLWithHeaders(url, nil);
}

NSString *IBPlayableURLWithHeaders(NSString *url, NSDictionary *headers) {
    if (headers.count) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:headers options:0 error:NULL];
        NSString *h = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        return [NSString stringWithFormat:@"http://127.0.0.1:8080/proxy?u=%@&h=%@", [IBHTTP escape:url], [IBHTTP escape:h]];
    }
    // Playlists always go through the proxy: it adapts them to iOS 6's HLS version,
    // filters variants and trims long live windows. Plain-HTTP segments stay direct.
    if ([[url lowercaseString] rangeOfString:@".m3u8"].location != NSNotFound) {
        return [NSString stringWithFormat:@"http://127.0.0.1:8080/proxy?u=%@", [IBHTTP escape:url]];
    }
    if (![url hasPrefix:@"https://"]) return url;
    NSString *host = [[NSURL URLWithString:url].host lowercaseString];
    // Google's front ends still speak iOS 6's TLS dialect; stream those directly.
    for (NSString *ok in @[@"googlevideo.com", @"youtube.com", @"ytimg.com"]) {
        if ([host isEqualToString:ok] || [host hasSuffix:[@"." stringByAppendingString:ok]]) return url;
    }
    return [NSString stringWithFormat:@"http://127.0.0.1:8080/proxy?u=%@", [IBHTTP escape:url]];
}

NSString *IBVariantProblem(NSString *line) {
    NSRegularExpression *res = [NSRegularExpression regularExpressionWithPattern:@"RESOLUTION=(\\d+)x(\\d+)" options:0 error:NULL];
    NSTextCheckingResult *r = [res firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (r) {
        int height = [[line substringWithRange:[r rangeAtIndex:2]] intValue];
        if (height > 720) return [NSString stringWithFormat:@"%dp video", height];
        NSRegularExpression *fr = [NSRegularExpression regularExpressionWithPattern:@"FRAME-RATE=([0-9.]+)" options:0 error:NULL];
        NSTextCheckingResult *f = [fr firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        double fps = f ? [[line substringWithRange:[f rangeAtIndex:1]] doubleValue] : 0;
        if (height >= 700 && fps > 31) return [NSString stringWithFormat:@"%dp video at %.0f fps", height, fps];  // beyond level 3.1
    }
    NSRegularExpression *cod = [NSRegularExpression regularExpressionWithPattern:@"CODECS=\"([^\"]*)\"" options:0 error:NULL];
    NSTextCheckingResult *c = [cod firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!c) return nil;  // unknown: let AVPlayer try
    for (NSString *raw in [[line substringWithRange:[c rangeAtIndex:1]] componentsSeparatedByString:@","]) {
        NSString *codec = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        if ([codec hasPrefix:@"hvc1"] || [codec hasPrefix:@"hev1"]) return @"HEVC video";
        if ([codec hasPrefix:@"av01"]) return @"AV1 video";
        if ([codec hasPrefix:@"vp09"]) return @"VP9 video";
        if ([codec hasPrefix:@"ac-3"] || [codec hasPrefix:@"ec-3"]) return @"Dolby Digital audio";
        if (![codec hasPrefix:@"avc1."] && ![codec hasPrefix:@"avc3."]) continue;
        NSArray *parts = [[codec substringFromIndex:5] componentsSeparatedByString:@"."];
        unsigned profile = 0, level = 0;
        if (parts.count == 1 && [parts[0] length] >= 6) {  // avc1.PPCCLL (hex)
            unsigned v = 0;
            [[NSScanner scannerWithString:parts[0]] scanHexInt:&v];
            profile = v >> 16;
            level = v & 0xFF;
        } else if (parts.count >= 2) {                      // legacy avc1.77.30 (decimal)
            profile = (unsigned)[parts[0] intValue];
            level = (unsigned)[parts[1] intValue];
        }
        if (profile && profile != 66 && profile != 77) {
            return profile == 100 ? @"H.264 High profile video" : [NSString stringWithFormat:@"H.264 profile %u video", profile];
        }
        if (level > 31) return [NSString stringWithFormat:@"H.264 level %.1f video", level / 10.0];
    }
    return nil;
}

static NSString *gWeather;
static NSString *gGeoCountry;
static NSTimeZone *gGeoTimeZone;

@implementation IBServices

+ (NSArray *)settingKeys {
    return @[@"jellyfinURL", @"jellyfinUser", @"jellyfinPassword", @"youtubeApiKey", @"spotifyClientId",
             @"spotifyClientSecret", @"iptvURL", @"country", @"weatherLocation", @"vncHosts", @"screensaver"];
}

+ (void)start {
    [self refreshWeather];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [IBYouTube prewarm];
    });
    [NSTimer scheduledTimerWithTimeInterval:1800 target:self selector:@selector(refreshWeather) userInfo:nil repeats:YES];
}

+ (void)probeStream:(NSString *)url headers:(NSDictionary *)headers
              done:(void (^)(IBStreamVerdict verdict, NSString *reason))done {
    IBProbeStream(url, headers, done);  // IBStreamProbe.m
}

+ (void)checkStream:(NSString *)url headers:(NSDictionary *)headers done:(IBResolveDone)done {
    [self probeStream:url headers:headers done:^(IBStreamVerdict verdict, NSString *reason) {
        done(verdict == IBStreamPlayable ? url : nil, reason);
    }];
}

+ (NSString *)country {
    NSString *c = [IBSettings get:@"country"];
    if (c.length == 2) return [c uppercaseString];
    if (gGeoCountry.length == 2) return gGeoCountry;
    NSString *locale = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return locale.length == 2 ? [locale uppercaseString] : @"FR";
}

+ (NSString *)weatherSummary { return gWeather; }
+ (NSTimeZone *)timeZone { return gGeoTimeZone ?: [NSTimeZone localTimeZone]; }

+ (void)refreshWeather {
    void (^fetch)(double, double) = ^(double lat, double lon) {
        NSString *url = [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.3f&longitude=%.3f&current_weather=true", lat, lon];
        [IBHTTP getJSON:url headers:nil completion:^(id json, NSError *error) {
            NSDictionary *cw = IBDict(IBDict(json)[@"current_weather"]);
            if (!cw[@"temperature"]) return;
            int code = [cw[@"weathercode"] intValue];
            // Only symbols present in iOS 6's emoji font.
            NSString *icon = code == 0 ? @"☀" : code <= 3 ? @"⛅" : code <= 48 ? @"☁" : code <= 67 ? @"☔"
                           : code <= 77 ? @"⛄" : code <= 82 ? @"☔" : code <= 86 ? @"⛄" : @"⚡";
            gWeather = [NSString stringWithFormat:@"%@ %.0f°", icon, [cw[@"temperature"] doubleValue]];
        }];
    };
    NSArray *parts = [[IBSettings get:@"weatherLocation"] componentsSeparatedByString:@","];
    // The IP lookup also gives the country (radio/TV defaults) and the timezone used
    // for the TV clock, so a phone left on another timezone still shows local time.
    [IBHTTP getJSON:@"http://ip-api.com/json/?fields=status,countryCode,lat,lon,timezone" headers:nil completion:^(id json, NSError *error) {
        NSDictionary *d = IBDict(json);
        BOOL ok = [d[@"status"] isEqual:@"success"];
        if (ok) {
            gGeoCountry = IBString(d[@"countryCode"]);
            NSTimeZone *tz = [NSTimeZone timeZoneWithName:IBString(d[@"timezone"]) ?: @""];
            if (tz) gGeoTimeZone = tz;
        }
        if (parts.count == 2) fetch([parts[0] doubleValue], [parts[1] doubleValue]);
        else if (ok) fetch([d[@"lat"] doubleValue], [d[@"lon"] doubleValue]);
    }];
}

+ (IBItem *)tile:(NSString *)title sub:(NSString *)sub glyph:(NSString *)glyph color:(unsigned)color action:(void (^)(void))action {
    IBItem *i = [[IBItem itemWithTitle:title subtitle:sub image:nil action:action] withShape:IBShapeTile];
    i.glyph = glyph;
    i.color = IBColor(color);
    return i;
}

+ (IBPage *)homePage {
    IBPage *page = [IBPage pageWithTitle:@"Home" shape:IBShapeTile loader:^(IBPage *p, IBPageDone done) {
        IBTV *tv = [IBTV shared];
        NSMutableArray *items = [NSMutableArray array];
        IBMedia *now = tv.player.currentMedia;
        if (now) {
            [items addObject:[self tile:@"Now Playing" sub:now.title glyph:@"♫" color:0x2E7D5B
                                 action:^{ [[IBTV shared].player show]; }]];
        }
        [items addObjectsFromArray:@[
            [self tile:@"Jellyfin" sub:@"Movies, shows & music" glyph:@"🎬" color:0x5B3E9E
                action:^{ [tv pushPage:[IBJellyfin rootPage]]; }],
            [self tile:@"YouTube" sub:@"Search & trending" glyph:@"📺" color:0xB3261E
                action:^{ [tv pushPage:[IBYouTube rootPage]]; }],
            [self tile:@"Spotify" sub:@"Playlists, albums, tracks" glyph:@"🎧" color:0x1A8D46
                action:^{ [tv pushPage:[IBSpotify rootPage]]; }],
            [self tile:@"Screen Share" sub:@"Browser cast & VNC" glyph:@"💻" color:0x1E5FA8
                action:^{ [tv pushPage:[IBScreenShare rootPage]]; }],
            [self tile:@"Radio" sub:@"30,000+ stations" glyph:@"📻" color:0xB8601A
                action:^{ [tv pushPage:[IBRadio rootPage]]; }],
            [self tile:@"Live TV" sub:@"Free IPTV channels" glyph:@"📡" color:0x137C7C
                action:^{ [tv pushPage:[IBLiveTV rootPage]]; }],
            [self tile:@"Play a link" sub:@"Any video / audio URL" glyph:@"🔗" color:0x4A5470
                action:^{
                    [tv promptText:@"Paste a link (YouTube, Spotify, .m3u8, .mp4, .mp3…)" initial:@"" secure:NO
                              done:^(NSString *text) { [self openLink:text]; }];
                }],
            [self tile:@"Settings" sub:@"Accounts & info" glyph:@"🔧" color:0x2F3A55
                action:^{ [tv pushPage:[self settingsPage]]; }],
        ]];
        done(items, nil);
    }];
    page.reloadOnShow = YES;
    return page;
}

+ (IBItem *)settingRow:(NSString *)title key:(NSString *)key secure:(BOOL)secure hint:(NSString *)hint {
    NSString *value = [IBSettings get:key];
    NSString *shown = value.length ? (secure ? @"••••••" : value) : (hint ?: @"Not set");
    return [[IBItem itemWithTitle:title subtitle:shown image:nil action:^{
        [[IBTV shared] promptText:title initial:secure ? @"" : value secure:secure done:^(NSString *text) {
            [IBSettings set:key value:text.length ? text : nil];
            if ([key hasPrefix:@"jellyfin"]) [IBSettings update:@{@"jellyfinToken": @"", @"jellyfinUserId": @""}];
            [[IBTV shared] reloadTopPage];
        }];
    }] withShape:IBShapeRow];
}

+ (IBItem *)tvPictureRow {
    NSString *fit = [IBSettings get:@"tvPicture"] ?: @"auto";
    NSDictionary *labels = @{@"auto": @"Automatic: fill on HDMI, shrink on analog TVs",
                             @"fill": @"Fill the screen", @"shrink": @"Shrink (for TVs that cut off the edges)"};
    return [[IBItem itemWithTitle:@"TV picture" subtitle:[labels[fit] ?: labels[@"auto"] stringByAppendingString:@"  —  OK to change"]
                            image:nil action:^{
        NSArray *order = @[@"auto", @"fill", @"shrink"];
        NSUInteger i = [order indexOfObject:fit];
        [IBSettings set:@"tvPicture" value:order[(i == NSNotFound ? 0 : i + 1) % order.count]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"IBTVPictureChanged" object:nil];
        [[IBTV shared] reloadTopPage];
    }] withShape:IBShapeRow];
}

+ (IBItem *)screensaverRow {
    NSString *v = [IBSettings get:@"screensaver"] ?: @"5";
    NSString *label = [v intValue] > 0 ? [NSString stringWithFormat:@"After %@ minutes without a key press (menus and music, never over a video)", v]
                                       : @"Off";
    return [[IBItem itemWithTitle:@"Screensaver" subtitle:[label stringByAppendingString:@"  \u2014  OK to change"] image:nil action:^{
        NSArray *order = @[@"2", @"5", @"10", @"15", @"0"];
        NSUInteger i = [order indexOfObject:v];
        [IBSettings set:@"screensaver" value:order[(i == NSNotFound ? 1 : i + 1) % order.count]];
        [[IBTV shared] reloadTopPage];
    }] withShape:IBShapeRow];
}

+ (IBPage *)settingsPage {
    IBPage *page = [IBPage pageWithTitle:@"Settings" shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        NSString *ip = IBLocalIPAddress();
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        done(@[
            [IBItem header:@"This iBox"],
            [[IBItem itemWithTitle:@"Remote control" subtitle:[NSString stringWithFormat:@"Open http://%@:8080 on your phone", ip] image:nil action:nil] withShape:IBShapeRow],
            [[IBItem itemWithTitle:@"Screen cast page" subtitle:[NSString stringWithFormat:@"https://%@:8443/cast (accept the certificate)", ip] image:nil action:nil] withShape:IBShapeRow],
            [[IBItem itemWithTitle:@"Video output" subtitle:[IBTV shared].outputDescription ?: @"Preview on iPhone screen" image:nil action:nil] withShape:IBShapeRow],
            [self tvPictureRow],
            [self screensaverRow],
            [[IBItem itemWithTitle:@"Reset" subtitle:@"Stops everything that plays and goes back to Home"
                             image:nil action:^{ [[IBTV shared] resetUI]; }] withShape:IBShapeRow],
            [[IBItem itemWithTitle:@"Restart the app" subtitle:@"If iBox itself is stuck: it closes and reopens in about 10 s"
                             image:nil action:^{ [[IBTV shared] toast:@"Restarting iBox…"]; [IBRemoteAPI restartApp]; }] withShape:IBShapeRow],
            [[IBItem itemWithTitle:@"Version" subtitle:[NSString stringWithFormat:@"iBox %@ on iOS %@", info[@"CFBundleShortVersionString"], [UIDevice currentDevice].systemVersion] image:nil action:nil] withShape:IBShapeRow],
            [IBItem header:@"Jellyfin"],
            [self settingRow:@"Server address" key:@"jellyfinURL" secure:NO hint:@"e.g. http://192.168.1.10:8096"],
            [self settingRow:@"User name" key:@"jellyfinUser" secure:NO hint:nil],
            [self settingRow:@"Password" key:@"jellyfinPassword" secure:YES hint:nil],
            [IBItem header:@"YouTube & Spotify"],
            [self settingRow:@"YouTube Data API key" key:@"youtubeApiKey" secure:NO hint:@"Needed for search and trending"],
            [self settingRow:@"Spotify client ID" key:@"spotifyClientId" secure:NO hint:@"Optional — enables Spotify search"],
            [self settingRow:@"Spotify client secret" key:@"spotifyClientSecret" secure:YES hint:nil],
            [IBItem header:@"Live TV, radio & weather"],
            [self settingRow:@"Live TV playlist (M3U)" key:@"iptvURL" secure:NO hint:@"Default: iptv-org channels for your country"],
            [self settingRow:@"Country code" key:@"country" secure:NO hint:[NSString stringWithFormat:@"Auto (%@)", [self country]]],
            [self settingRow:@"Weather location" key:@"weatherLocation" secure:NO hint:@"Auto from IP, or \"lat,lon\""],
        ], nil);
    }];
    return page;
}

+ (BOOL)openLink:(NSString *)link {
    link = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (link.length == 0) return NO;
    if (![link hasPrefix:@"http"] && ![link hasPrefix:@"spotify:"]) link = [@"https://" stringByAppendingString:link];
    NSString *lower = [link lowercaseString];
    if ([lower rangeOfString:@"youtube.com/"].location != NSNotFound || [lower rangeOfString:@"youtu.be/"].location != NSNotFound) {
        return [IBYouTube openLink:link];
    }
    if ([lower rangeOfString:@"spotify.com/"].location != NSNotFound || [lower hasPrefix:@"spotify:"]) {
        return [IBSpotify openLink:link];
    }
    NSString *path = [[NSURL URLWithString:link].path lowercaseString] ?: @"";
    if ([path hasSuffix:@".m3u"]) {
        [[IBTV shared] pushPage:[IBLiveTV pageForPlaylist:link title:@"Playlist"]];
        return YES;
    }
    IBMedia *m = [IBMedia mediaWithTitle:[[NSURL URLWithString:link].lastPathComponent stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: link url:link];
    m.subtitle = [NSURL URLWithString:link].host;
    for (NSString *ext in @[@".mp3", @".aac", @".m4a", @".ogg", @".opus", @".flac", @".wav", @".pls"]) {
        if ([path hasSuffix:ext]) m.audioOnly = YES;
    }
    if ([path rangeOfString:@".m3u8"].location != NSNotFound) {
        m.url = nil;
        m.resolver = ^(IBMedia *media, IBResolveDone done) { [IBServices checkStream:link headers:nil done:done]; };
    }
    [[IBTV shared] playMedia:m];
    return YES;
}

@end

/* ================= Radio ================= */

@implementation IBRadio

+ (void)query:(NSString *)pathAndQuery done:(IBPageDone)done {
    [self query:pathAndQuery attempt:0 done:done];
}

+ (void)query:(NSString *)pathAndQuery attempt:(NSUInteger)attempt done:(IBPageDone)done {
    NSArray *hosts = @[@"de1.api.radio-browser.info", @"fi1.api.radio-browser.info", @"de2.api.radio-browser.info"];
    NSString *url = [NSString stringWithFormat:@"http://%@/json/stations/%@", hosts[attempt], pathAndQuery];
    [IBHTTP getJSON:url headers:@{@"User-Agent": @"iBox/1.0"} completion:^(id json, NSError *error) {
        if (error && attempt + 1 < hosts.count) return [self query:pathAndQuery attempt:attempt + 1 done:done];
        if (error) return done(nil, error.localizedDescription);
        done([self items:IBArray(json)], nil);
    }];
}

+ (NSArray *)items:(NSArray *)stations {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray array];
    for (NSDictionary *s in stations) {
        NSString *codec = [IBString(s[@"codec"]) uppercaseString] ?: @"";
        if (!([codec hasPrefix:@"MP3"] || [codec hasPrefix:@"AAC"] || [codec isEqualToString:@""] || [codec isEqualToString:@"UNKNOWN"])) continue;
        NSString *url = IBString(s[@"url_resolved"]) ?: IBString(s[@"url"]);
        if (!url.length) continue;
        IBMedia *m = [IBMedia mediaWithTitle:[IBString(s[@"name"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] url:url];
        m.audioOnly = YES;
        m.live = YES;
        m.artworkURL = IBString(s[@"favicon"]).length ? IBString(s[@"favicon"]) : nil;
        int br = [s[@"bitrate"] intValue];
        NSString *tags = [[IBString(s[@"tags"]) componentsSeparatedByString:@","] firstObject] ?: @"";
        m.subtitle = [NSString stringWithFormat:@"%@%@%@", codec, br ? [NSString stringWithFormat:@" %d kbps", br] : @"",
                      tags.length ? [@" • " stringByAppendingString:tags] : @""];
        [queue addObject:m];
        NSUInteger idx = queue.count - 1;
        IBItem *item = [IBItem itemWithTitle:m.title subtitle:m.subtitle image:m.artworkURL action:^{
            [[IBTV shared] playQueue:queue index:(NSInteger)idx];
        }];
        item.fitImage = YES;
        [items addObject:item];
    }
    return items;
}

+ (IBPage *)stationsPage:(NSString *)title query:(NSString *)q {
    return [IBPage pageWithTitle:title shape:IBShapeSquare loader:^(IBPage *p, IBPageDone done) {
        [self query:q done:done];
    }];
}

+ (IBPage *)searchPage:(NSString *)query {
    return [self stationsPage:[NSString stringWithFormat:@"“%@”", query]
                        query:[NSString stringWithFormat:@"search?name=%@&order=clickcount&reverse=true&hidebroken=true&limit=80", [IBHTTP escape:query]]];
}

+ (IBPage *)rootPage {
    NSString *cc = [IBServices country];
    NSString *common = @"order=clickcount&reverse=true&hidebroken=true&limit=80";
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[
        [[IBItem itemWithTitle:@"Search stations" subtitle:@"By name" image:nil action:^{
            [[IBTV shared] promptText:@"Search radio stations" initial:@"" secure:NO done:^(NSString *text) {
                if (!text.length) return;
                [[IBTV shared] pushPage:[self stationsPage:text query:[NSString stringWithFormat:@"search?name=%@&%@", [IBHTTP escape:text], common]]];
            }];
        }] withShape:IBShapeRow],
        [[IBItem itemWithTitle:[NSString stringWithFormat:@"Popular in %@", cc] subtitle:nil image:nil action:^{
            [[IBTV shared] pushPage:[self stationsPage:[NSString stringWithFormat:@"Popular in %@", cc]
                                                 query:[NSString stringWithFormat:@"search?countrycode=%@&%@", cc, common]]];
        }] withShape:IBShapeRow],
        [[IBItem itemWithTitle:@"Popular worldwide" subtitle:nil image:nil action:^{
            [[IBTV shared] pushPage:[self stationsPage:@"Popular worldwide" query:[NSString stringWithFormat:@"search?%@", common]]];
        }] withShape:IBShapeRow],
        [IBItem header:@"Genres"],
    ]];
    for (NSString *tag in @[@"pop", @"rock", @"jazz", @"classical", @"electronic", @"hiphop", @"news", @"chillout", @"80s", @"reggae", @"metal", @"talk"]) {
        IBItem *i = [IBItem itemWithTitle:[tag capitalizedString] subtitle:nil image:nil action:^{
            [[IBTV shared] pushPage:[self stationsPage:[tag capitalizedString]
                                                 query:[NSString stringWithFormat:@"search?tag=%@&tagExact=true&%@", tag, common]]];
        }];
        i.color = IBColor(0x3A2A1A);
        i.glyph = @"📻";
        [items addObject:[i withShape:IBShapeTile]];
    }
    return [IBPage pageWithTitle:@"Radio" shape:IBShapeRow items:items];
}

@end

/* ================= Live TV (M3U) ================= */

// Results of channel checks, persisted so a playlist opens already filtered.
// Accessed on the main thread only (IBHTTP completions run there).
static NSMutableDictionary *gChannelChecks;
static BOOL gChannelChecksDirty;

static NSString *ChannelChecksPath(void) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [caches stringByAppendingPathComponent:@"ibox-channel-checks-v2.plist"];
}

static NSMutableDictionary *ChannelChecks(void) {
    if (!gChannelChecks) {
        gChannelChecks = [[NSDictionary dictionaryWithContentsOfFile:ChannelChecksPath()] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return gChannelChecks;
}

// Cached verdict for a stream, or nil when unknown or expired. Unreachable streams
// are retried soon (often a temporary hiccup); decoder verdicts hold for days.
static NSDictionary *IBCachedChannelCheck(NSString *url) {
    NSDictionary *c = ChannelChecks()[url];
    if (!c) return nil;
    IBStreamVerdict v = (IBStreamVerdict)[c[@"v"] integerValue];
    NSTimeInterval ttl = v == IBStreamUnreachable ? 2 * 3600 : v == IBStreamBlocked ? 12 * 3600 : 3 * 86400;
    return [[NSDate date] timeIntervalSince1970] - [c[@"t"] doubleValue] < ttl ? c : nil;
}

static void IBStoreChannelCheck(NSString *url, IBStreamVerdict verdict, NSString *reason) {
    if (!url) return;
    ChannelChecks()[url] = @{@"v": @(verdict), @"r": reason ?: @"", @"t": @([[NSDate date] timeIntervalSince1970])};
    gChannelChecksDirty = YES;
}

static void IBSaveChannelChecks(void) {
    if (!gChannelChecksDirty) return;
    gChannelChecksDirty = NO;
    [ChannelChecks() writeToFile:ChannelChecksPath() atomically:YES];
}

// "this channel only sends 1080p video, which…" -> "1080p video only"
static NSString *ShortReason(NSDictionary *check) {
    NSString *r = check[@"r"] ?: @"";
    NSRange a = [r rangeOfString:@"only sends "], b = [r rangeOfString:@", which"];
    if (a.location != NSNotFound && b.location != NSNotFound && b.location > NSMaxRange(a)) {
        return [[r substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))] stringByAppendingString:@" only"];
    }
    NSRange http = [r rangeOfString:@"(HTTP "];
    if (http.location != NSNotFound) {
        NSRange close = [r rangeOfString:@")" options:0 range:NSMakeRange(http.location, r.length - http.location)];
        if (close.location != NSNotFound) return [NSString stringWithFormat:@"Offline or blocked %@",
                                                  [r substringWithRange:NSMakeRange(http.location, NSMaxRange(close) - http.location)]];
    }
    return [check[@"v"] integerValue] == IBStreamUnreachable ? @"Can't be reached" : @"Not playable";
}

// Checks a playlist's channels a few at a time in the background and hides the
// ones the iPhone can't play. Pauses while a video is on screen so it never
// competes with playback on the A4.
@interface IBChannelChecker : NSObject
@property (nonatomic, weak) IBPage *page;
@property (nonatomic, copy) NSString *baseTitle;
@property (nonatomic, strong) NSArray *channels;  // @{url, headers, group, item}
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSUInteger next, running, checked, hiddenShown;
@property (nonatomic) BOOL finished;
- (NSArray *)visibleItems;
- (void)start;
@end

@implementation IBChannelChecker

- (NSArray *)visibleItems {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableArray *hidden = [NSMutableArray array];
    BOOL grouped = [[NSSet setWithArray:[self.channels valueForKey:@"group"]] count] > 1;
    NSString *lastGroup = nil;
    for (NSDictionary *c in self.channels) {
        NSDictionary *check = IBCachedChannelCheck(c[@"url"]);
        if (check && [check[@"v"] integerValue] != IBStreamPlayable) {
            [hidden addObject:@[c, check]];
            continue;
        }
        if (grouped && ![c[@"group"] isEqualToString:lastGroup]) {
            [items addObject:[IBItem header:c[@"group"]]];
            lastGroup = c[@"group"];
        }
        [items addObject:c[@"item"]];
    }
    self.hiddenShown = hidden.count;
    if (hidden.count) {
        [items addObject:[IBItem header:@"Not playable on this iPhone"]];
        NSString *title = self.baseTitle;
        [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"Show %lu hidden channels", (unsigned long)hidden.count]
                                       subtitle:@"1080p-only, H.264 High profile, offline or geo-blocked — you can still try them"
                                          image:nil action:^{
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *h in hidden) {
                IBItem *orig = h[0][@"item"];
                IBItem *row = [IBItem itemWithTitle:orig.title subtitle:ShortReason(h[1]) image:orig.imageURL action:orig.action];
                row.color = orig.color;
                row.fitImage = YES;
                [rows addObject:row];
            }
            [[IBTV shared] pushPage:[IBPage pageWithTitle:[title stringByAppendingString:@" · hidden"] shape:IBShapeWide items:rows]];
        }] withShape:IBShapeRow]];
    }
    [self updateTitle];
    return items;
}

- (void)updateTitle {
    IBPage *page = self.page;
    NSUInteger total = self.channels.count;
    page.title = self.finished || self.checked >= total
        ? [NSString stringWithFormat:@"%@ · %lu channels", self.baseTitle, (unsigned long)(total - self.hiddenShown)]
        : [NSString stringWithFormat:@"%@ · checking %lu/%lu", self.baseTitle, (unsigned long)self.checked, (unsigned long)total];
}

- (void)start {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self pump];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    IBSaveChannelChecks();
}

- (BOOL)videoOnScreen {
    IBPlayer *p = [IBTV shared].player;
    return p.visible && p.currentMedia && !p.currentMedia.audioOnly;
}

- (void)pump {
    IBPage *page = self.page;
    if (!page || ![[IBTV shared] hasPage:page]) return [self stop];
    while (![self videoOnScreen] && self.running < 3 && self.next < self.channels.count) {
        NSDictionary *c = self.channels[self.next++];
        if (IBCachedChannelCheck(c[@"url"])) {
            self.checked++;
            continue;
        }
        self.running++;
        __weak IBChannelChecker *weakSelf = self;
        [IBServices probeStream:c[@"url"] headers:[c[@"headers"] count] ? c[@"headers"] : nil
                           done:^(IBStreamVerdict verdict, NSString *reason) {
            IBStoreChannelCheck(c[@"url"], verdict, reason);
            IBChannelChecker *s = weakSelf;
            if (!s) return;
            s.running--;
            s.checked++;
            [s pump];
        }];
    }
    if (self.next >= self.channels.count && self.running == 0 && !self.finished) {
        self.finished = YES;
        [self apply];
        [self stop];
    }
}

// Applies new verdicts to the page (at most every few seconds: re-rendering a few
// hundred cards is not free on the A4).
- (void)apply {
    IBPage *page = self.page;
    if (!page) return;
    NSUInteger before = self.hiddenShown;
    NSArray *items = [self visibleItems];
    if (self.hiddenShown != before || self.finished) [[IBTV shared] replaceItems:items ofPage:page];
    else [[IBTV shared] refreshTitle:page];
    IBSaveChannelChecks();
}

- (void)tick {
    if (!self.page || ![[IBTV shared] hasPage:self.page]) return [self stop];
    [self apply];
    [self pump];  // resumes after a video was closed
}

@end

@implementation IBLiveTV

+ (NSString *)attribute:(NSString *)name in:(NSString *)line {
    NSRange r = [line rangeOfString:[name stringByAppendingString:@"=\""]];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [line rangeOfString:@"\"" options:0 range:NSMakeRange(start, line.length - start)];
    return end.location == NSNotFound ? nil : [line substringWithRange:NSMakeRange(start, end.location - start)];
}

+ (NSArray *)parse:(NSString *)text {
    NSMutableArray *channels = [NSMutableArray array];
    NSMutableDictionary *pending = nil;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#EXTINF"]) {
            NSRange comma = [line rangeOfString:@"," options:NSBackwardsSearch];
            NSString *name = comma.location != NSNotFound ? [line substringFromIndex:comma.location + 1] : @"Channel";
            pending = [@{@"name": name,
                         @"logo": [self attribute:@"tvg-logo" in:line] ?: @"",
                         @"group": [[[self attribute:@"group-title" in:line] componentsSeparatedByString:@";"] firstObject] ?: @"Other",
                         @"headers": [NSMutableDictionary dictionary]} mutableCopy];
            NSString *ua = [self attribute:@"http-user-agent" in:line], *ref = [self attribute:@"http-referrer" in:line];
            if (ua.length) pending[@"headers"][@"User-Agent"] = ua;
            if (ref.length) pending[@"headers"][@"Referer"] = ref;
        } else if ([line hasPrefix:@"#EXTVLCOPT:"] && pending) {
            // VLC-style per-stream options: "#EXTVLCOPT:http-user-agent=..." / "http-referrer=..."
            NSString *opt = [line substringFromIndex:11];
            NSRange eq = [opt rangeOfString:@"="];
            if (eq.location != NSNotFound) {
                NSString *key = [[opt substringToIndex:eq.location] lowercaseString], *value = [opt substringFromIndex:eq.location + 1];
                if ([key isEqualToString:@"http-user-agent"]) pending[@"headers"][@"User-Agent"] = value;
                if ([key isEqualToString:@"http-referrer"] || [key isEqualToString:@"http-referer"]) pending[@"headers"][@"Referer"] = value;
            }
        } else if (line.length && ![line hasPrefix:@"#"]) {
            NSMutableDictionary *c = [pending ?: @{@"name": line.lastPathComponent, @"logo": @"", @"group": @"Other"} mutableCopy];
            if ([c[@"group"] length] == 0) c[@"group"] = @"Other";
            c[@"url"] = line;
            [channels addObject:c];
            pending = nil;
        }
    }
    return channels;
}

+ (IBPage *)pageForPlaylist:(NSString *)url title:(NSString *)title {
    return [IBPage pageWithTitle:title shape:IBShapeWide loader:^(IBPage *p, IBPageDone done) {
        [IBHTTP get:url headers:nil completion:^(IBHTTPResponse *resp, NSError *error) {
            if (error) return done(nil, [NSString stringWithFormat:@"Playlist: %@", error.localizedDescription]);
            NSArray *parsed = [self parse:[resp text]];
            NSMutableDictionary *groups = [NSMutableDictionary dictionary];
            for (NSDictionary *c in parsed) {
                NSMutableArray *g = groups[c[@"group"]] ?: (groups[c[@"group"]] = [NSMutableArray array]);
                [g addObject:c];
            }
            NSMutableArray *channels = [NSMutableArray array];
            NSMutableArray *queue = [NSMutableArray array];
            for (NSString *group in [groups.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
                for (NSDictionary *c in groups[group]) {
                    IBMedia *m = [IBMedia mediaWithTitle:c[@"name"] url:nil];
                    m.subtitle = group;
                    m.live = YES;
                    NSDictionary *headers = [c[@"headers"] count] ? [c[@"headers"] copy] : nil;
                    NSString *streamURL = c[@"url"];
                    m.headers = headers;
                    m.resolver = ^(IBMedia *media, IBResolveDone done) {
                        [IBServices probeStream:streamURL headers:headers done:^(IBStreamVerdict verdict, NSString *reason) {
                            IBStoreChannelCheck(streamURL, verdict, reason);  // a failed tune also hides it next time
                            done(verdict == IBStreamPlayable ? streamURL : nil, reason);
                        }];
                    };
                    m.artworkURL = [c[@"logo"] length] ? c[@"logo"] : nil;
                    [queue addObject:m];
                    NSUInteger idx = queue.count - 1;
                    IBItem *i = [IBItem itemWithTitle:c[@"name"] subtitle:group image:m.artworkURL action:^{
                        [[IBTV shared] playQueue:queue index:(NSInteger)idx];
                    }];
                    i.color = IBColor(0x14303A);
                    i.fitImage = YES;
                    [channels addObject:@{@"url": streamURL, @"headers": headers ?: @{}, @"group": group, @"item": i}];
                }
            }
            IBChannelChecker *checker = [IBChannelChecker new];
            checker.page = p;
            checker.baseTitle = title;
            checker.channels = channels;
            p.context = checker;
            done([checker visibleItems], parsed.count ? nil : @"No channels found in this playlist");
            [checker start];
        }];
    }];
}

+ (IBPage *)rootPage {
    NSString *custom = [IBSettings get:@"iptvURL"];
    NSString *cc = [[IBServices country] lowercaseString];
    NSString *url = custom.length ? custom : [NSString stringWithFormat:@"https://iptv-org.github.io/iptv/countries/%@.m3u", cc];
    IBPage *channels = [self pageForPlaylist:url title:@"Live TV"];
    channels.emptyText = @"Set a playlist URL in Settings, or play any .m3u link from the remote.";
    return channels;
}

@end
