#import <Foundation/Foundation.h>

// HTTP API and pages served by iBox: the web remote (port 8080), the screen-cast
// page (HTTPS on 8443, needed by browsers for screen capture) and the media proxy.
@interface IBRemoteAPI : NSObject
+ (void)startServers;
+ (void)ensureServers;  // call when the app becomes active again
+ (void)restartApp;     // via the watchdog (kill + relaunch); quits if it isn't running
// For an HLS master the proxy rewrote: @{heights: compatible variant heights (high
// to low), audio: rendition names, defaultAudio}. nil if it never went through it.
+ (NSDictionary *)masterInfo:(NSString *)url;
@end
