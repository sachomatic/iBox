#import <UIKit/UIKit.h>

/* Shapes of browse cards. */
typedef NS_ENUM(NSInteger, IBShape) {
    IBShapeTile,    // big colored home tiles
    IBShapeWide,    // 16:9 thumbnails (videos, channels)
    IBShapePoster,  // 2:3 posters (movies, shows)
    IBShapeSquare,  // 1:1 (albums, stations)
    IBShapeRow,     // full-width list rows (tracks, settings)
    IBShapeHeader,  // non-focusable section title
};

@interface IBItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, copy) NSString *glyph;      // emoji/text drawn when there is no image
@property (nonatomic, strong) UIColor *color;     // tile/background color
@property (nonatomic) IBShape shape;              // IBShapeTile.. ; 0 means "use page default" only for tiles
@property (nonatomic) BOOL hasShape;
@property (nonatomic) BOOL fitImage;               // logos: aspect-fit instead of fill
@property (nonatomic) float progress;             // 0..1 watched bar, 0 hides
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)itemWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                        image:(NSString *)imageURL action:(void (^)(void))action;
+ (instancetype)header:(NSString *)title;
- (instancetype)withShape:(IBShape)shape;
@end

typedef void (^IBPageDone)(NSArray *items, NSString *error);

@interface IBPage : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) IBShape shape;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, copy) void (^loader)(IBPage *page, IBPageDone done);
@property (nonatomic, copy) NSString *emptyText;
@property (nonatomic) NSInteger focusIndex;
@property (nonatomic) BOOL reloadOnShow;          // re-run the loader when returning to the page
@property (nonatomic, strong) id context;         // owned helper living as long as the page (e.g. a background checker)
+ (instancetype)pageWithTitle:(NSString *)title shape:(IBShape)shape items:(NSArray *)items;
+ (instancetype)pageWithTitle:(NSString *)title shape:(IBShape)shape loader:(void (^)(IBPage *page, IBPageDone done))loader;
@end

@class IBMedia;
typedef void (^IBResolveDone)(NSString *url, NSString *error);

@interface IBMedia : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *artworkURL;
@property (nonatomic, copy) NSString *url;
@property (nonatomic) BOOL audioOnly;
@property (nonatomic) BOOL live;
@property (nonatomic) NSTimeInterval startAt;
@property (nonatomic, strong) NSDictionary *headers;  // extra HTTP headers the source requires (User-Agent, Referer)
@property (nonatomic, copy) NSString *note;       // shown in the player, e.g. "30 s preview"
@property (nonatomic, copy) void (^resolver)(IBMedia *media, IBResolveDone done);
// Source-specific rows for the in-player options panel (IBOption objects), e.g.
// Jellyfin's audio / subtitle streams. The player adds generic rows itself.
@property (nonatomic, copy) NSArray *(^options)(IBMedia *media);
@property (nonatomic, copy) NSString *captionsURL;          // WebVTT / SubRip drawn by the player, nil = none
@property (nonatomic, strong) NSMutableDictionary *proxyParams;  // HLS choices for the proxy (ib_audio, ib_maxh)
// event: "start", "progress", "pause", "stop"; position in seconds
@property (nonatomic, copy) void (^onEvent)(IBMedia *media, NSString *event, NSTimeInterval position, BOOL paused);
+ (instancetype)mediaWithTitle:(NSString *)title url:(NSString *)url;
@end

/* Persistent settings (NSUserDefaults). */
@interface IBSettings : NSObject
+ (NSString *)get:(NSString *)key;
+ (void)set:(NSString *)key value:(NSString *)value;
+ (NSDictionary *)all;
+ (void)update:(NSDictionary *)values;
+ (id)object:(NSString *)key;
+ (void)setObject:(id)object forKey:(NSString *)key;
+ (NSString *)deviceId;
@end

/* Asynchronous, size-limited image loading with a memory cache. */
@interface IBImageLoader : NSObject
+ (void)load:(NSString *)url maxPixels:(CGFloat)maxPixels completion:(void (^)(UIImage *image))completion;
@end

/* Misc helpers. */
NSString *IBLocalIPAddress(void);
NSString *IBFormatTime(NSTimeInterval seconds);
UIColor *IBColor(unsigned rgb);
UIFont *IBFont(CGFloat size, BOOL bold);
NSString *IBString(id value);  // nil/NSNull safe description
NSArray *IBArray(id value);
NSDictionary *IBDict(id value);
NSString *IBResourcePath(NSString *name);
