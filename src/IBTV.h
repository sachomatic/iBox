#import <UIKit/UIKit.h>
#import "IBCore.h"

typedef NS_ENUM(NSInteger, IBKey) {
    IBKeyUp, IBKeyDown, IBKeyLeft, IBKeyRight, IBKeySelect, IBKeyBack, IBKeyHome,
    IBKeyPlayPause, IBKeyNext, IBKeyPrev, IBKeyInfo,
};

IBKey IBKeyFromName(NSString *name, BOOL *ok);
NSDictionary *IBBatteryInfo(void);  // {level: 0-100 or -1, state: unplugged|charging|full|unknown}

@class IBPlayer;

// The 10-foot interface drawn on the TV (external screen) or, without one,
// rotated onto the iPhone's own screen.
@interface IBTV : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) IBPlayer *player;
@property (nonatomic, readonly) NSDictionary *textPrompt;  // nil when no prompt
@property (nonatomic, copy) NSString *outputDescription;   // "TV 1280x720", "Preview"...

- (void)layoutForSize:(CGSize)size;
- (void)showHome;
- (void)resetUI;  // stop all playback, close prompts/overlays, back to Home
- (void)pushPage:(IBPage *)page;
- (void)popPage;
- (void)reloadTopPage;
- (BOOL)hasPage:(IBPage *)page;                              // still on the navigation stack
- (void)replaceItems:(NSArray *)items ofPage:(IBPage *)page;  // live update, keeps the focused item
- (void)refreshTitle:(IBPage *)page;
- (void)handleKey:(IBKey)key;
- (void)toast:(NSString *)message;
- (void)setBusy:(BOOL)busy;

- (void)promptText:(NSString *)title initial:(NSString *)initial secure:(BOOL)secure done:(void (^)(NSString *text))done;
- (void)updatePromptText:(NSString *)text;
- (void)submitPrompt:(NSString *)text;
- (void)cancelPrompt;

// Full-screen layer above pages (screen share, VNC, info panels). The handler gets
// keys first; returning NO lets Back dismiss it.
- (void)showOverlay:(UIView *)view keys:(BOOL (^)(IBKey key))handler onClose:(void (^)(void))onClose;
- (void)dismissOverlay;
@property (nonatomic, readonly) UIView *overlay;

- (void)playQueue:(NSArray *)media index:(NSInteger)index;
- (void)playMedia:(IBMedia *)media;
- (void)playerVisibilityChanged;

- (NSDictionary *)stateSnapshot;
// Transparent layer above everything on the TV, including the window iOS opens by itself
// to show web video (YouTube) on the TV: OSDs, panels, messages go here. Same size and
// position as `view`; it is `view` itself when the interface is on the iPhone's screen.
- (UIView *)chrome;
- (UIWindow *)chromeWindow;
- (CGSize)size;
@end
