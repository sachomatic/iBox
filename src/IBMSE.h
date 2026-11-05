#import <Foundation/Foundation.h>
#import "IBHTTP.h"

// MediaSource bridge for YouTube's official player on iOS 6.
//
// iOS 6's WebKit has no MediaSource, so YouTube's player falls back to its 360p MP4.
// res/msebridge.js gives the page a MediaSource whose SourceBuffers send the
// fragmented MP4 the player appends (H.264 video, AAC audio) here. iBox keeps the
// samples, and serves them back to the page's own <video> element as an HLS stream
// (MPEG-TS segments cut on keyframes), which iOS 6 plays natively. The player keeps
// doing everything else itself: choosing and fetching streams, ads, seeking.
//
// Routes (port 8080):
//   POST /mse/<sid>/append?sb=<n>&off=<timestampOffset>   body: fMP4 bytes -> {"buffered": [[s, e]...]}
//   POST /mse/<sid>/remove?sb=<n>&s=&e=                   -> {"buffered": ...}
//   POST /mse/<sid>/duration?d=   POST /mse/<sid>/eos   POST /mse/<sid>/abort?sb=<n>
//   GET  /mse/<sid>/index.m3u8    GET /mse/<sid>/seg<k>.ts
//   GET  /api/debug/mse
@interface IBMSE : NSObject
+ (void)installRoutes:(IBHTTPServer *)server;
+ (NSDictionary *)debugState;
+ (void)closeAll;  // the YouTube page is gone: free every session
@end
