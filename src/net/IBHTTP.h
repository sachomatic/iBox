#import <Foundation/Foundation.h>
#include "ibnet.h"

/* ---------------- client ---------------- */

@interface IBHTTPResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, strong) NSDictionary *headers;  // lowercase keys
@property (nonatomic, strong) NSData *body;
@property (nonatomic, strong) NSURL *url;              // after redirects
- (NSString *)text;
- (id)json;
@end

typedef void (^IBHTTPCompletion)(IBHTTPResponse *response, NSError *error);

@interface IBHTTP : NSObject
// Blocking request. When onData is set the body is streamed to it instead of being
// buffered; onHeaders may return NO to skip reading the body.
+ (IBHTTPResponse *)syncRequest:(NSString *)url
                         method:(NSString *)method
                        headers:(NSDictionary *)headers
                           body:(NSData *)body
                      onHeaders:(BOOL (^)(IBHTTPResponse *response))onHeaders
                         onData:(BOOL (^)(const void *bytes, size_t length))onData
                          error:(NSError **)error;

// Asynchronous helpers; completions run on the main thread.
+ (void)get:(NSString *)url headers:(NSDictionary *)headers completion:(IBHTTPCompletion)completion;
+ (void)request:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers
           body:(NSData *)body completion:(IBHTTPCompletion)completion;
+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers
     completion:(void (^)(id json, NSError *error))completion;
+ (void)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object
      completion:(void (^)(id json, NSError *error))completion;

+ (NSString *)escape:(NSString *)component;
+ (NSString *)query:(NSDictionary *)params;
@end

/* ---------------- server ---------------- */

@interface IBHTTPRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSDictionary *query;
@property (nonatomic, strong) NSDictionary *headers;  // lowercase keys
@property (nonatomic, strong) NSData *body;
@property (nonatomic) BOOL secure;
- (id)jsonBody;
@end

@interface IBHTTPConnection : NSObject
@property (nonatomic, readonly) BOOL headersSent;
@property (nonatomic) BOOL keepAlive;
- (BOOL)sendStatus:(NSInteger)status headers:(NSDictionary *)headers;  // body follows via -write:
- (BOOL)write:(const void *)bytes length:(size_t)length;
- (void)sendData:(NSData *)data type:(NSString *)type status:(NSInteger)status;
- (void)sendJSON:(id)object;
- (void)sendText:(NSString *)text status:(NSInteger)status;
@end

typedef void (^IBRouteHandler)(IBHTTPRequest *request, IBHTTPConnection *connection);

@interface IBHTTPServer : NSObject
- (void)route:(NSString *)method path:(NSString *)path handler:(IBRouteHandler)handler;  // path ending in * = prefix
- (BOOL)listenOnPort:(int)port tls:(BOOL)tls;
- (void)ensureListening;  // reopens ports iOS took away while the app was suspended (blocking)
@end
