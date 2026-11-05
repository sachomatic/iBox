#import <Foundation/Foundation.h>
#import "IBCore.h"

// Rewrites media URLs that AVPlayer can't open by itself (HTTPS that iOS 6's TLS
// stack can't negotiate) to go through the built-in proxy.
NSString *IBPlayableURL(NSString *url);
// Same, but the proxy also sends `headers` (and keeps sending them for HLS segments).
NSString *IBPlayableURLWithHeaders(NSString *url, NSDictionary *headers);

// Why an HLS variant (#EXT-X-STREAM-INF line) can't play on the iPhone 4's A4
// decoder (H.264 Baseline/Main up to level 3.1 / 720p, AAC/MP3), or nil if it can.
NSString *IBVariantProblem(NSString *streamInfLine);

typedef NS_ENUM(NSInteger, IBStreamVerdict) {
    IBStreamPlayable,      // compatible (or not HLS, so unknown until AVPlayer tries)
    IBStreamIncompatible,  // only variants the A4 can't decode
    IBStreamBlocked,       // HTTP 4xx/5xx or not a playlist
    IBStreamUnreachable,   // DNS / connection / TLS failure, may be temporary
};

// Full check of a stream (playlist, chosen variant, segment format, codecs from a
// real segment). Runs in the background; `done` is called on the main thread.
void IBProbeStream(NSString *url, NSDictionary *headers, void (^done)(IBStreamVerdict verdict, NSString *reason));

@interface IBServices : NSObject
+ (void)start;
+ (IBPage *)homePage;
+ (IBPage *)settingsPage;
+ (NSString *)weatherSummary;
+ (NSTimeZone *)timeZone;                    // IP-based, falls back to the phone's
+ (BOOL)openLink:(NSString *)link;           // "cast" any URL to the TV
+ (NSString *)country;                        // ISO code used by radio / TV
+ (NSArray *)settingKeys;                     // keys editable from the web remote
// Fetches an HLS playlist first so blocked, offline or undecodable streams fail
// right away with a readable reason instead of a few seconds into playback.
+ (void)checkStream:(NSString *)url headers:(NSDictionary *)headers done:(IBResolveDone)done;
+ (void)probeStream:(NSString *)url headers:(NSDictionary *)headers
              done:(void (^)(IBStreamVerdict verdict, NSString *reason))done;
@end

@interface IBRadio : NSObject
+ (IBPage *)rootPage;
+ (IBPage *)searchPage:(NSString *)query;
@end

@interface IBLiveTV : NSObject
+ (IBPage *)rootPage;
+ (IBPage *)pageForPlaylist:(NSString *)url title:(NSString *)title;
@end

@interface IBJellyfin : NSObject
+ (IBPage *)rootPage;
+ (IBPage *)searchPage:(NSString *)query;
@end

@interface IBYouTube : NSObject
+ (IBPage *)rootPage;
+ (IBPage *)searchPage:(NSString *)query;
+ (BOOL)openLink:(NSString *)link;
+ (BOOL)canResolveStreams;
// Plays videos in YouTube's embedded player on the TV. Queue entries:
// @{@"id" or @"query", @"title", @"channel", @"thumb", optional @"preview": IBMedia fallback}.
+ (void)playQueue:(NSArray *)queue index:(NSInteger)index;
+ (void)findVideoFor:(NSString *)query done:(void (^)(NSDictionary *video, NSString *error))done;
+ (BOOL)playerActive;
+ (NSDictionary *)playerState;
+ (void)playerControl:(NSString *)action value:(double)value;
+ (void)prewarm;  // build the YouTube player in the background
+ (void)releaseMedia;  // free the video decoder held by the idle YouTube player
+ (void)hardStop;      // Reset: drop the YouTube page entirely (re-warmed later)
+ (void)cancelWarmup;  // a video starts: stop an unfinished background warm-up
+ (NSString *)debugState:(BOOL)release;
@end

@interface IBSpotify : NSObject
+ (IBPage *)rootPage;
+ (IBPage *)searchPage:(NSString *)query;
+ (BOOL)openLink:(NSString *)link;
@end

@interface IBScreenShare : NSObject
+ (IBPage *)rootPage;
+ (void)receiveFrame:(NSData *)jpeg;
+ (void)connectVNC:(NSString *)spec;  // "host[:port] [password]"
@end
