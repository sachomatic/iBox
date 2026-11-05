#import <UIKit/UIKit.h>
#import "IBTV.h"

// One row of the in-player options panel ("Audio", "Subtitles", "Quality"...).
@interface IBOption : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *choices;    // labels
@property (nonatomic) NSInteger selected;
@property (nonatomic, copy) void (^apply)(NSInteger index);
+ (instancetype)optionWithTitle:(NSString *)title choices:(NSArray *)choices selected:(NSInteger)selected
                          apply:(void (^)(NSInteger index))apply;
@end

// Options panel drawn over a playing video: Up/Down pick a row, Left/Right change
// its value (applied after a short pause, so cycling through choices doesn't
// restart a stream at every step), OK or Back close it.
@interface IBOptionsPanel : UIView
+ (instancetype)panelWithOptions:(NSArray *)options;
- (void)layoutInBounds:(CGRect)bounds;
- (BOOL)handleKey:(IBKey)key;  // NO once the panel should close
- (void)commit;                // apply a pending change now
@property (nonatomic, readonly) NSArray *options;
- (NSArray *)stateSnapshot;    // for /api/state
@end

// Subtitles drawn by iBox itself (WebVTT or SubRip text), for sources whose own
// tracks iOS 6 can't render.
@interface IBSubtitleTrack : NSObject
+ (void)load:(NSString *)url done:(void (^)(IBSubtitleTrack *track, NSString *error))done;
+ (instancetype)trackWithText:(NSString *)text;
- (NSString *)textAt:(NSTimeInterval)t;
@property (nonatomic, readonly) NSUInteger count;
@end

// A label styled for subtitles (white text on a translucent box), bottom-centred.
@interface IBSubtitleView : UIView
- (void)setText:(NSString *)text inBounds:(CGRect)bounds raised:(BOOL)raised;
@end
