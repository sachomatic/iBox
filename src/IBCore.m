#import "IBCore.h"
#import "IBHTTP.h"
#import <ImageIO/ImageIO.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

@implementation IBItem
+ (instancetype)itemWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                        image:(NSString *)imageURL action:(void (^)(void))action {
    IBItem *i = [self new];
    i.title = title;
    i.subtitle = subtitle;
    i.imageURL = imageURL.length ? imageURL : nil;
    i.action = action;
    return i;
}
+ (instancetype)header:(NSString *)title {
    return [[self itemWithTitle:title subtitle:nil image:nil action:nil] withShape:IBShapeHeader];
}
- (instancetype)withShape:(IBShape)shape {
    self.shape = shape;
    self.hasShape = YES;
    return self;
}
@end

@implementation IBPage
+ (instancetype)pageWithTitle:(NSString *)title shape:(IBShape)shape items:(NSArray *)items {
    IBPage *p = [self new];
    p.title = title;
    p.shape = shape;
    p.items = items;
    return p;
}
+ (instancetype)pageWithTitle:(NSString *)title shape:(IBShape)shape loader:(void (^)(IBPage *, IBPageDone))loader {
    IBPage *p = [self pageWithTitle:title shape:shape items:nil];
    p.loader = loader;
    return p;
}
@end

@implementation IBMedia
+ (instancetype)mediaWithTitle:(NSString *)title url:(NSString *)url {
    IBMedia *m = [self new];
    m.title = title;
    m.url = url;
    return m;
}
@end

/* ---------------- settings ---------------- */

@implementation IBSettings
static NSString *const kSettingsKey = @"ibox.settings";

+ (NSMutableDictionary *)store {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSettingsKey];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
+ (void)save:(NSDictionary *)d {
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kSettingsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
+ (NSString *)get:(NSString *)key {
    id v = [self store][key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
+ (void)set:(NSString *)key value:(NSString *)value {
    [self setObject:value forKey:key];
}
+ (id)object:(NSString *)key {
    return [self store][key];
}
+ (void)setObject:(id)object forKey:(NSString *)key {
    @synchronized (self) {
        NSMutableDictionary *d = [self store];
        if (object) d[key] = object; else [d removeObjectForKey:key];
        [self save:d];
    }
}
+ (NSDictionary *)all {
    return [self store];
}
+ (void)update:(NSDictionary *)values {
    @synchronized (self) {
        NSMutableDictionary *d = [self store];
        for (NSString *k in values) {
            id v = values[k];
            if ([v isKindOfClass:[NSString class]] && [v length] == 0) [d removeObjectForKey:k];
            else if (v != [NSNull null]) d[k] = v;
        }
        [self save:d];
    }
}
+ (NSString *)deviceId {
    NSString *d = [self get:@"deviceId"];
    if (!d) {
        CFUUIDRef u = CFUUIDCreate(NULL);
        d = CFBridgingRelease(CFUUIDCreateString(NULL, u));
        CFRelease(u);
        [self set:@"deviceId" value:d];
    }
    return d;
}
@end

/* ---------------- images ---------------- */

@implementation IBImageLoader

+ (NSCache *)cache {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.totalCostLimit = 24 * 1024 * 1024;
    });
    return c;
}

+ (NSOperationQueue *)queue {
    static NSOperationQueue *q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 4;
    });
    return q;
}

+ (void)load:(NSString *)url maxPixels:(CGFloat)maxPixels completion:(void (^)(UIImage *))completion {
    if (url.length == 0) return completion(nil);
    NSString *key = [NSString stringWithFormat:@"%@#%d", url, (int)maxPixels];
    UIImage *cached = [[self cache] objectForKey:key];
    if (cached) return completion(cached);
    [[self queue] addOperationWithBlock:^{
        NSData *data = nil;
        if ([url hasPrefix:@"/"]) {
            data = [NSData dataWithContentsOfFile:url];
        } else {
            IBHTTPResponse *r = [IBHTTP syncRequest:url method:@"GET" headers:nil body:nil onHeaders:nil onData:nil error:NULL];
            if (r.status == 200) data = r.body;
        }
        UIImage *image = nil;
        if (data.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                       (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                       (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixels)};
                CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                if (cg) {
                    image = [UIImage imageWithCGImage:cg];
                    [[self cache] setObject:image forKey:key cost:CGImageGetWidth(cg) * CGImageGetHeight(cg) * 4];
                    CGImageRelease(cg);
                }
                CFRelease(src);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    }];
}
@end

/* ---------------- helpers ---------------- */

NSString *IBLocalIPAddress(void) {
    struct ifaddrs *ifs = NULL, *i;
    NSString *best = nil;
    if (getifaddrs(&ifs) == 0) {
        for (i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK)) continue;
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof buf);
            NSString *ip = [NSString stringWithUTF8String:buf];
            if (strcmp(i->ifa_name, "en0") == 0) { best = ip; break; }
            if (!best && strncmp(i->ifa_name, "pdp_ip", 6) != 0) best = ip;
        }
        freeifaddrs(ifs);
    }
    return best ?: @"127.0.0.1";
}

NSString *IBFormatTime(NSTimeInterval s) {
    if (isnan(s) || s < 0) s = 0;
    long t = (long)s;
    if (t >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

UIColor *IBColor(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:1];
}

UIFont *IBFont(CGFloat size, BOOL bold) {
    return [UIFont fontWithName:bold ? @"HelveticaNeue-Bold" : @"HelveticaNeue" size:size]
           ?: (bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size]);
}

NSString *IBString(id v) {
    if (!v || v == [NSNull null]) return nil;
    return [v isKindOfClass:[NSString class]] ? v : [v description];
}

NSArray *IBArray(id v) {
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

NSDictionary *IBDict(id v) {
    return [v isKindOfClass:[NSDictionary class]] ? v : @{};
}

NSString *IBResourcePath(NSString *name) {
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:name];
}
