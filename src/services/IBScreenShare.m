#import "IBServices.h"
#import "IBHTTP.h"
#import "IBTV.h"
#import "IBPlayer.h"
#import <CommonCrypto/CommonCryptor.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#include <zlib.h>

/* ================= screen surface ================= */

@interface IBScreenView : UIView
@property (nonatomic, strong) UILabel *banner;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)showImage:(CGImageRef)image;
- (void)setMessage:(NSString *)message;
@end

@implementation IBScreenView
- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.backgroundColor = [UIColor blackColor];
    self.layer.contentsGravity = kCAGravityResizeAspect;
    _banner = [[UILabel alloc] init];
    _banner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    _banner.textColor = [UIColor whiteColor];
    _banner.textAlignment = NSTextAlignmentCenter;
    _banner.numberOfLines = 2;
    [self addSubview:_banner];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [self addSubview:_spinner];
    return self;
}
- (void)layoutSubviews {
    CGFloat fs = MAX(15, roundf(self.bounds.size.height * 0.03));
    self.banner.font = IBFont(fs, YES);
    self.banner.frame = CGRectMake(0, self.bounds.size.height - fs * 4, self.bounds.size.width, fs * 3);
    self.spinner.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
}
- (void)showImage:(CGImageRef)image {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)image;
    [CATransaction commit];
    [self.spinner stopAnimating];
}
- (void)setMessage:(NSString *)message {
    self.banner.text = message;
    self.banner.alpha = 1;
    if (!message) return;
    [UIView animateWithDuration:0.6 delay:4 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.banner.alpha = 0; } completion:nil];
}
@end

/* ================= VNC client (RFB 3.3–3.8) ================= */

@interface IBVNCClient : NSObject
@property (nonatomic, copy) NSString *host, *password;
@property (nonatomic) int port;
@property (nonatomic, weak) IBScreenView *view;
@property (atomic) BOOL stopped;
- (void)start;
@end

@implementation IBVNCClient {
    ib_conn *_conn;
    unsigned char _buf[65536];
    size_t _pos, _len;
    uint32_t *_fb;
    int _w, _h;
    z_stream _zlibRaw, _zlibZrle;
    BOOL _zlibRawInit, _zlibZrleInit;
    unsigned char *_inflated;
    size_t _inflatedCap, _inflatedLen;
    CFAbsoluteTime _lastPush;
}

- (void)start {
    [NSThread detachNewThreadSelector:@selector(run) toTarget:self withObject:nil];
}

- (void)status:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.view setMessage:message]; });
}

- (BOOL)readExact:(void *)dst length:(size_t)n {
    unsigned char *out = dst;
    while (n > 0) {
        if (_pos == _len) {
            long r = ib_read(_conn, _buf, sizeof _buf);
            if (r <= 0 || self.stopped) return NO;
            _pos = 0;
            _len = (size_t)r;
        }
        size_t take = MIN(n, _len - _pos);
        memcpy(out, _buf + _pos, take);
        _pos += take;
        out += take;
        n -= take;
    }
    return YES;
}

- (BOOL)u8:(uint8_t *)v { return [self readExact:v length:1]; }
- (BOOL)u16:(uint16_t *)v { uint8_t b[2]; if (![self readExact:b length:2]) return NO; *v = (uint16_t)(b[0] << 8 | b[1]); return YES; }
- (BOOL)u32:(uint32_t *)v {
    uint8_t b[4];
    if (![self readExact:b length:4]) return NO;
    *v = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
    return YES;
}
- (BOOL)send:(const void *)bytes length:(size_t)n {
    return ib_write_all(_conn, bytes, n) == 0 && ib_flush(_conn) == 0;
}

- (NSString *)readReason {
    uint32_t len = 0;
    if (![self u32:&len] || len > 4096) return @"connection refused";
    char *s = calloc(len + 1, 1);
    [self readExact:s length:len];
    NSString *r = [NSString stringWithUTF8String:s] ?: @"refused";
    free(s);
    return r;
}

- (void)fail:(NSString *)message {
    NSString *text = [NSString stringWithFormat:@"VNC: %@", message];
    [self status:text];
    dispatch_async(dispatch_get_main_queue(), ^{ [[IBTV shared] toast:text]; });
}

- (void)run {
    @autoreleasepool {
        [self status:[NSString stringWithFormat:@"Connecting to %@:%d…", self.host, self.port]];
        char err[256];
        _conn = ib_connect(self.host.UTF8String, self.port, 0, 10, err, sizeof err);
        if (!_conn) return [self fail:[NSString stringWithUTF8String:err]];
        ib_set_timeout(_conn, 120);
        if (![self handshake]) {
            ib_close(_conn);
            _conn = NULL;
            return;
        }
        [self status:[NSString stringWithFormat:@"Connected to %@ — Back to close", self.host]];
        [self requestUpdate:NO];
        while (!self.stopped && [self readMessage]) {}
        if (!self.stopped) [self fail:@"connection closed"];
        ib_close(_conn);
        _conn = NULL;
        if (_zlibRawInit) inflateEnd(&_zlibRaw);
        if (_zlibZrleInit) inflateEnd(&_zlibZrle);
        free(_fb);
        free(_inflated);
    }
}

- (BOOL)handshake {
    char version[13] = {0};
    if (![self readExact:version length:12] || strncmp(version, "RFB ", 4) != 0) {
        [self fail:@"not a VNC server"];
        return NO;
    }
    int minor = atoi(version + 8);
    if (minor >= 8) minor = 8; else if (minor >= 7) minor = 7; else minor = 3;
    char reply[13];
    snprintf(reply, sizeof reply, "RFB 003.00%d\n", minor);
    if (![self send:reply length:12]) return NO;

    uint32_t secType = 0;
    if (minor == 3) {
        if (![self u32:&secType]) return NO;
        if (secType == 0) { [self fail:[self readReason]]; return NO; }
    } else {
        uint8_t n = 0, types[255];
        if (![self u8:&n]) return NO;
        if (n == 0) { [self fail:[self readReason]]; return NO; }
        if (![self readExact:types length:n]) return NO;
        BOOL hasNone = NO, hasVnc = NO;
        for (int i = 0; i < n; i++) {
            if (types[i] == 1) hasNone = YES;
            if (types[i] == 2) hasVnc = YES;
        }
        secType = hasNone && !self.password.length ? 1 : hasVnc ? 2 : hasNone ? 1 : 0;
        if (!secType) {
            [self fail:@"server needs an authentication type iBox doesn't support (set a classic VNC password)"];
            return NO;
        }
        uint8_t chosen = (uint8_t)secType;
        if (![self send:&chosen length:1]) return NO;
    }
    if (secType == 2) {
        unsigned char challenge[16], response[16], key[8] = {0};
        if (![self readExact:challenge length:16]) return NO;
        const char *pw = self.password.UTF8String ?: "";
        for (int i = 0; i < 8 && pw[i]; i++) {
            unsigned char c = (unsigned char)pw[i], r = 0;
            for (int b = 0; b < 8; b++) if (c & (1 << b)) r |= (unsigned char)(1 << (7 - b));
            key[i] = r;  // VNC uses the bit-reversed password as DES key
        }
        size_t moved = 0;
        CCCrypt(kCCEncrypt, kCCAlgorithmDES, kCCOptionECBMode, key, 8, NULL, challenge, 16, response, 16, &moved);
        if (![self send:response length:16]) return NO;
    }
    if (secType == 2 || minor == 8) {
        uint32_t result = 1;
        if (![self u32:&result]) return NO;
        if (result != 0) {
            [self fail:minor == 8 ? [self readReason] : @"authentication failed"];
            return NO;
        }
    }
    uint8_t shared = 1;
    if (![self send:&shared length:1]) return NO;
    uint16_t w, h;
    uint8_t pf[16];
    if (![self u16:&w] || ![self u16:&h] || ![self readExact:pf length:16]) return NO;
    NSString *name = [self readReason];
    [self status:[NSString stringWithFormat:@"%@ (%dx%d)", name, w, h]];
    [self resize:w height:h];

    // 32bpp little-endian xRGB: matches CoreGraphics' native BGRA layout.
    uint8_t setpf[20] = {0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0};
    if (![self send:setpf length:20]) return NO;
    int32_t encodings[] = {16, 6, 5, 1, 0, -223};  // ZRLE, Zlib, Hextile, CopyRect, Raw, DesktopSize
    uint8_t setenc[4 + sizeof encodings];
    int count = sizeof encodings / sizeof encodings[0];
    setenc[0] = 2; setenc[1] = 0; setenc[2] = 0; setenc[3] = (uint8_t)count;
    for (int i = 0; i < count; i++) {
        uint32_t e = (uint32_t)encodings[i];
        setenc[4 + i * 4] = e >> 24; setenc[5 + i * 4] = (e >> 16) & 0xFF;
        setenc[6 + i * 4] = (e >> 8) & 0xFF; setenc[7 + i * 4] = e & 0xFF;
    }
    return [self send:setenc length:sizeof setenc];
}

- (void)resize:(int)w height:(int)h {
    free(_fb);
    _w = w;
    _h = h;
    _fb = calloc((size_t)w * h, 4);
}

- (BOOL)requestUpdate:(BOOL)incremental {
    uint8_t req[10] = {3, incremental ? 1 : 0, 0, 0, 0, 0, (uint8_t)(_w >> 8), (uint8_t)_w, (uint8_t)(_h >> 8), (uint8_t)_h};
    return [self send:req length:10];
}

- (BOOL)readMessage {
    uint8_t type;
    if (![self u8:&type]) return NO;
    switch (type) {
        case 0: {  // FramebufferUpdate
            uint8_t pad;
            uint16_t n;
            if (![self u8:&pad] || ![self u16:&n]) return NO;
            for (int i = 0; i < n; i++) {
                uint16_t x, y, w, h;
                uint32_t enc;
                if (![self u16:&x] || ![self u16:&y] || ![self u16:&w] || ![self u16:&h] || ![self u32:&enc]) return NO;
                if (![self rect:x y:y w:w h:h encoding:(int32_t)enc]) return NO;
            }
            [self push];
            return [self requestUpdate:YES];
        }
        case 1: {  // SetColourMapEntries (unused in true colour)
            uint8_t pad;
            uint16_t first, n;
            if (![self u8:&pad] || ![self u16:&first] || ![self u16:&n]) return NO;
            uint8_t skip[6];
            for (int i = 0; i < n; i++) if (![self readExact:skip length:6]) return NO;
            return YES;
        }
        case 2: return YES;  // Bell
        case 3: {  // ServerCutText
            uint8_t pad[3];
            uint32_t len;
            if (![self readExact:pad length:3] || ![self u32:&len]) return NO;
            while (len > 0) {
                uint8_t skip[512];
                size_t take = MIN((size_t)len, sizeof skip);
                if (![self readExact:skip length:take]) return NO;
                len -= take;
            }
            return YES;
        }
        default:
            [self fail:[NSString stringWithFormat:@"unknown message %d", type]];
            return NO;
    }
}

- (BOOL)clip:(int)x y:(int)y w:(int)w h:(int)h {
    return x >= 0 && y >= 0 && x + w <= _w && y + h <= _h;
}

- (void)fill:(int)x y:(int)y w:(int)w h:(int)h color:(uint32_t)c {
    if (![self clip:x y:y w:w h:h]) return;
    for (int r = 0; r < h; r++) {
        uint32_t *row = _fb + (size_t)(y + r) * _w + x;
        for (int i = 0; i < w; i++) row[i] = c;
    }
}

- (BOOL)rect:(int)x y:(int)y w:(int)w h:(int)h encoding:(int32_t)enc {
    switch (enc) {
        case 0: {  // Raw
            if (![self clip:x y:y w:w h:h]) return NO;
            for (int r = 0; r < h; r++) {
                if (![self readExact:_fb + (size_t)(y + r) * _w + x length:(size_t)w * 4]) return NO;
            }
            return YES;
        }
        case 1: {  // CopyRect
            uint16_t sx, sy;
            if (![self u16:&sx] || ![self u16:&sy]) return NO;
            if (![self clip:sx y:sy w:w h:h] || ![self clip:x y:y w:w h:h]) return YES;
            uint32_t *tmp = malloc((size_t)w * h * 4);
            for (int r = 0; r < h; r++) memcpy(tmp + (size_t)r * w, _fb + (size_t)(sy + r) * _w + sx, (size_t)w * 4);
            for (int r = 0; r < h; r++) memcpy(_fb + (size_t)(y + r) * _w + x, tmp + (size_t)r * w, (size_t)w * 4);
            free(tmp);
            return YES;
        }
        case 5: return [self hextile:x y:y w:w h:h];
        case 6: {  // Zlib: raw pixels through a persistent zlib stream
            size_t need = (size_t)w * h * 4;
            if (![self inflate:&_zlibRaw initialized:&_zlibRawInit want:need]) return NO;
            if (![self clip:x y:y w:w h:h]) return YES;
            for (int r = 0; r < h; r++) memcpy(_fb + (size_t)(y + r) * _w + x, _inflated + (size_t)r * w * 4, (size_t)w * 4);
            return YES;
        }
        case 16: return [self zrle:x y:y w:w h:h];
        case -223:  // DesktopSize
            [self resize:w height:h];
            return YES;
        default:
            [self fail:[NSString stringWithFormat:@"unsupported encoding %d", enc]];
            return NO;
    }
}

- (BOOL)hextile:(int)rx y:(int)ry w:(int)rw h:(int)rh {
    uint32_t bg = 0, fg = 0;
    for (int ty = ry; ty < ry + rh; ty += 16) {
        for (int tx = rx; tx < rx + rw; tx += 16) {
            int tw = MIN(16, rx + rw - tx), th = MIN(16, ry + rh - ty);
            uint8_t mask;
            if (![self u8:&mask]) return NO;
            if (mask & 1) {
                if (![self rect:tx y:ty w:tw h:th encoding:0]) return NO;
                continue;
            }
            if (mask & 2) { if (![self readExact:&bg length:4]) return NO; }
            [self fill:tx y:ty w:tw h:th color:bg];
            if (mask & 4) { if (![self readExact:&fg length:4]) return NO; }
            if (mask & 8) {
                uint8_t n;
                if (![self u8:&n]) return NO;
                for (int i = 0; i < n; i++) {
                    uint32_t c = fg;
                    if ((mask & 16) && ![self readExact:&c length:4]) return NO;
                    uint8_t xy, wh;
                    if (![self u8:&xy] || ![self u8:&wh]) return NO;
                    [self fill:tx + (xy >> 4) y:ty + (xy & 15) w:(wh >> 4) + 1 h:(wh & 15) + 1 color:c];
                }
            }
        }
    }
    return YES;
}

// Reads a u32-length-prefixed zlib block and inflates exactly `want` bytes (or all of it if want == 0).
- (BOOL)inflate:(z_stream *)zs initialized:(BOOL *)inited want:(size_t)want {
    uint32_t clen;
    if (![self u32:&clen]) return NO;
    unsigned char *in = malloc(clen ? clen : 1);
    if (![self readExact:in length:clen]) { free(in); return NO; }
    if (!*inited) {
        memset(zs, 0, sizeof *zs);
        inflateInit(zs);
        *inited = YES;
    }
    size_t cap = want ? want : (size_t)clen * 8 + 65536;
    if (_inflatedCap < cap) {
        _inflated = realloc(_inflated, cap);
        _inflatedCap = cap;
    }
    zs->next_in = in;
    zs->avail_in = clen;
    size_t produced = 0;
    for (;;) {
        if (produced == _inflatedCap) {
            if (want) break;
            _inflatedCap *= 2;
            _inflated = realloc(_inflated, _inflatedCap);
        }
        zs->next_out = _inflated + produced;
        zs->avail_out = (uInt)(_inflatedCap - produced);
        int rc = inflate(zs, Z_SYNC_FLUSH);
        produced = _inflatedCap - zs->avail_out;
        if (rc != Z_OK && rc != Z_BUF_ERROR) break;
        if (zs->avail_in == 0 && zs->avail_out > 0) break;
        if (rc == Z_BUF_ERROR && zs->avail_in == 0) break;
    }
    free(in);
    _inflatedLen = produced;
    return !want || produced >= want;
}

- (BOOL)zrle:(int)rx y:(int)ry w:(int)rw h:(int)rh {
    if (![self inflate:&_zlibZrle initialized:&_zlibZrleInit want:0]) return NO;
    const unsigned char *p = _inflated, *end = _inflated + _inflatedLen;
#define NEED(n) do { if (p + (n) > end) return YES; } while (0)
#define CPIXEL() (p += 3, (uint32_t)p[-3] | (uint32_t)p[-2] << 8 | (uint32_t)p[-1] << 16)
    for (int ty = ry; ty < ry + rh; ty += 64) {
        for (int tx = rx; tx < rx + rw; tx += 64) {
            int tw = MIN(64, rx + rw - tx), th = MIN(64, ry + rh - ty);
            BOOL visible = [self clip:tx y:ty w:tw h:th];
            NEED(1);
            uint8_t sub = *p++;
            uint32_t palette[128];
            if (sub == 0) {
                NEED((size_t)tw * th * 3);
                for (int y = 0; y < th; y++)
                    for (int x = 0; x < tw; x++) {
                        uint32_t c = CPIXEL();
                        if (visible) _fb[(size_t)(ty + y) * _w + tx + x] = c;
                    }
            } else if (sub == 1) {
                NEED(3);
                uint32_t c = CPIXEL();
                [self fill:tx y:ty w:tw h:th color:c];
            } else if (sub <= 16) {
                NEED((size_t)sub * 3);
                for (int i = 0; i < sub; i++) palette[i] = CPIXEL();
                int bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4;
                for (int y = 0; y < th; y++) {
                    int shift = 8 - bits;
                    NEED(1);
                    for (int x = 0; x < tw; x++) {
                        if (shift < 0) { p++; shift = 8 - bits; NEED(1); }
                        int idx = (*p >> shift) & ((1 << bits) - 1);
                        shift -= bits;
                        if (visible) _fb[(size_t)(ty + y) * _w + tx + x] = palette[idx % sub];
                    }
                    p++;
                }
            } else if (sub == 128 || sub >= 130) {
                int pal = sub >= 130 ? sub - 128 : 0;
                NEED((size_t)pal * 3);
                for (int i = 0; i < pal; i++) palette[i] = CPIXEL();
                int total = tw * th, done = 0;
                while (done < total) {
                    uint32_t c;
                    int run = 1;
                    if (pal) {
                        NEED(1);
                        uint8_t b = *p++;
                        c = palette[(b & 127) % pal];
                        if (b & 128) {
                            run = 1;
                            uint8_t r;
                            do { NEED(1); r = *p++; run += r; } while (r == 255);
                        }
                    } else {
                        NEED(4);
                        c = CPIXEL();
                        uint8_t r;
                        do { NEED(1); r = *p++; run += r; } while (r == 255);
                    }
                    for (int i = 0; i < run && done < total; i++, done++) {
                        if (visible) _fb[(size_t)(ty + done / tw) * _w + tx + done % tw] = c;
                    }
                }
            } else {
                return YES;  // 17..127 and 129 are unused
            }
        }
    }
#undef NEED
#undef CPIXEL
    return YES;
}

- (void)push {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastPush < 0.06) return;  // ~15 fps is plenty for the A4
    _lastPush = now;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_fb, _w, _h, 8, (size_t)_w * 4, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    if (!image) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view showImage:image];
        CGImageRelease(image);
    });
}

@end

/* ================= module ================= */

static IBScreenView *gCastView;
static NSTimer *gCastTimer;
static IBVNCClient *gVNC;
static volatile int gDecoding;

@implementation IBScreenShare

+ (NSString *)castURL {
    return [NSString stringWithFormat:@"https://%@:8443/cast", IBLocalIPAddress()];
}

+ (void)receiveFrame:(NSData *)jpeg {
    if (gDecoding > 1) return;  // drop frames while the A4 is still busy
    __sync_add_and_fetch(&gDecoding, 1);
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef decoded = NULL;
    if (src) {
        CGImageRef lazy = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (lazy) {
            // Force decoding off the main thread.
            size_t w = CGImageGetWidth(lazy), h = CGImageGetHeight(lazy);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), lazy);
                decoded = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
            }
            CGColorSpaceRelease(cs);
            CGImageRelease(lazy);
        }
        CFRelease(src);
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (decoded) {
            IBTV *tv = [IBTV shared];
            if (!gCastView || tv.overlay != gCastView) {
                if (tv.player.currentMedia && !tv.player.currentMedia.audioOnly) [tv.player stop];
                gCastView = [[IBScreenView alloc] init];
                [tv showOverlay:gCastView keys:nil onClose:^{ gCastView = nil; }];
                [gCastView setMessage:@"Screen cast from browser — Back to close"];
            }
            [gCastView showImage:decoded];
            [gCastTimer invalidate];
            gCastTimer = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(castTimeout) userInfo:nil repeats:NO];
        }
    });
    if (decoded) CGImageRelease(decoded);
    __sync_sub_and_fetch(&gDecoding, 1);
}

+ (void)castTimeout {
    if (gCastView && [IBTV shared].overlay == gCastView) [[IBTV shared] dismissOverlay];
}

+ (void)connectVNC:(NSString *)spec {
    NSArray *parts = [[spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                      componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *hostPort = parts.firstObject;
    if (!hostPort.length) return;
    NSString *host = hostPort;
    int port = 5900;
    NSRange colon = [hostPort rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [hostPort substringToIndex:colon.location];
        port = [[hostPort substringFromIndex:colon.location + 1] intValue];
        if (port > 0 && port < 100) port += 5900;  // "host:1" display notation
    }
    gVNC.stopped = YES;
    IBScreenView *view = [[IBScreenView alloc] init];
    [view.spinner startAnimating];
    IBVNCClient *client = [IBVNCClient new];
    client.host = host;
    client.port = port;
    client.password = parts.count > 1 ? parts[1] : nil;
    client.view = view;
    gVNC = client;
    IBTV *tv = [IBTV shared];
    if (tv.player.currentMedia && !tv.player.currentMedia.audioOnly) [tv.player stop];
    [tv showOverlay:view keys:nil onClose:^{
        client.stopped = YES;
        if (gVNC == client) gVNC = nil;
    }];
    [client start];
}

+ (NSArray *)savedHosts {
    NSString *raw = [IBSettings get:@"vncHosts"] ?: @"";
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";\n"]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [hosts addObject:t];
    }
    return hosts;
}

+ (IBPage *)rootPage {
    IBPage *page = [IBPage pageWithTitle:@"Screen Share" shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[IBItem header:@"Cast from a computer"]];
        [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"Open %@", [self castURL]]
                                       subtitle:@"Chrome, Edge or Firefox • accept the certificate warning once, then click Share"
                                          image:nil action:nil] withShape:IBShapeRow]];
        [items addObject:[IBItem header:@"View a VNC screen (Android, Windows, Mac, Linux)"]];
        for (NSString *host in [self savedHosts]) {
            NSString *label = [host componentsSeparatedByString:@" "].firstObject;
            [items addObject:[[IBItem itemWithTitle:[@"Connect to " stringByAppendingString:label]
                                           subtitle:[host rangeOfString:@" "].location != NSNotFound ? @"with password" : @"no password"
                                              image:nil action:^{ [self connectVNC:host]; }] withShape:IBShapeRow]];
        }
        [items addObject:[[IBItem itemWithTitle:@"Connect to a new VNC server…" subtitle:@"Type \"host[:port] [password]\"" image:nil action:^{
            [[IBTV shared] promptText:@"VNC server: host[:port] [password]" initial:@"" secure:NO done:^(NSString *text) {
                if (!text.length) return;
                NSMutableArray *hosts = [[self savedHosts] mutableCopy];
                if (![hosts containsObject:text]) [hosts insertObject:text atIndex:0];
                [IBSettings set:@"vncHosts" value:[hosts componentsJoinedByString:@"\n"]];
                [self connectVNC:text];
            }];
        }] withShape:IBShapeRow]];
        [items addObject:[[IBItem itemWithTitle:@"Android phone: install droidVNC-NG (free, no root)"
                                       subtitle:@"Start it, set a password, then connect here to its IP on port 5900" image:nil action:nil] withShape:IBShapeRow]];
        [items addObject:[[IBItem itemWithTitle:@"Windows: TightVNC or UltraVNC server  •  Mac: Screen Sharing with a VNC password"
                                       subtitle:@"View only — control stays on the shared device" image:nil action:nil] withShape:IBShapeRow]];
        done(items, nil);
    }];
    page.reloadOnShow = YES;
    return page;
}

@end
