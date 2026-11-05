#import "IBHTTP.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const IBHTTPErrorDomain = @"IBHTTP";

static NSError *IBError(NSString *message) {
    return [NSError errorWithDomain:IBHTTPErrorDomain code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Network error"}];
}

/* Buffered reader over an ib_conn. */
typedef struct {
    ib_conn *conn;
    unsigned char buf[16384];
    size_t pos, len;
    int eof;
} IBReader;

static int reader_fill(IBReader *r) {
    if (r->pos < r->len) return 1;
    if (r->eof) return 0;
    long n = ib_read(r->conn, r->buf, sizeof r->buf);
    if (n <= 0) { r->eof = 1; return 0; }
    r->pos = 0;
    r->len = (size_t)n;
    return 1;
}

// Reads one CRLF-terminated line (without the terminator). Returns nil at EOF.
static NSString *reader_line(IBReader *r, NSUInteger maxLength) {
    NSMutableData *line = [NSMutableData data];
    while (reader_fill(r)) {
        unsigned char *start = r->buf + r->pos;
        unsigned char *nl = memchr(start, '\n', r->len - r->pos);
        size_t take = nl ? (size_t)(nl - start) + 1 : r->len - r->pos;
        [line appendBytes:start length:take];
        r->pos += take;
        if (nl) break;
        if (line.length > maxLength) return nil;
    }
    if (line.length == 0 && r->eof) return nil;
    NSUInteger n = line.length;
    const char *bytes = line.bytes;
    while (n > 0 && (bytes[n - 1] == '\n' || bytes[n - 1] == '\r')) n--;
    return [[NSString alloc] initWithBytes:bytes length:n encoding:NSISOLatin1StringEncoding];
}

static long reader_read(IBReader *r, void *dst, size_t max) {
    if (!reader_fill(r)) return 0;
    size_t take = MIN(max, r->len - r->pos);
    memcpy(dst, r->buf + r->pos, take);
    r->pos += take;
    return (long)take;
}

static NSDictionary *read_headers(IBReader *r) {
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (int i = 0; i < 200; i++) {
        NSString *line = reader_line(r, 65536);
        if (line == nil) return nil;
        if (line.length == 0) return headers;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        headers[key] = headers[key] ? [NSString stringWithFormat:@"%@, %@", headers[key], value] : value;
    }
    return headers;
}

/* ================= client ================= */

@implementation IBHTTPResponse
- (NSString *)text {
    NSString *s = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    return s ?: [[NSString alloc] initWithData:self.body encoding:NSISOLatin1StringEncoding];
}
- (id)json {
    if (self.body.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:self.body options:NSJSONReadingAllowFragments error:NULL];
}
@end

@implementation IBHTTP

+ (dispatch_queue_t)queue {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("ibox.http", DISPATCH_QUEUE_CONCURRENT); });
    return q;
}

+ (IBHTTPResponse *)syncRequest:(NSString *)urlString method:(NSString *)method headers:(NSDictionary *)headers
                           body:(NSData *)body onHeaders:(BOOL (^)(IBHTTPResponse *))onHeaders
                         onData:(BOOL (^)(const void *, size_t))onData error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:urlString];
    method = method ?: @"GET";
    for (int redirects = 0; redirects < 6; redirects++) {
        if (!url.host) {
            if (error) *error = IBError([NSString stringWithFormat:@"Bad URL: %@", urlString]);
            return nil;
        }
        BOOL tls = [[url.scheme lowercaseString] isEqualToString:@"https"];
        int port = url.port ? url.port.intValue : (tls ? 443 : 80);
        char err[256] = "";
        ib_conn *conn = ib_connect(url.host.UTF8String, port, tls, 20, err, sizeof err);
        if (!conn) {
            if (error) *error = IBError([NSString stringWithUTF8String:err]);
            return nil;
        }

        NSString *path = CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)url));
        if (path.length == 0) path = @"/";
        if (url.query) path = [path stringByAppendingFormat:@"?%@", url.query];
        BOOL defaultPort = !url.port || (tls && port == 443) || (!tls && port == 80);
        NSString *hostHeader = defaultPort ? url.host : [NSString stringWithFormat:@"%@:%d", url.host, port];

        NSMutableString *req = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\n", method, path, hostHeader];
        NSMutableDictionary *h = [@{@"User-Agent": @"iBox/1.0 (iPhone; iOS 6)",
                                    @"Accept": @"*/*",
                                    @"Accept-Encoding": @"identity",
                                    @"Connection": @"close"} mutableCopy];
        [h addEntriesFromDictionary:headers ?: @{}];
        if (body) h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
        for (NSString *k in h) [req appendFormat:@"%@: %@\r\n", k, h[k]];
        [req appendString:@"\r\n"];
        NSData *head = [req dataUsingEncoding:NSUTF8StringEncoding];
        if (ib_write_all(conn, head.bytes, head.length) < 0 ||
            (body.length && ib_write_all(conn, body.bytes, body.length) < 0) || ib_flush(conn) < 0) {
            int tlsErr = ib_tls_error(conn);
            ib_close(conn);
            if (error) *error = IBError(tlsErr ? [NSString stringWithFormat:@"TLS error %d with %@", tlsErr, url.host]
                                               : [NSString stringWithFormat:@"Cannot send request to %@", url.host]);
            return nil;
        }

        IBReader *r = calloc(1, sizeof *r);
        r->conn = conn;
        NSString *statusLine = reader_line(r, 8192);
        NSArray *parts = [statusLine componentsSeparatedByString:@" "];
        NSDictionary *respHeaders = parts.count >= 2 ? read_headers(r) : nil;
        if (!respHeaders) {
            int tlsErr = ib_tls_error(conn);
            free(r);
            ib_close(conn);
            if (error) *error = IBError(tlsErr ? [NSString stringWithFormat:@"TLS error %d with %@", tlsErr, url.host]
                                               : [NSString stringWithFormat:@"No HTTP response from %@", url.host]);
            return nil;
        }
        IBHTTPResponse *resp = [IBHTTPResponse new];
        resp.status = [parts[1] integerValue];
        resp.headers = respHeaders;
        resp.url = url;

        NSString *location = respHeaders[@"location"];
        if (resp.status >= 300 && resp.status < 400 && resp.status != 304 && location) {
            free(r);
            ib_close(conn);
            url = [NSURL URLWithString:location relativeToURL:url].absoluteURL;
            if (resp.status == 303 || ((resp.status == 301 || resp.status == 302) && ![method isEqualToString:@"GET"])) {
                method = @"GET";
                body = nil;
            }
            continue;
        }

        BOOL wantBody = ![method isEqualToString:@"HEAD"] && resp.status != 204 && resp.status != 304;
        if (onHeaders && !onHeaders(resp)) wantBody = NO;
        NSMutableData *accumulated = onData ? nil : [NSMutableData data];
        if (wantBody) {
            NSString *te = [respHeaders[@"transfer-encoding"] lowercaseString] ?: @"";  // never message nil for a struct
            BOOL chunked = [te rangeOfString:@"chunked"].location != NSNotFound;
            long long remaining = respHeaders[@"content-length"] ? [respHeaders[@"content-length"] longLongValue] : -1;
            unsigned char buf[16384];
            BOOL keepGoing = YES;
            while (keepGoing) {
                long long chunkLeft = remaining;
                if (chunked) {
                    NSString *sizeLine = reader_line(r, 1024);
                    if (!sizeLine) break;
                    unsigned long long size = strtoull(sizeLine.UTF8String, NULL, 16);
                    if (size == 0) break;
                    chunkLeft = (long long)size;
                }
                while (chunkLeft != 0) {
                    size_t want = chunkLeft < 0 ? sizeof buf : (size_t)MIN((long long)sizeof buf, chunkLeft);
                    long n = reader_read(r, buf, want);
                    if (n <= 0) { keepGoing = NO; break; }
                    if (chunkLeft > 0) chunkLeft -= n;
                    if (onData) {
                        if (!onData(buf, (size_t)n)) { keepGoing = NO; break; }
                    } else {
                        [accumulated appendBytes:buf length:(size_t)n];
                    }
                }
                if (!chunked) break;
                reader_line(r, 16);  // CRLF after each chunk
            }
        }
        free(r);
        ib_close(conn);
        resp.body = accumulated;
        return resp;
    }
    if (error) *error = IBError(@"Too many redirects");
    return nil;
}

+ (void)request:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers
           body:(NSData *)body completion:(IBHTTPCompletion)completion {
    dispatch_async([self queue], ^{
        NSError *error = nil;
        IBHTTPResponse *resp = [self syncRequest:url method:method headers:headers body:body
                                       onHeaders:nil onData:nil error:&error];
        if (resp && resp.status >= 400 && !error) {
            NSString *snippet = [[resp text] substringToIndex:MIN((NSUInteger)160, [resp text].length)];
            error = [NSError errorWithDomain:IBHTTPErrorDomain code:resp.status
                                    userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:@"HTTP %ld %@", (long)resp.status, snippet ?: @""]}];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(resp, error); });
    });
}

+ (void)get:(NSString *)url headers:(NSDictionary *)headers completion:(IBHTTPCompletion)completion {
    [self request:url method:@"GET" headers:headers body:nil completion:completion];
}

+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers completion:(void (^)(id, NSError *))completion {
    NSMutableDictionary *h = [@{@"Accept": @"application/json"} mutableCopy];
    [h addEntriesFromDictionary:headers ?: @{}];
    [self get:url headers:h completion:^(IBHTTPResponse *response, NSError *error) {
        id json = error ? nil : [response json];
        if (!error && !json) error = IBError(@"Invalid JSON response");
        completion(json, error);
    }];
}

+ (void)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object
      completion:(void (^)(id, NSError *))completion {
    NSMutableDictionary *h = [@{@"Accept": @"application/json", @"Content-Type": @"application/json"} mutableCopy];
    [h addEntriesFromDictionary:headers ?: @{}];
    NSData *body = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] : [NSData data];
    [self request:url method:@"POST" headers:h body:body completion:^(IBHTTPResponse *response, NSError *error) {
        if (completion) completion(error ? nil : [response json], error);
    }];
}

+ (NSString *)escape:(NSString *)component {
    return CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(
        NULL, (__bridge CFStringRef)(component ?: @""), NULL, CFSTR(":/?#[]@!$&'()*+,;= \"<>%{}|\\^`"),
        kCFStringEncodingUTF8));
}

+ (NSString *)query:(NSDictionary *)params {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in params) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", [self escape:k], [self escape:[params[k] description]]]];
    }
    return [parts componentsJoinedByString:@"&"];
}

@end

/* ================= server ================= */

@implementation IBHTTPRequest
- (id)jsonBody {
    if (self.body.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:self.body options:0 error:NULL];
}
@end

@interface IBHTTPConnection ()
@property (nonatomic) ib_conn *conn;
@property (nonatomic, readwrite) BOOL headersSent;
@property (nonatomic) BOOL chunked;
@property (nonatomic) BOOL failed;
@end

static NSString *StatusText(NSInteger s) {
    switch (s) {
        case 200: return @"OK";
        case 204: return @"No Content";
        case 206: return @"Partial Content";
        case 302: return @"Found";
        case 400: return @"Bad Request";
        case 404: return @"Not Found";
        case 416: return @"Range Not Satisfiable";
        case 500: return @"Internal Server Error";
        case 502: return @"Bad Gateway";
        default: return @"Status";
    }
}

@implementation IBHTTPConnection

- (BOOL)sendStatus:(NSInteger)status headers:(NSDictionary *)headers {
    if (self.headersSent) return NO;
    self.headersSent = YES;
    NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, StatusText(status)];
    BOOL hasLength = NO;
    for (NSString *k in headers) {
        if ([[k lowercaseString] isEqualToString:@"content-length"]) hasLength = YES;
        [head appendFormat:@"%@: %@\r\n", k, headers[k]];
    }
    if (!hasLength) {
        self.chunked = YES;
        [head appendString:@"Transfer-Encoding: chunked\r\n"];
    }
    [head appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [head appendFormat:@"Connection: %@\r\n\r\n", self.keepAlive ? @"keep-alive" : @"close"];
    NSData *d = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (ib_write_all(self.conn, d.bytes, d.length) < 0 || ib_flush(self.conn) < 0) self.failed = YES;
    return !self.failed;
}

- (BOOL)write:(const void *)bytes length:(size_t)length {
    if (self.failed) return NO;
    if (length == 0) return YES;
    if (self.chunked) {
        char hdr[24];
        int n = snprintf(hdr, sizeof hdr, "%zx\r\n", length);
        if (ib_write_all(self.conn, hdr, (size_t)n) < 0) self.failed = YES;
    }
    if (!self.failed && ib_write_all(self.conn, bytes, length) < 0) self.failed = YES;
    if (!self.failed && self.chunked && ib_write_all(self.conn, "\r\n", 2) < 0) self.failed = YES;
    if (!self.failed && ib_flush(self.conn) < 0) self.failed = YES;
    return !self.failed;
}

- (void)finish {
    if (!self.headersSent) [self sendText:@"" status:204];
    if (self.chunked && !self.failed) {
        ib_write_all(self.conn, "0\r\n\r\n", 5);
        ib_flush(self.conn);
    }
}

- (void)sendData:(NSData *)data type:(NSString *)type status:(NSInteger)status {
    [self sendStatus:status headers:@{@"Content-Type": type ?: @"application/octet-stream",
                                      @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                                      @"Cache-Control": @"no-store"}];
    if (data.length && !self.failed) {
        if (ib_write_all(self.conn, data.bytes, data.length) < 0 || ib_flush(self.conn) < 0) self.failed = YES;
    }
}

- (void)sendJSON:(id)object {
    NSData *d = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:NULL];
    [self sendData:d type:@"application/json; charset=utf-8" status:200];
}

- (void)sendText:(NSString *)text status:(NSInteger)status {
    [self sendData:[text dataUsingEncoding:NSUTF8StringEncoding] type:@"text/plain; charset=utf-8" status:status];
}

@end

@interface IBHTTPServer ()
@property (nonatomic, strong) NSMutableArray *routes;
@property (nonatomic, strong) NSMutableDictionary *listeners;  // port -> listening fd (-1 while rebinding)
@end

@implementation IBHTTPServer

- (instancetype)init {
    if ((self = [super init])) _routes = [NSMutableArray array];
    return self;
}

- (void)route:(NSString *)method path:(NSString *)path handler:(IBRouteHandler)handler {
    [self.routes addObject:@[method, path, [handler copy]]];
}

- (IBRouteHandler)handlerFor:(NSString *)method path:(NSString *)path {
    for (NSArray *r in self.routes) {
        if (![r[0] isEqualToString:@"*"] && ![r[0] isEqualToString:method]) continue;
        NSString *p = r[1];
        if ([p hasSuffix:@"*"] ? [path hasPrefix:[p substringToIndex:p.length - 1]] : [path isEqualToString:p]) return r[2];
    }
    return nil;
}

static int BindPort(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 32) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)listenOnPort:(int)port tls:(BOOL)tls {
    int fd = BindPort(port);
    if (fd < 0) return NO;
    @synchronized (self) {
        if (!self.listeners) self.listeners = [NSMutableDictionary dictionary];
        self.listeners[@(port)] = @(fd);
    }
    [NSThread detachNewThreadSelector:@selector(acceptLoop:) toTarget:self withObject:@[@(port), @(tls)]];
    return YES;
}

// iOS reclaims the listening sockets of an app it suspends (screen locked, Home
// pressed): after resuming, accept() fails for good. The loop then rebinds the port.
- (void)acceptLoop:(NSArray *)args {
    int port = [args[0] intValue];
    BOOL tls = [args[1] boolValue];
    int failures = 0;
    for (;;) {
        @autoreleasepool {
            int lfd;
            @synchronized (self) { lfd = [self.listeners[@(port)] intValue]; }
            int cfd = lfd >= 0 ? accept(lfd, NULL, NULL) : -1;
            if (cfd >= 0) {
                failures = 0;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self serveSocket:cfd tls:tls];
                });
                continue;
            }
            if (lfd >= 0 && errno == EINTR) continue;
            if (lfd >= 0 && errno != EBADF && ++failures < 3) {
                usleep(100000);
                continue;
            }
            if (lfd >= 0) close(lfd);
            int nfd = BindPort(port);
            @synchronized (self) { self.listeners[@(port)] = @(nfd); }
            failures = 0;
            if (nfd < 0) sleep(1);
            else NSLog(@"iBox: server on port %d reopened", port);
        }
    }
}

- (void)ensureListening {
    NSDictionary *listeners;
    @synchronized (self) { listeners = [self.listeners copy]; }
    for (NSNumber *port in listeners) {
        int probe = socket(AF_INET, SOCK_STREAM, 0);
        if (probe < 0) continue;
        int on = 1;
        setsockopt(probe, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        fcntl(probe, F_SETFL, O_NONBLOCK);
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof addr);
        addr.sin_len = sizeof addr;
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)port.intValue);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        BOOL alive = connect(probe, (struct sockaddr *)&addr, sizeof addr) == 0;
        if (!alive && errno == EINPROGRESS) {
            struct pollfd pfd = { probe, POLLOUT, 0 };
            int soerr = 1;
            socklen_t len = sizeof soerr;
            alive = poll(&pfd, 1, 500) == 1 && getsockopt(probe, SOL_SOCKET, SO_ERROR, &soerr, &len) == 0 && soerr == 0;
        }
        close(probe);
        if (!alive) {
            NSLog(@"iBox: server on port %@ is dead, restarting it", port);
            int fd = [listeners[port] intValue];
            if (fd >= 0) shutdown(fd, SHUT_RDWR);  // wakes accept(), which then rebinds
        }
    }
}

static NSDictionary *ParseQuery(NSString *q) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *pair in [q componentsSeparatedByString:@"&"]) {
        if (pair.length == 0) continue;
        NSRange eq = [pair rangeOfString:@"="];
        NSString *k = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
        NSString *v = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1];
        k = [[k stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        v = [[v stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (k) d[k] = v ?: @"";
    }
    return d;
}

- (void)serveSocket:(int)fd tls:(BOOL)tls {
    ib_conn *conn = ib_wrap_accepted(fd, tls);
    if (!conn) {
        close(fd);
        return;
    }
    IBReader *r = calloc(1, sizeof *r);
    r->conn = conn;
    for (int served = 0; served < 10000; served++) {
        @autoreleasepool {
            NSString *line = reader_line(r, 16384);
            if (line.length == 0) break;
            NSArray *parts = [line componentsSeparatedByString:@" "];
            NSDictionary *headers = read_headers(r);
            if (parts.count < 3 || !headers) break;

            IBHTTPRequest *req = [IBHTTPRequest new];
            req.method = parts[0];
            req.secure = tls;
            NSString *target = parts[1];
            NSRange qm = [target rangeOfString:@"?"];
            req.path = qm.location == NSNotFound ? target : [target substringToIndex:qm.location];
            req.query = qm.location == NSNotFound ? @{} : ParseQuery([target substringFromIndex:qm.location + 1]);
            req.headers = headers;

            long long length = [headers[@"content-length"] longLongValue];
            if (length > 32 * 1024 * 1024) break;
            if (length > 0) {
                NSMutableData *body = [NSMutableData dataWithLength:(NSUInteger)length];
                size_t got = 0;
                while (got < (size_t)length) {
                    long n = reader_read(r, (char *)body.mutableBytes + got, (size_t)length - got);
                    if (n <= 0) break;
                    got += (size_t)n;
                }
                if (got < (size_t)length) break;
                req.body = body;
            }

            IBHTTPConnection *c = [IBHTTPConnection new];
            c.conn = conn;
            c.keepAlive = [parts[2] isEqualToString:@"HTTP/1.1"] &&
                          ![[headers[@"connection"] lowercaseString] isEqualToString:@"close"];
            if ([req.method isEqualToString:@"OPTIONS"]) {
                [c sendStatus:204 headers:@{@"Content-Length": @"0",
                                            @"Access-Control-Allow-Methods": @"GET, POST, OPTIONS",
                                            @"Access-Control-Allow-Headers": @"Content-Type"}];
            } else {
                IBRouteHandler handler = [self handlerFor:req.method path:req.path];
                if (handler) {
                    @try {
                        handler(req, c);
                    } @catch (NSException *e) {
                        NSLog(@"iBox: handler exception for %@: %@", req.path, e);
                        if (!c.headersSent) [c sendText:e.reason status:500];
                        c.keepAlive = NO;
                    }
                } else {
                    [c sendText:@"Not found" status:404];
                }
            }
            [c finish];
            if (!c.keepAlive || c.failed) break;
        }
    }
    free(r);
    ib_close(conn);
}

@end
