#import "IBServices.h"
#import "IBOptions.h"
#import "IBMSE.h"
#import "IBHTTP.h"
#import "IBTV.h"
#import "IBPlayer.h"
#import <QuartzCore/QuartzCore.h>

// YouTube on iOS 6, without a PC: videos play in YouTube's own embedded player,
// running in a web view on the TV. iOS 6's WebKit lacks APIs that player needs,
// so res/ytshim.js fills them in before the player is built. The player only
// gets 360p MP4 (format 18) without MediaSource, which the A4 decodes fine.
//
// Search uses the YouTube Data API when an API key is set, otherwise YouTube's
// public mobile search page.

static NSString *const kEmbedReferer = @"https://com.ibox.tv";  // app identity YouTube asks web-view embeds to send

@interface IBYouTubeView : UIView <UIWebViewDelegate>
@property (nonatomic, strong) UIWebView *web;
@property (nonatomic, strong) UIView *osd;
@property (nonatomic, strong) CAGradientLayer *osdGradient;
@property (nonatomic, strong) UILabel *titleLabel, *subtitleLabel, *timeLabel, *stateLabel, *hintLabel;
@property (nonatomic, strong) UIView *barTrack, *barFill;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *chromeView;      // OSD & panel, above iOS's TV-out video window
@property (nonatomic, strong) IBSubtitleView *captionView;
@property (nonatomic, strong) NSTimer *captionPoll;
@property (nonatomic) BOOL captionsOn;
@property (nonatomic, strong) NSArray *queue;  // @{id | query, title, channel, thumb, preview?}
@property (nonatomic) NSInteger index;
@property (nonatomic, strong) NSTimer *poll, *osdTimer;
@property (nonatomic) NSInteger generation, kicks, reloads, state;
@property (nonatomic, strong) NSDate *lastReload;
@property (nonatomic) NSTimeInterval position, duration;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic) BOOL userPaused, failedCurrent, pageReady, sawPlaying, showingAd, coldStart;
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *quality;  // e.g. "720p", shown in the OSD
- (BOOL)handleKey:(IBKey)key;
- (void)startCurrent;
@property (nonatomic, strong) IBOptionsPanel *optionsPanel;
@property (nonatomic) BOOL captionsApplied;  // remembered caption language applied to this video
@property (nonatomic) BOOL triedWithoutBridge;
@property (nonatomic) BOOL formatChecked;  // compared the bridge's best H.264 with the 360p MP4
@property (nonatomic) NSTimeInterval pendingSeek;  // remote presses are combined into one seek
@property (nonatomic) BOOL seekPending;
@property (nonatomic) NSTimeInterval resumeAt, progressPos;  // 360p fallback restarts where the video was
@property (nonatomic, strong) NSDate *progressAt, *errorSince;
- (void)seekTo:(NSTimeInterval)t;
- (void)teardown;
@end

static IBYouTubeView *gPlayer;
static UIWebView *gSharedWeb;   // kept between sessions while memory allows
static BOOL gSharedWebReady;     // the embed page and its player are built

// Empties the player's <video> element: the iPhone 4 has one hardware video decoder,
// and a web-view video holding it makes every AVPlayer item fail ("Cannot Complete
// Action"). YouTube's JavaScript stays loaded, so the next video still starts fast.
// Only empty the element: on a playing video pause() blocks the main thread ~1 s and
// YouTube's stopVideo() ~0.8 s (both go through mediaserverd and, on Back, could hang
// the phone); dropping the source stops picture and sound in ~0.1 s.
// YouTube's player doesn't know it was closed and may finish loading later (Back
// pressed during loading or an ad), so window.ibClosed also turns play() into a no-op.
static NSString *const kReleaseMediaJS =
    @"(function(){window.ibClosed=true;var P=window.HTMLMediaElement&&HTMLMediaElement.prototype;"
    "if(P&&!P.ibPlay){P.ibPlay=P.play;P.play=function(){if(window.ibClosed)return;return P.ibPlay.apply(this,arguments)}}"
    // media events don't bubble, but a capturing listener on document sees every one:
    // whatever way playback starts later (autoplay, a new element), it's unloaded again.
    "if(!window.ibGuard){window.ibGuard=1;var k=function(e){if(window.ibClosed&&e.target.getAttribute&&e.target.getAttribute('src')){"
    "e.target.removeAttribute('src');try{e.target.load()}catch(x){}}};"
    "document.addEventListener('play',k,true);document.addEventListener('playing',k,true);document.addEventListener('loadedmetadata',k,true)}"
    "var a=document.getElementsByTagName('video');for(var i=0;i<a.length;i++){var v=a[i];"
    "if(v.getAttribute('src')){v.autoplay=false;v.removeAttribute('src');try{v.load()}catch(e){}}}})()";
static NSString *const kReopenJS = @"window.ibClosed=false";

// 480p/720p through the MediaSource bridge (src/IBMSE.m, res/msebridge.js). Turned off
// for the session after repeated failures; "youtubeHD" = "0" in the settings disables it.
static NSInteger gBridgeFailures;
static NSString *gBridgeLastFailure;
static BOOL gSharedWebBridge;  // the shared page was built with the bridge
static BOOL BridgeWanted(void) {
    return ![[IBSettings get:@"youtubeHD"] isEqualToString:@"0"] && gBridgeFailures < 3;
}

// Scripts that run in the embed page before YouTube's player is built.
static void InstallPageScripts(UIWebView *web, BOOL bridge) {
    NSString *shim = [NSString stringWithContentsOfFile:IBResourcePath(@"ytshim.js") encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    [web stringByEvaluatingJavaScriptFromString:shim];
    if (bridge) {
        NSString *mse = [NSString stringWithContentsOfFile:IBResourcePath(@"msebridge.js") encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        [web stringByEvaluatingJavaScriptFromString:mse];
    } else {
        [web stringByEvaluatingJavaScriptFromString:@"window.ibNoMSE=true"];
    }
    if (web == gSharedWeb) gSharedWebBridge = bridge;
}

// Builds YouTube's player in the background so the first video starts quickly:
// without a JIT, the A4 needs 30-60 s to start the player script from scratch.
@interface IBYouTubeWarmer : NSObject <UIWebViewDelegate>
@end

@implementation IBYouTubeWarmer
- (void)webViewDidFinishLoad:(UIWebView *)web {
    if (web != gSharedWeb || gPlayer) return;
    InstallPageScripts(web, BridgeWanted());
    [web stringByEvaluatingJavaScriptFromString:@"(function(){var p=document.getElementById('player');"
     "if(p&&!document.getElementById('movie_player')&&!p.children.length&&typeof writeEmbed==='function'){try{writeEmbed()}catch(e){}}})()"];
    gSharedWebReady = YES;
    NSLog(@"iBox: YouTube player warmed up");
    for (NSNumber *delay in @[@2, @8, @20]) {  // a cued video may still attach a source
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [IBYouTube releaseMedia];
        });
    }
}
@end

@implementation IBYouTube

+ (NSString *)debugState:(BOOL)release {
    if (!gSharedWeb) return @"no shared web view";
    if (release) [self releaseMedia];
    NSString *js = @"(function(){var v=document.getElementsByTagName('video')[0];"
                    "return v?('src='+(v.src?v.src.split('/')[2]:'none')+' ready='+v.readyState+' paused='+v.paused):'no video element'})()";
    return [NSString stringWithFormat:@"ready=%d player=%d bridge=%d failures=%ld last=%@ %@", gSharedWebReady, gPlayer != nil,
            gSharedWebBridge, (long)gBridgeFailures, gBridgeLastFailure ?: @"-",
            [gSharedWeb stringByEvaluatingJavaScriptFromString:js]];
}

// Reset: closes the player and throws the whole YouTube page away (no media can survive
// that), then warms a fresh one up in the background.
+ (void)hardStop {
    if (gPlayer) [[IBTV shared] dismissOverlay];
    if (gSharedWeb) {
        gSharedWeb.delegate = nil;
        [gSharedWeb stopLoading];
        [gSharedWeb loadHTMLString:@"" baseURL:nil];
        [gSharedWeb removeFromSuperview];
    }
    gSharedWeb = nil;
    gSharedWebReady = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self prewarm]; });
}

// A video is starting in AVPlayer: an unfinished warm-up would keep the A4 busy for up to
// a minute (stutter). Drop it; +prewarm tries again once no video is playing.
+ (void)cancelWarmup {
    if (gPlayer || !gSharedWeb || gSharedWebReady) return;  // a ready, idle player costs nothing
    gSharedWeb.delegate = nil;
    [gSharedWeb stopLoading];
    [gSharedWeb loadHTMLString:@"" baseURL:nil];
    gSharedWeb = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self prewarm]; });
}

+ (void)releaseMedia {
    if (gPlayer || !gSharedWeb) return;
    [gSharedWeb stringByEvaluatingJavaScriptFromString:kReleaseMediaJS];
}

// A closed player's web view: forget it (kept alive a few seconds so its blank page
// finishes loading and tears the old media down), then warm a fresh one up — unless a
// new video already started its own page in the meantime.
+ (void)retire:(UIWebView *)web {
    static NSMutableArray *dying;
    if (!dying) dying = [NSMutableArray array];
    [dying addObject:web];
    if (gSharedWeb == web) {
        gSharedWeb = nil;
        gSharedWebReady = NO;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [dying removeObject:web];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self prewarm];  // no-op if a player or a shared web view already exists
    });
}

+ (void)prewarm {
    if (gSharedWeb || gPlayer) return;
    IBMedia *playing = [IBTV shared].player.currentMedia;
    if (playing && !playing.audioOnly) {
        // Building YouTube's player keeps the A4 busy for up to a minute: not during a video.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self prewarm]; });
        return;
    }
    static IBYouTubeWarmer *warmer;
    warmer = [IBYouTubeWarmer new];
    UIWebView *web = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0, 640, 360)];
    web.allowsInlineMediaPlayback = YES;
    web.mediaPlaybackRequiresUserAction = NO;
    web.delegate = warmer;
    gSharedWeb = web;
    gSharedWebReady = NO;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        @"https://www.youtube.com/embed/aqz-KE-bpKQ?playsinline=1&autoplay=0&controls=0&rel=0&iv_load_policy=3&fs=0&disablekb=1"]];
    [req setValue:kEmbedReferer forHTTPHeaderField:@"Referer"];
    [web loadRequest:req];
}

+ (NSString *)apiKey { return [IBSettings get:@"youtubeApiKey"]; }
+ (BOOL)canResolveStreams { return YES; }

/* ---------------- search ---------------- */

static NSString *JSStringUnescape(NSString *s) {
    NSUInteger n = s.length;
    unichar *in = malloc(n * sizeof(unichar)), *out = malloc(n * sizeof(unichar));
    [s getCharacters:in range:NSMakeRange(0, n)];
    NSUInteger o = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = in[i];
        if (c != '\\' || i + 1 >= n) { out[o++] = c; continue; }
        unichar e = in[++i];
        if ((e == 'x' && i + 2 < n) || (e == 'u' && i + 4 < n)) {
            NSUInteger digits = e == 'x' ? 2 : 4;
            unsigned v = 0;
            NSString *hex = [NSString stringWithCharacters:in + i + 1 length:digits];
            [[NSScanner scannerWithString:hex] scanHexInt:&v];
            out[o++] = (unichar)v;
            i += digits;
        } else {
            out[o++] = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e;
        }
    }
    NSString *r = [NSString stringWithCharacters:out length:o];
    free(in);
    free(out);
    return r;
}

static NSString *RunsText(id node) {
    NSDictionary *d = IBDict(node);
    if (IBString(d[@"simpleText"])) return d[@"simpleText"];
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *r in IBArray(d[@"runs"])) [s appendString:IBString(IBDict(r)[@"text"]) ?: @""];
    return s.length ? s : nil;
}

static void CollectVideos(id node, NSMutableArray *out, NSMutableSet *seen, int depth) {
    if (depth > 40) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = node;
        NSString *vid = IBString(d[@"videoId"]);
        NSString *title = RunsText(d[@"headline"]) ?: RunsText(d[@"title"]);
        if (vid.length == 11 && title.length && ![seen containsObject:vid] && (d[@"thumbnail"] || d[@"lengthText"])) {
            [seen addObject:vid];
            NSString *channel = RunsText(d[@"shortBylineText"]) ?: RunsText(d[@"ownerText"]) ?: RunsText(d[@"longBylineText"]);
            NSString *length = RunsText(d[@"lengthText"]);
            [out addObject:@{@"id": vid, @"title": title, @"channel": channel ?: @"",
                             @"length": length ?: @"",
                             @"thumb": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid]}];
            return;
        }
        for (id v in d.allValues) CollectVideos(v, out, seen, depth + 1);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) CollectVideos(v, out, seen, depth + 1);
    }
}

// Videos listed in a youtube.com / m.youtube.com page (search results, playlists).
+ (NSArray *)videosFromPage:(NSString *)html {
    NSString *json = nil;
    NSRange a = [html rangeOfString:@"ytInitialData = '"];
    if (a.location != NSNotFound) {
        NSUInteger from = NSMaxRange(a);
        NSRange end = [html rangeOfString:@"';" options:0 range:NSMakeRange(from, html.length - from)];
        if (end.location != NSNotFound) json = JSStringUnescape([html substringWithRange:NSMakeRange(from, end.location - from)]);
    } else {
        NSRange b = [html rangeOfString:@"ytInitialData = {"];
        if (b.location != NSNotFound) {
            NSUInteger from = NSMaxRange(b) - 1;
            NSRange end = [html rangeOfString:@";</script>" options:0 range:NSMakeRange(from, html.length - from)];
            if (end.location != NSNotFound) json = [html substringWithRange:NSMakeRange(from, end.location - from)];
        }
    }
    id data = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    NSMutableArray *videos = [NSMutableArray array];
    CollectVideos(data, videos, [NSMutableSet set], 0);
    return videos;
}

+ (NSString *)language {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return [NSString stringWithFormat:@"%@-%@,%@;q=0.8,en;q=0.5", [lang substringToIndex:MIN((NSUInteger)2, lang.length)], [IBServices country], lang];
}

+ (void)webVideos:(NSString *)url done:(void (^)(NSArray *videos, NSString *error))done {
    [IBHTTP get:url headers:@{@"Accept": @"text/html", @"Accept-Language": [self language]} completion:^(IBHTTPResponse *resp, NSError *error) {
        if (error) return done(nil, [NSString stringWithFormat:@"YouTube: %@", error.localizedDescription]);
        NSString *html = [resp text] ?: @"";
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSArray *videos = [self videosFromPage:html];  // ~0.5 MB of JSON: parse off the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                done(videos, videos.count ? nil : @"YouTube returned no videos");
            });
        });
    }];
}

+ (NSArray *)videosFromAPI:(NSArray *)entries {
    NSMutableArray *videos = [NSMutableArray array];
    for (NSDictionary *e in entries) {
        NSDictionary *sn = IBDict(e[@"snippet"]);
        id rawId = e[@"id"];
        NSString *vid = [rawId isKindOfClass:[NSDictionary class]] ? IBString(rawId[@"videoId"])
                      : IBString(IBDict(sn[@"resourceId"])[@"videoId"]) ?: IBString(rawId);
        if (vid.length != 11) continue;
        NSString *title = IBString(sn[@"title"]) ?: @"";
        for (NSArray *ent in @[@[@"&#39;", @"'"], @[@"&quot;", @"\""], @[@"&amp;", @"&"]]) {
            title = [title stringByReplacingOccurrencesOfString:ent[0] withString:ent[1]];
        }
        [videos addObject:@{@"id": vid, @"title": title, @"channel": IBString(sn[@"channelTitle"]) ?: @"",
                            @"thumb": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", vid]}];
    }
    return videos;
}

+ (void)apiVideos:(NSString *)path done:(void (^)(NSArray *videos, NSString *error))done {
    NSString *url = [NSString stringWithFormat:@"https://www.googleapis.com/youtube/v3/%@&key=%@", path, [self apiKey]];
    [IBHTTP getJSON:url headers:nil completion:^(id json, NSError *error) {
        if (error) return done(nil, [NSString stringWithFormat:@"YouTube: %@", error.localizedDescription]);
        done([self videosFromAPI:IBArray(IBDict(json)[@"items"])], nil);
    }];
}

+ (void)search:(NSString *)query limit:(NSUInteger)limit done:(void (^)(NSArray *videos, NSString *error))done {
    if ([self apiKey].length) {
        [self apiVideos:[NSString stringWithFormat:@"search?part=snippet&type=video&videoEmbeddable=true&maxResults=%lu&q=%@",
                         (unsigned long)limit, [IBHTTP escape:query]] done:done];
    } else {
        [self webVideos:[NSString stringWithFormat:@"https://m.youtube.com/results?search_query=%@", [IBHTTP escape:query]] done:done];
    }
}

+ (void)findVideoFor:(NSString *)query done:(void (^)(NSDictionary *, NSString *))done {
    [self search:query limit:3 done:^(NSArray *videos, NSString *error) {
        done(videos.firstObject, videos.count ? nil : (error ?: @"No YouTube match"));
    }];
}

/* ---------------- pages ---------------- */

+ (NSArray *)itemsForVideos:(NSArray *)videos {
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < videos.count; i++) {
        NSDictionary *v = videos[i];
        NSString *sub = [v[@"length"] length] ? [NSString stringWithFormat:@"%@ • %@", v[@"channel"], v[@"length"]] : v[@"channel"];
        [items addObject:[IBItem itemWithTitle:v[@"title"] subtitle:sub image:v[@"thumb"] action:^{
            [self playQueue:videos index:(NSInteger)i];
        }]];
    }
    return items;
}

+ (IBPage *)videosPage:(NSString *)title fetch:(void (^)(void (^)(NSArray *, NSString *)))fetch {
    return [IBPage pageWithTitle:title shape:IBShapeWide loader:^(IBPage *p, IBPageDone done) {
        fetch(^(NSArray *videos, NSString *error) { done([self itemsForVideos:videos ?: @[]], error); });
    }];
}

+ (IBPage *)searchPage:(NSString *)query {
    return [self videosPage:[NSString stringWithFormat:@"“%@”", query] fetch:^(void (^done)(NSArray *, NSString *)) {
        [self search:query limit:40 done:done];
    }];
}

+ (IBPage *)playlistPage:(NSString *)listId title:(NSString *)title {
    return [self videosPage:title fetch:^(void (^done)(NSArray *, NSString *)) {
        if ([self apiKey].length) {
            [self apiVideos:[NSString stringWithFormat:@"playlistItems?part=snippet&maxResults=50&playlistId=%@", listId] done:done];
        } else {
            [self webVideos:[NSString stringWithFormat:@"https://m.youtube.com/playlist?list=%@", listId] done:done];
        }
    }];
}

+ (IBPage *)rootPage {
    NSString *cc = [IBServices country];
    BOOL api = [self apiKey].length > 0;
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[[IBItem itemWithTitle:@"Search YouTube" subtitle:@"Or cast a link from the web remote" image:nil action:^{
        [[IBTV shared] promptText:@"Search YouTube" initial:@"" secure:NO done:^(NSString *text) {
            if (text.length) [[IBTV shared] pushPage:[self searchPage:text]];
        }];
    }] withShape:IBShapeRow]];
    // With an API key: YouTube's official popular charts. Without: equivalent searches.
    NSArray *categories = @[@[@"Popular", @"", @"populaire aujourd'hui"], @[@"Music", @"10", @"clip officiel nouveauté"],
                            @[@"Gaming", @"20", @"gaming"], @[@"Sports", @"17", @"sport résumé"],
                            @[@"Film & Animation", @"1", @"bande annonce film"], @[@"Science & Tech", @"28", @"science tech"],
                            @[@"Comedy", @"23", @"humour sketch"], @[@"News", @"25", @"actualités"]];
    [items addObject:[IBItem header:api ? [NSString stringWithFormat:@"Popular in %@", cc] : @"Browse"]];
    for (NSArray *c in categories) {
        NSString *title = c[0], *catId = c[1], *query = c[2];
        IBItem *i = [IBItem itemWithTitle:title subtitle:nil image:nil action:^{
            if (api) {
                NSString *path = [NSString stringWithFormat:@"videos?part=snippet&chart=mostPopular&maxResults=40&regionCode=%@%@",
                                  cc, catId.length ? [@"&videoCategoryId=" stringByAppendingString:catId] : @""];
                [[IBTV shared] pushPage:[self videosPage:title fetch:^(void (^done)(NSArray *, NSString *)) { [self apiVideos:path done:done]; }]];
            } else {
                IBPage *page = [self searchPage:query];
                page.title = title;
                [[IBTV shared] pushPage:page];
            }
        }];
        i.glyph = @"►";
        i.color = IBColor(0x5A1712);
        [items addObject:[i withShape:IBShapeTile]];
    }
    [items addObject:[IBItem header:@"About"]];
    [items addObject:[[IBItem itemWithTitle:@"Plays in YouTube's own player at 360p"
                                   subtitle:@"The highest quality iOS 6 can receive without modern browser features"
                                      image:nil action:nil] withShape:IBShapeRow]];
    return [IBPage pageWithTitle:@"YouTube" shape:IBShapeRow items:items];
}

/* ---------------- links ---------------- */

+ (NSString *)videoIdFromLink:(NSString *)link {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"(?:v=|youtu\\.be/|/shorts/|/live/|/embed/)([A-Za-z0-9_-]{11})" options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:link options:0 range:NSMakeRange(0, link.length)];
    return m ? [link substringWithRange:[m rangeAtIndex:1]] : nil;
}

+ (NSString *)playlistIdFromLink:(NSString *)link {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[?&]list=([A-Za-z0-9_-]+)" options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:link options:0 range:NSMakeRange(0, link.length)];
    return m ? [link substringWithRange:[m rangeAtIndex:1]] : nil;
}

+ (BOOL)openLink:(NSString *)link {
    NSString *videoId = [self videoIdFromLink:link];
    NSString *listId = [self playlistIdFromLink:link];
    if (listId && !videoId) {
        [[IBTV shared] pushPage:[self playlistPage:listId title:@"Playlist"]];
        return YES;
    }
    if (!videoId) {
        [[IBTV shared] toast:@"That doesn't look like a YouTube video link"];
        return NO;
    }
    [self playQueue:@[@{@"id": videoId, @"title": @"YouTube video", @"channel": @"",
                        @"thumb": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", videoId]}] index:0];
    return YES;
}

/* ---------------- player ---------------- */

+ (void)playQueue:(NSArray *)queue index:(NSInteger)index {
    if (queue.count == 0) return;
    IBTV *tv = [IBTV shared];
    if (tv.player.currentMedia) [tv.player stop];
    IBYouTubeView *view = [[IBYouTubeView alloc] init];
    [tv showOverlay:view keys:^BOOL(IBKey key) { return [view handleKey:key]; } onClose:^{
        [view teardown];
        if (gPlayer == view) gPlayer = nil;
    }];
    gPlayer = view;
    view.queue = queue;
    view.index = MAX(0, MIN(index, (NSInteger)queue.count - 1));
    [view startCurrent];
}

+ (BOOL)playerActive { return gPlayer != nil; }

+ (NSDictionary *)playerState {
    IBYouTubeView *p = gPlayer;
    if (!p) return nil;
    NSDictionary *item = p.queue[p.index];
    return @{@"title": item[@"title"] ?: @"", @"subtitle": item[@"channel"] ?: @"", @"artwork": item[@"thumb"] ?: @"",
             @"position": @(p.position), @"duration": @(p.duration), @"paused": @(p.userPaused || p.state == 2),
             @"audio": @NO, @"visible": @YES, @"index": @(p.index), @"count": @(p.queue.count), @"note": @"YouTube",
             @"options": p.optionsPanel ? [p.optionsPanel stateSnapshot] : [NSNull null]};
}

+ (void)playerControl:(NSString *)action value:(double)value {
    IBYouTubeView *p = gPlayer;
    if (!p) return;
    if ([action isEqual:@"playpause"]) [p handleKey:IBKeyPlayPause];
    else if ([action isEqual:@"next"]) [p handleKey:IBKeyNext];
    else if ([action isEqual:@"prev"]) [p handleKey:IBKeyPrev];
    else if ([action isEqual:@"stop"]) [[IBTV shared] dismissOverlay];
    else if ([action isEqual:@"seek"]) [p seekTo:value];
    else if ([action isEqual:@"seekby"]) [p seekTo:p.position + value];
    else if ([action isEqual:@"show"]) [p handleKey:IBKeyInfo];
}

@end

@implementation IBYouTubeView

- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 1280, 720)])) return nil;
    self.backgroundColor = [UIColor blackColor];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                                                           queue:nil usingBlock:^(NSNotification *n) {
            if (!gPlayer) { gSharedWeb = nil; gSharedWebReady = NO; }
        }];
    });
    _web = gSharedWeb ?: [[UIWebView alloc] initWithFrame:self.bounds];
    gSharedWeb = _web;
    _pageReady = gSharedWebReady;
    _coldStart = !gSharedWebReady;
    _web.frame = self.bounds;
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.allowsInlineMediaPlayback = YES;
    _web.mediaPlaybackRequiresUserAction = NO;
    _web.backgroundColor = [UIColor blackColor];
    _web.opaque = YES;
    _web.scrollView.scrollEnabled = NO;
    _web.userInteractionEnabled = NO;  // the remote drives it; keep phone-screen gestures working in preview
    _web.delegate = self;
    [self addSubview:_web];

    _chromeView = [[UIView alloc] initWithFrame:self.bounds];
    _chromeView.backgroundColor = [UIColor clearColor];
    _chromeView.userInteractionEnabled = NO;
    _captionView = [[IBSubtitleView alloc] init];
    [_chromeView addSubview:_captionView];
    _osd = [[UIView alloc] init];
    _osdGradient = [CAGradientLayer layer];
    _osdGradient.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.85].CGColor];
    [_osd.layer addSublayer:_osdGradient];
    [_chromeView addSubview:_osd];
    _titleLabel = [self label:YES];
    _subtitleLabel = [self label:NO];
    _subtitleLabel.textColor = IBColor(0xB8C0D6);
    _timeLabel = [self label:NO];
    _timeLabel.textAlignment = NSTextAlignmentRight;
    _stateLabel = [self label:YES];
    _stateLabel.textColor = IBColor(0xF5C451);
    _hintLabel = [self label:NO];
    _hintLabel.textColor = IBColor(0x8C95AD);
    _hintLabel.text = @"\u2193  Options (subtitles, quality)     OK  Pause     \u2190 \u2192  Seek     \u2191  Info";
    _barTrack = [[UIView alloc] init];
    _barTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    [_osd addSubview:_barTrack];
    _barFill = [[UIView alloc] init];
    _barFill.backgroundColor = IBColor(0xE53935);
    [_barTrack addSubview:_barFill];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [_chromeView addSubview:_spinner];
    return self;
}

- (UILabel *)label:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    l.font = IBFont(20, bold);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.osd addSubview:l];
    return l;
}

// On the TV, iOS shows web video in a window of its own above iBox's: the OSD and the
// options panel live in IBTV's chrome layer, which is above that window.
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        UIView *host = [[IBTV shared] chrome];
        if (host == [IBTV shared].view) host = self;  // interface on the iPhone's screen
        self.chromeView.frame = host == self ? self.bounds : host.bounds;
        [host addSubview:self.chromeView];
    } else {
        [self.chromeView removeFromSuperview];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.chromeView.superview == self) self.chromeView.frame = self.bounds;
    else if (self.chromeView.superview) self.chromeView.frame = self.chromeView.superview.bounds;
    CGSize s = self.bounds.size;
    CGFloat fs = MAX(15, roundf(s.height * 0.029)), m = roundf(s.width * 0.05), h = fs * 7.5;
    self.osd.frame = CGRectMake(0, s.height - h, s.width, h);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.osdGradient.frame = self.osd.bounds;
    [CATransaction commit];
    self.titleLabel.font = IBFont(fs * 1.35, YES);
    self.titleLabel.frame = CGRectMake(m, fs * 1.2, s.width - 2 * m, fs * 1.8);
    self.subtitleLabel.font = IBFont(fs * 0.9, NO);
    self.subtitleLabel.frame = CGRectMake(m, fs * 3.0, s.width * 0.6, fs * 1.3);
    self.stateLabel.font = IBFont(fs * 0.85, YES);
    self.stateLabel.frame = CGRectMake(s.width * 0.6, fs * 3.0, s.width * 0.4 - m, fs * 1.3);
    self.stateLabel.textAlignment = NSTextAlignmentRight;
    self.barTrack.frame = CGRectMake(m, fs * 4.9, s.width - 2 * m - fs * 9, 6);
    self.timeLabel.font = IBFont(fs * 0.85, NO);
    self.timeLabel.frame = CGRectMake(s.width - m - fs * 8.5, fs * 4.4, fs * 8.5, fs * 1.4);
    self.hintLabel.font = IBFont(fs * 0.75, NO);
    self.hintLabel.frame = CGRectMake(m, fs * 5.6, s.width - 2 * m - fs * 9, fs * 1.3);
    self.spinner.center = CGPointMake(s.width / 2, s.height / 2);
    if (self.optionsPanel) [self.optionsPanel layoutInBounds:self.bounds];
    [self updateOSD];
}

- (NSString *)js:(NSString *)code {
    return [self.web stringByEvaluatingJavaScriptFromString:code] ?: @"";
}

/* ---- queue ---- */

- (void)startCurrent {
    NSDictionary *item = self.queue[self.index];
    NSInteger gen = ++self.generation;
    self.failedCurrent = NO;
    self.sawPlaying = NO;
    self.userPaused = NO;
    self.kicks = 0;
    self.reloads = 0;
    self.lastReload = [NSDate distantPast];
    self.position = 0;
    self.duration = 0;
    self.state = -9;
    self.captionsApplied = NO;
    self.triedWithoutBridge = NO;
    self.formatChecked = NO;
    self.resumeAt = 0;
    self.progressAt = nil;
    [self closeOptions];
    self.titleLabel.text = item[@"title"];
    self.subtitleLabel.text = item[@"channel"];
    [self.spinner startAnimating];
    [self flashOSD];
    if (item[@"id"]) return [self loadVideo:item[@"id"]];
    [IBYouTube findVideoFor:item[@"query"] done:^(NSDictionary *video, NSString *error) {
        if (gen != self.generation || !self.superview) return;
        if (!video) return [self fail:error ?: @"no match on YouTube"];
        [self loadVideo:video[@"id"]];
    }];
}

- (void)loadVideo:(NSString *)videoId {
    self.videoId = videoId;
    self.startedAt = [NSDate date];
    if (!self.poll) {
        self.poll = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    }
    [self js:kReopenJS];
    // Reuse a running player (keeps the shim and saves a page load); otherwise load the embed page.
    BOOL bridgeOK = gSharedWebBridge == (BridgeWanted() && !self.triedWithoutBridge);
    if (bridgeOK && self.pageReady && [[self js:@"typeof document.getElementById('movie_player').loadVideoById"] isEqualToString:@"function"]) {
        // Preferred quality first: a switch after the stream started restarts it.
        NSString *q = [IBSettings get:@"youtubeQuality"] ?: @"hd720";
        [self js:[NSString stringWithFormat:@"(function(id,q){window.ibMSEOff=false;var m=document.getElementById('movie_player');"
                  "try{if(q!='auto'&&m.setPlaybackQualityRange)m.setPlaybackQualityRange(q,q)}catch(e){}m.loadVideoById(id)})('%@','%@')", videoId, q]];
        return;
    }
    self.pageReady = NO;
    gSharedWebReady = NO;
    NSString *url = [NSString stringWithFormat:@"https://www.youtube.com/embed/%@?playsinline=1&autoplay=1&controls=0&rel=0&iv_load_policy=3&fs=0&disablekb=1&modestbranding=1%@",
                     videoId, self.resumeAt > 5 ? [NSString stringWithFormat:@"&start=%d", (int)self.resumeAt] : @""];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:kEmbedReferer forHTTPHeaderField:@"Referer"];
    [self.web loadRequest:req];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    InstallPageScripts(self.web, BridgeWanted() && !self.triedWithoutBridge);
    NSString *r = [self js:@"(function(){var p=document.getElementById('player');"
                   "if(!p||document.getElementById('movie_player'))return 'ok';"
                   "if(p.children.length||typeof writeEmbed!=='function')return 'skip';"
                   "try{writeEmbed();return 'built'}catch(e){return 'EXC '+e}})()"];
    if ([r hasPrefix:@"EXC"]) NSLog(@"iBox: YouTube embed failed to build: %@", r);
    self.pageReady = YES;
    gSharedWebReady = YES;
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    if (error.code == NSURLErrorCancelled || error.code == 102) return;  // 102: frame load interrupted
    [self fail:error.localizedDescription];
}

- (void)tick {
    if (!self.superview || self.failedCurrent) return;
    // The <video> element is the ground truth: once the player was built late (after
    // the shim), its own state API can lag or stay at "unstarted" while video plays.
    NSString *json = [self js:@"(function(){var m=document.getElementById('movie_player'),v=document.getElementsByTagName('video')[0],"
                      "e=document.querySelector('.ytp-error'),r={e:e&&e.offsetHeight?e.innerText.replace(/\\s+/g,' '):''};"
                      "r.s=m&&m.getPlayerState?m.getPlayerState():-9;r.d=m&&m.getDuration?m.getDuration():0;"
                      "r.ad=!!(m&&/ad-showing|ad-interrupting/.test(m.className));"
                      "if(m&&m.getVideoData){var vd=m.getVideoData();r.title=vd.title;r.author=vd.author}"
                      "try{r.q=m.getPlaybackQuality()}catch(x){}"
                      "if(v&&v.src){r.v=1;r.t=v.currentTime;r.vd=isFinite(v.duration)?v.duration:0;r.p=v.paused;r.end=v.ended;r.rs=v.readyState;r.ve=v.error?v.error.code:0}"
                      "return JSON.stringify(r)})()"];
    NSDictionary *st = IBDict([NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]);
    if (!st.count) return;
    NSString *err = [IBString(st[@"e"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSTimeInterval age = -[self.startedAt timeIntervalSinceNow];
    if (err.length && age > 2) return [self fail:[err componentsSeparatedByString:@" Learn More"].firstObject];
    // A media error through the bridge: YouTube's player usually recovers by itself (new
    // stream); give up on 480p/720p for this video only if it lasts.
    if ([st[@"ve"] integerValue] && gSharedWebBridge) {
        if (!self.errorSince) self.errorSince = [NSDate date];
        else if ([self.errorSince timeIntervalSinceNow] < -8) return [self fail:[NSString stringWithFormat:@"video error %@", st[@"ve"]]];
    } else {
        self.errorSince = nil;
    }
    // Some videos have H.264 only up to 240p (higher qualities in VP9/AV1, which the A4
    // can't decode): YouTube's progressive 360p MP4 is better for those.
    if (gSharedWebBridge && !self.formatChecked && [st[@"s"] integerValue] != -9) {
        NSString *h = [self js:[NSString stringWithFormat:@"(function(id){var m=document.getElementById('movie_player');"
            "var r=m&&m.getPlayerResponse?m.getPlayerResponse():null;if(!r||!r.streamingData||!r.videoDetails||r.videoDetails.videoId!=id)return -1;"
            "var a=r.streamingData.adaptiveFormats||[],h=0;for(var i=0;i<a.length;i++){var x=a[i];"
            "if(/avc1\\.(42|4d)/i.test(x.mimeType||'')&&(x.fps||30)<=31&&(x.height||0)<=720&&(x.width||0)<=1280)h=Math.max(h,Math.min(x.width||0,x.height||0))}"
            "return h})('%@')", self.videoId]];
        int best = [h intValue];
        if (best >= 0) {
            self.formatChecked = YES;
            if (best <= 360) {
                NSLog(@"iBox: YouTube %@ has H.264 only up to %dp: using the 360p MP4", self.videoId, best);
                [self js:[NSString stringWithFormat:@"(function(id,t){window.ibMSEOff=true;document.getElementById('movie_player').loadVideoById(id,t)})('%@',%f)",
                          self.videoId, self.sawPlaying ? self.position : 0]];
                self.startedAt = [NSDate date];
                self.kicks = 0;
            }
        }
    }
    // Bridge stuck (no progress for 40 s while it should play): fall back to 360p there.
    if (gSharedWebBridge && [st[@"v"] boolValue] && !self.userPaused) {
        double t = [st[@"t"] doubleValue];
        if (!self.progressAt || fabs(t - self.progressPos) > 0.5) {
            self.progressAt = [NSDate date];
            self.progressPos = t;
        } else if ([self.progressAt timeIntervalSinceNow] < -40 && self.sawPlaying) {
            return [self retryWithoutBridge:@"stalled"];
        }
    }

    BOOL hasSource = [st[@"v"] boolValue];
    BOOL paused = [st[@"p"] boolValue];
    NSInteger ready = [st[@"rs"] integerValue];
    double apiDuration = [st[@"d"] doubleValue], videoDuration = [st[@"vd"] doubleValue];
    if (!self.seekPending) self.position = hasSource ? [st[@"t"] doubleValue] : 0;
    self.duration = videoDuration > 0 ? videoDuration : apiDuration;
    // An ad plays in the same <video> element: it isn't the video, and its end
    // isn't the video's end.
    BOOL ad = [st[@"ad"] boolValue] || (apiDuration > 0 && videoDuration > 0 && fabs(videoDuration - apiDuration) > 3);
    if (ad) self.duration = apiDuration;
    NSDictionary *qualities = @{@"tiny": @"144p", @"small": @"240p", @"medium": @"360p", @"large": @"480p", @"hd720": @"720p"};
    self.quality = qualities[IBString(st[@"q"]) ?: @""];
    NSString *realTitle = IBString(st[@"title"]);
    if (realTitle.length && ![self.titleLabel.text isEqualToString:realTitle] && [self.queue[self.index][@"title"] isEqual:@"YouTube video"]) {
        NSMutableArray *q = [self.queue mutableCopy];
        NSMutableDictionary *item = [q[self.index] mutableCopy];
        item[@"title"] = realTitle;
        item[@"channel"] = IBString(st[@"author"]) ?: @"";
        q[self.index] = item;
        self.queue = q;
        self.titleLabel.text = realTitle;
        self.subtitleLabel.text = item[@"channel"];
    }
    self.showingAd = ad && hasSource;
    BOOL playing = hasSource && !paused && self.position > 0.05;
    if (playing && !ad && self.position > 1) self.sawPlaying = YES;
    if (self.sawPlaying && !self.captionsApplied) {
        self.captionsApplied = YES;
        NSString *lang = [IBSettings get:@"youtubeCaptions"];
        if (lang.length) [self applyCaptions:lang];
    }
    if (ad) self.position = 0;
    self.state = playing ? 1 : (self.userPaused ? 2 : [st[@"s"] integerValue]);

    // Only this video's own end counts: right after loading the next one, the
    // element can still report the previous video as ended.
    if (self.sawPlaying && !ad && hasSource && ([st[@"end"] boolValue] || (self.duration > 0 && self.position >= self.duration - 0.5 && paused))) {
        return [self advance];
    }
    if (!hasSource) {
        if ([st[@"s"] integerValue] == -9 && age > 30) return [self fail:@"the YouTube player didn't start"];
        // Built late, the player sometimes waits for a play request before fetching
        // its streams; if even that stalls, loading the video again starts it.
        if ([st[@"s"] integerValue] != -9) {
            if (age > 2 && self.kicks < 4 && [self.lastReload timeIntervalSinceNow] < -3) {
                self.kicks++;
                self.lastReload = [NSDate date];
                [self js:@"var m=document.getElementById('movie_player');m&&m.playVideo&&m.playVideo()"];
            } else if (age > 12 && self.reloads < 2 && [self.lastReload timeIntervalSinceNow] < -12) {
                self.reloads++;
                self.lastReload = [NSDate date];
                [self js:[NSString stringWithFormat:@"document.getElementById('movie_player').loadVideoById('%@')", self.videoId]];
            }
        }
        if (age > (self.coldStart ? 100 : 50)) return [self fail:@"YouTube sent no playable stream for this video"];
    } else if (paused && !self.userPaused && age > 3 && self.kicks < 10) {
        self.kicks++;  // autoplay isn't guaranteed in a web view
        [self js:@"var v=document.getElementsByTagName('video')[0],m=document.getElementById('movie_player');v&&v.play();m&&m.playVideo&&m.playVideo()"];
    }
    if (playing || self.userPaused) [self.spinner stopAnimating];
    else if (!hasSource || ready < 3) [self.spinner startAnimating];
    [self updateOSD];
}

- (void)retryWithoutBridge:(NSString *)reason {
    NSLog(@"iBox: YouTube HD bridge failed (%@), retrying at 360p", reason);
    gBridgeLastFailure = [NSString stringWithFormat:@"%@ (at %.0f s, %@)", reason, self.position, [self js:@"(window.ibLog||[]).slice(-8).join(' | ')"]];
    gBridgeFailures++;
    self.triedWithoutBridge = YES;
    self.resumeAt = self.sawPlaying ? self.position : 0;
    self.startedAt = [NSDate date];
    self.progressAt = nil;
    self.kicks = 0;
    self.reloads = 0;
    self.pageReady = NO;
    gSharedWebReady = NO;
    [IBMSE closeAll];
    [self.spinner startAnimating];
    [self loadVideo:self.videoId];
}

- (void)fail:(NSString *)reason {
    if (self.failedCurrent) return;
    if (gSharedWebBridge && !self.triedWithoutBridge) {
        [self retryWithoutBridge:reason];
        return;
    }
    self.failedCurrent = YES;
    [self.spinner stopAnimating];
    NSDictionary *item = self.queue[self.index];
    [[IBTV shared] toast:[NSString stringWithFormat:@"%@ — YouTube: %@", item[@"title"], reason ?: @"playback failed"]];
    IBMedia *preview = item[@"preview"];
    if ([preview isKindOfClass:[IBMedia class]]) {  // Spotify track: fall back to its 30 s preview
        IBTV *tv = [IBTV shared];
        [tv dismissOverlay];
        [tv playMedia:preview];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.superview && self.failedCurrent) [self advance];
    });
}

- (void)advance {
    if (self.index + 1 < (NSInteger)self.queue.count) {
        self.index++;
        [self startCurrent];
    } else {
        [[IBTV shared] dismissOverlay];
    }
}

- (void)seekTo:(NSTimeInterval)t {
    if (self.duration > 0) t = MIN(t, self.duration - 2);
    BOOL bridge = gSharedWebBridge && ![[self js:@"String(!!window.ibMSEOff)"] isEqualToString:@"true"];
    if (bridge) {
        // Through the bridge YouTube's player must do the seek itself (it fetches the data
        // for the new position). Several presses in a row become one seek, so it doesn't
        // fetch (and the <video> doesn't wait for) every position in between.
        self.pendingSeek = MAX(0, t);
        self.seekPending = YES;
        self.position = self.pendingSeek;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(doPendingSeek) object:nil];
        [self performSelector:@selector(doPendingSeek) withObject:nil afterDelay:0.9];
        [self.spinner startAnimating];
        [self flashOSD];
        return;
    }
    // YouTube's progressive MP4: moving the <video> directly is quickest.
    [self js:[NSString stringWithFormat:@"(function(t){var v=document.getElementsByTagName('video')[0];"
              "if(v&&v.src)v.currentTime=t;else document.getElementById('movie_player').seekTo(t,true)})(%f)", MAX(0, t)]];
    self.position = MAX(0, t);
    [self flashOSD];
}

- (void)doPendingSeek {
    if (!self.superview || !self.videoId) return;
    // A seek inside the stream leaves iOS's player waiting on data YouTube re-fetches and
    // re-cuts; reloading the video at the new time gives a fresh stream starting there,
    // which plays within a few seconds.
    NSString *q = [IBSettings get:@"youtubeQuality"] ?: @"hd720";
    [self js:[NSString stringWithFormat:@"(function(id,t,q){var m=document.getElementById('movie_player');"
              "try{if(q!='auto'&&m.setPlaybackQualityRange)m.setPlaybackQualityRange(q,q)}catch(e){}"
              "m.loadVideoById({videoId:id,startSeconds:t})})('%@',%f,'%@')", self.videoId, self.pendingSeek, q]];
    self.startedAt = [NSDate date];
    self.seekPending = NO;
    self.progressAt = nil;
}

- (BOOL)handleKey:(IBKey)key {
    if (self.optionsPanel) {
        if (![self.optionsPanel handleKey:key]) [self closeOptions];
        return key != IBKeyHome;
    }
    if (key == IBKeyDown || key == IBKeyInfo) {
        [self openOptions];
        return YES;
    }
    switch (key) {
        case IBKeySelect:
            if (self.osd.alpha < 0.5) {  // info bar hidden: OK first brings it back
                [self flashOSD];
                return YES;
            }
        case IBKeyPlayPause:
            if (self.state == 1) {
                self.userPaused = YES;
                [self js:@"var v=document.getElementsByTagName('video')[0],m=document.getElementById('movie_player');m&&m.pauseVideo&&m.pauseVideo();v&&v.pause()"];
            } else {
                self.userPaused = NO;
                [self js:@"var v=document.getElementsByTagName('video')[0],m=document.getElementById('movie_player');v&&v.play();m&&m.playVideo&&m.playVideo()"];
            }
            [self flashOSD];
            return YES;
        case IBKeyLeft: [self seekTo:(self.seekPending ? self.pendingSeek : self.position) - 10]; return YES;
        case IBKeyRight: [self seekTo:(self.seekPending ? self.pendingSeek : self.position) + 30]; return YES;
        case IBKeyNext: [self advance]; return YES;
        case IBKeyPrev:
            if (self.position > 5 || self.index == 0) [self seekTo:0];
            else { self.index--; [self startCurrent]; }
            return YES;
        case IBKeyUp: [self flashOSD]; return YES;
        default: return NO;  // Back / Home close the player
    }
}

/* ---- options (captions, quality, speed, audio language) ---- */

static NSString *const kOptionsJS =
    @"(function(){var m=document.getElementById('movie_player'),o={caps:[],cur:'',q:[],qc:'',rates:[],rate:1,audio:[],ac:-1};if(!m)return JSON.stringify(o);"
    "try{var r=m.getPlayerResponse?m.getPlayerResponse():null;var ct=r&&r.captions&&r.captions.playerCaptionsTracklistRenderer&&r.captions.playerCaptionsTracklistRenderer.captionTracks||[];"
    "for(var i=0;i<ct.length;i++){var n=ct[i].name||{};o.caps.push({lang:ct[i].languageCode,kind:ct[i].kind||'',name:n.simpleText||(n.runs&&n.runs[0]&&n.runs[0].text)||ct[i].languageCode})}}catch(e){}"
    "try{var t=m.getOption('captions','track');if(t&&t.languageCode)o.cur=t.languageCode+(t.kind=='asr'?':asr':'')}catch(e){}"
    "try{o.q=m.getAvailableQualityLevels()||[];o.qc=m.getPlaybackQuality()}catch(e){}"
    "try{o.rates=m.getAvailablePlaybackRates()||[];o.rate=m.getPlaybackRate()}catch(e){}"
    "try{var at=m.getAvailableAudioTracks?m.getAvailableAudioTracks():[];var ca=m.getAudioTrack?m.getAudioTrack():null;"
    "for(var j=0;j<at.length;j++){var li=at[j].getLanguageInfo?at[j].getLanguageInfo():null;o.audio.push(li&&li.getName?li.getName():('Track '+(j+1)));if(ca&&at[j]===ca)o.ac=j}window.ibAudioTracks=at}catch(e){}"
    "return JSON.stringify(o)})()";

static NSString *QualityLabel(NSString *q) {
    NSDictionary *map = @{@"tiny": @"144p", @"small": @"240p", @"medium": @"360p", @"large": @"480p", @"hd720": @"720p",
                          @"hd1080": @"1080p", @"auto": @"Auto"};
    return map[q] ?: q;
}

- (void)pollCaptions {
    if (!self.captionsOn || self.chromeView.superview == self) {
        [self.captionView setText:nil inBounds:self.chromeView.bounds raised:NO];
        return;
    }
    NSString *text = [self js:@"(function(){var a=document.querySelectorAll('.ytp-caption-segment'),o=[];"
                      "for(var i=0;i<a.length;i++){var t=(a[i].textContent||'').replace(/^\\s+|\\s+$/g,'');if(t)o.push(t)}return o.join('\\n')})()"];
    [self.captionView setText:text inBounds:self.chromeView.bounds raised:self.osd.alpha > 0.5 || self.optionsPanel];
}

- (void)applyCaptions:(NSString *)spec {  // "fr", "en:asr" or "" (off)
    self.captionsOn = spec.length > 0;
    [self.captionPoll invalidate];
    self.captionPoll = self.captionsOn ? [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(pollCaptions)
                                                                         userInfo:nil repeats:YES] : nil;
    [self pollCaptions];
    NSArray *p = [spec componentsSeparatedByString:@":"];
    NSString *lang = p[0], *kind = p.count > 1 ? p[1] : @"";
    if (!lang.length) {
        [self js:@"var m=document.getElementById('movie_player');try{m.setOption('captions','track',{});m.unloadModule('captions')}catch(e){}"];
        return;
    }
    // Bigger text than YouTube's default: it is read from a sofa.
    [self js:[NSString stringWithFormat:@"(function(l,k){var m=document.getElementById('movie_player');try{m.loadModule('captions');"
              "var t={languageCode:l};if(k)t.kind=k;m.setOption('captions','track',t);m.setOption('captions','fontSize',2)}catch(e){}})('%@','%@')",
              lang, kind]];
}

- (void)openOptions {
    if (self.optionsPanel) return;
    NSDictionary *o = IBDict([NSJSONSerialization JSONObjectWithData:[[self js:kOptionsJS] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]);
    NSMutableArray *rows = [NSMutableArray array];
    __weak IBYouTubeView *weakSelf = self;

    NSArray *caps = IBArray(o[@"caps"]);
    NSMutableArray *capLabels = [NSMutableArray arrayWithObject:@"Off"], *capSpecs = [NSMutableArray arrayWithObject:@""];
    for (NSDictionary *c in caps) {
        BOOL asr = [c[@"kind"] isEqual:@"asr"];
        [capLabels addObject:[NSString stringWithFormat:@"%@%@", IBString(c[@"name"]) ?: c[@"lang"], asr && [IBString(c[@"name"]) rangeOfString:@"auto"].location == NSNotFound ? @" (auto)" : @""]];
        [capSpecs addObject:[NSString stringWithFormat:@"%@%@", c[@"lang"], asr ? @":asr" : @""]];
    }
    NSUInteger capSel = [capSpecs indexOfObject:IBString(o[@"cur"]) ?: @""];
    [rows addObject:[IBOption optionWithTitle:@"Subtitles" choices:caps.count ? capLabels : @[@"None for this video"]
                                     selected:capSel == NSNotFound ? 0 : capSel apply:^(NSInteger i) {
        if (!caps.count) return;
        [IBSettings set:@"youtubeCaptions" value:capSpecs[i]];  // remembered for the next videos
        [weakSelf applyCaptions:capSpecs[i]];
    }]];

    NSArray *audio = IBArray(o[@"audio"]);
    if (audio.count > 1) {
        [rows addObject:[IBOption optionWithTitle:@"Audio" choices:audio selected:MAX(0, [o[@"ac"] integerValue]) apply:^(NSInteger i) {
            [weakSelf js:[NSString stringWithFormat:@"try{document.getElementById('movie_player').setAudioTrack(window.ibAudioTracks[%ld])}catch(e){}", (long)i]];
        }]];
    }

    NSMutableArray *levels = [NSMutableArray array];
    for (NSString *q in IBArray(o[@"q"])) if (![levels containsObject:q]) [levels addObject:q];
    NSMutableArray *qLabels = [NSMutableArray array];
    for (NSString *q in levels) [qLabels addObject:QualityLabel(q)];
    NSUInteger qSel = [levels indexOfObject:IBString(o[@"qc"]) ?: @""];
    [rows addObject:[IBOption optionWithTitle:@"Quality" choices:qLabels.count ? qLabels : @[@"360p"]
                                     selected:qSel == NSNotFound ? 0 : qSel apply:^(NSInteger i) {
        if (i >= (NSInteger)levels.count) return;
        [IBSettings set:@"youtubeQuality" value:levels[i]];
        [weakSelf js:[NSString stringWithFormat:@"(function(q){var m=document.getElementById('movie_player');try{"
                      "if(q=='auto'){m.setPlaybackQualityRange&&m.setPlaybackQualityRange('auto','auto')}else{m.setPlaybackQualityRange&&m.setPlaybackQualityRange(q,q)}"
                      "m.setPlaybackQuality&&m.setPlaybackQuality(q)}catch(e){}})('%@')", levels[i]]];
    }]];

    NSMutableArray *rates = [NSMutableArray array], *rLabels = [NSMutableArray array];
    for (NSNumber *r in IBArray(o[@"rates"])) {
        if ([@[@0.5, @0.75, @1, @1.25, @1.5, @2] containsObject:r]) {
            [rates addObject:r];
            [rLabels addObject:[r doubleValue] == 1 ? @"Normal" : [NSString stringWithFormat:@"%gx", [r doubleValue]]];
        }
    }
    if (rates.count > 1) {
        NSUInteger rSel = [rates indexOfObject:o[@"rate"] ?: @1];
        [rows addObject:[IBOption optionWithTitle:@"Speed" choices:rLabels selected:rSel == NSNotFound ? [rates indexOfObject:@1] : rSel apply:^(NSInteger i) {
            [weakSelf js:[NSString stringWithFormat:@"try{document.getElementById('movie_player').setPlaybackRate(%g)}catch(e){}", [rates[i] doubleValue]]];
        }]];
    }

    IBOptionsPanel *panel = [IBOptionsPanel panelWithOptions:rows];
    self.optionsPanel = panel;
    [self.chromeView addSubview:panel];
    [panel layoutInBounds:self.bounds];
    [self.osdTimer invalidate];
    self.osd.alpha = 1;
}

- (void)closeOptions {
    if (!self.optionsPanel) return;
    [self.optionsPanel commit];
    [self.optionsPanel removeFromSuperview];
    self.optionsPanel = nil;
    [self flashOSD];
}

/* ---- OSD ---- */

- (void)updateOSD {
    BOOL live = self.duration <= 0;
    self.timeLabel.text = live ? @"" : [NSString stringWithFormat:@"%@ / %@", IBFormatTime(self.position), IBFormatTime(self.duration)];
    self.barTrack.hidden = live;
    CGRect tb = self.barTrack.bounds;
    self.barFill.frame = CGRectMake(0, 0, self.duration > 0 ? tb.size.width * MIN(1, self.position / self.duration) : 0, tb.size.height);
    self.stateLabel.text = self.userPaused ? @"|| Paused" : self.showingAd ? @"Ad" : [NSString stringWithFormat:@"YouTube%@%@",
                           self.quality ? [@" \u2022 " stringByAppendingString:self.quality] : @"",
                           self.queue.count > 1 ? [NSString stringWithFormat:@" • %ld/%lu", (long)self.index + 1, (unsigned long)self.queue.count] : @""];
}

- (void)flashOSD {
    [self.osdTimer invalidate];
    self.osd.alpha = 1;
    [self updateOSD];
    self.osdTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(fadeOSD) userInfo:nil repeats:NO];
}

- (void)fadeOSD {
    if (self.userPaused || self.optionsPanel) return;
    [UIView animateWithDuration:0.6 animations:^{ self.osd.alpha = 0; }];
}

- (void)teardown {
    [self.captionPoll invalidate];
    self.captionPoll = nil;
    [self.chromeView removeFromSuperview];
    self.generation++;
    [self.optionsPanel commit];
    [self.optionsPanel removeFromSuperview];
    self.optionsPanel = nil;
    [self.poll invalidate];
    self.poll = nil;
    [self.osdTimer invalidate];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    // A newer player view may already have taken the shared web view: leave it alone.
    if (self.web.superview != self) return;
    self.web.delegate = nil;
    // Throw the whole page away. Emptying the main <video> isn't enough: other media on
    // the page (YouTube's ad player runs in its own frame) kept playing — sound on the
    // phone, and picture too on the TV, where iOS routes web video differently.
    [self js:kReleaseMediaJS];  // stops the main video at once (~0.1 s)
    [self.web stopLoading];
    [self.web loadHTMLString:@"" baseURL:nil];
    [self.web removeFromSuperview];
    [IBYouTube retire:self.web];
    [IBMSE closeAll];
}

@end
