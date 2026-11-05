#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "IBTV.h"
#import "IBPlayer.h"
#import "IBServices.h"
#import "IBRemoteAPI.h"
#include <signal.h>

/* ================= touch input → keys ================= */

// Turns a view into a trackpad: drag to move focus (one step per ~50 pt, so long
// drags scroll), tap = OK, two-finger tap = Back, long press = Home.
@interface IBTouchpad : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic) CGPoint anchor;
+ (instancetype)attachTo:(UIView *)view;
@end

@implementation IBTouchpad
+ (instancetype)attachTo:(UIView *)view {
    IBTouchpad *t = [IBTouchpad new];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:t action:@selector(pan:)];
    pan.maximumNumberOfTouches = 1;
    [view addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(tap:)];
    [view addGestureRecognizer:tap];
    UITapGestureRecognizer *back = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(back:)];
    back.numberOfTouchesRequired = 2;
    [view addGestureRecognizer:back];
    UILongPressGestureRecognizer *home = [[UILongPressGestureRecognizer alloc] initWithTarget:t action:@selector(home:)];
    home.minimumPressDuration = 0.8;
    [view addGestureRecognizer:home];
    view.userInteractionEnabled = YES;
    return t;
}
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:g.view];
    if (g.state == UIGestureRecognizerStateBegan) self.anchor = CGPointZero;
    CGFloat dx = p.x - self.anchor.x, dy = p.y - self.anchor.y, step = 50;
    if (fabsf(dx) < step && fabsf(dy) < step) return;
    IBKey key = fabsf(dx) > fabsf(dy) ? (dx > 0 ? IBKeyRight : IBKeyLeft) : (dy > 0 ? IBKeyDown : IBKeyUp);
    self.anchor = p;
    [[IBTV shared] handleKey:key];
}
- (void)tap:(UITapGestureRecognizer *)g { [[IBTV shared] handleKey:IBKeySelect]; }
- (void)back:(UITapGestureRecognizer *)g { [[IBTV shared] handleKey:IBKeyBack]; }
- (void)home:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [[IBTV shared] handleKey:IBKeyHome];
}
@end

/* ================= phone screen ================= */

@interface IBPhoneController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIView *remote;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) IBTouchpad *padRemote, *padPreview;
@property (nonatomic) BOOL tvAttached;
@property (nonatomic, strong) NSTimer *dimTimer;
- (void)setTVAttached:(BOOL)attached;
@end

@implementation IBPhoneController

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = IBColor(0x0B0F1A);
    self.view = v;
    CGSize s = v.bounds.size;

    _remote = [[UIView alloc] initWithFrame:v.bounds];
    _remote.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:_remote];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, s.width - 40, 34)];
    title.text = @"iBox remote";
    title.font = IBFont(26, YES);
    title.textColor = [UIColor whiteColor];
    title.backgroundColor = [UIColor clearColor];
    [_remote addSubview:title];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, s.width - 40, 40)];
    _status.font = IBFont(13, NO);
    _status.numberOfLines = 2;
    _status.textColor = IBColor(0x8C95AD);
    _status.backgroundColor = [UIColor clearColor];
    [_remote addSubview:_status];

    CGFloat padTop = 110, buttonsH = 120;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(16, padTop, s.width - 32, s.height - padTop - buttonsH - 16)];
    pad.backgroundColor = IBColor(0x161C2D);
    pad.layer.cornerRadius = 18;
    pad.layer.borderColor = IBColor(0x2A3350).CGColor;
    pad.layer.borderWidth = 1;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectInset(pad.bounds, 20, 20)];
    hint.text = @"Drag to move\nTap = OK\nTwo-finger tap = Back\nHold = Home";
    hint.numberOfLines = 4;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = IBColor(0x4A5470);
    hint.font = IBFont(16, NO);
    hint.backgroundColor = [UIColor clearColor];
    [pad addSubview:hint];
    [_remote addSubview:pad];
    _padRemote = [IBTouchpad attachTo:pad];

    NSArray *buttons = @[@[@"Back", @(IBKeyBack)], @[@"Home", @(IBKeyHome)], @[@"Pause", @(IBKeyPlayPause)], @[@"Options", @(IBKeyInfo)],
                         @[@"Prev", @(IBKeyPrev)], @[@"Next", @(IBKeyNext)], @[@"Keyboard", @(-1)]];
    CGFloat bw = (s.width - 32 - 8 * 3) / 4, bh = 48;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        NSUInteger row = i / 4, col = i % 4;
        CGFloat w = row == 1 && col == 2 ? bw * 2 + 8 : bw;  // Keyboard takes the rest of the row
        b.frame = CGRectMake(16 + col * (bw + 8), s.height - buttonsH + row * (bh + 10), w, bh);
        b.backgroundColor = [buttons[i][1] integerValue] == IBKeyInfo ? IBColor(0x1D4E89) : IBColor(0x232B42);
        b.layer.cornerRadius = 10;
        b.titleLabel.font = IBFont(16, YES);
        [b setTitle:buttons[i][0] forState:UIControlStateNormal];
        b.tag = [buttons[i][1] integerValue];
        [b addTarget:self action:@selector(button:) forControlEvents:UIControlEventTouchUpInside];
        [_remote addSubview:b];
    }

    _field = [[UITextField alloc] initWithFrame:CGRectMake(16, 110, s.width - 32, 44)];
    _field.backgroundColor = [UIColor whiteColor];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.font = IBFont(18, NO);
    _field.returnKeyType = UIReturnKeyDone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.delegate = self;
    _field.hidden = YES;
    [_field addTarget:self action:@selector(fieldChanged) forControlEvents:UIControlEventEditingChanged];
    [v addSubview:_field];

    [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self setTVAttached:NO];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotate { return NO; }

- (void)setTVAttached:(BOOL)attached {
    self.tvAttached = attached;
    IBTV *tv = [IBTV shared];
    if (attached) {
        self.remote.hidden = NO;
        [self wake];
        return;
    }
    // No TV: show the TV interface on the phone itself, rotated to landscape.
    [UIScreen mainScreen].brightness = MAX([UIScreen mainScreen].brightness, 0.5);
    self.remote.hidden = YES;
    CGSize s = self.view.bounds.size;
    [tv.view removeFromSuperview];
    tv.view.transform = CGAffineTransformIdentity;
    [tv layoutForSize:CGSizeMake(s.height, s.width)];
    tv.view.center = CGPointMake(s.width / 2, s.height / 2);
    tv.view.transform = CGAffineTransformMakeRotation(M_PI_2);
    [self.view insertSubview:tv.view belowSubview:self.field];
    if (!self.padPreview) self.padPreview = [IBTouchpad attachTo:tv.view];
    tv.outputDescription = @"No TV detected — preview on iPhone";
}

- (void)button:(UIButton *)b {
    [self wake];
    if (b.tag < 0) {
        IBTV *tv = [IBTV shared];
        if (!tv.textPrompt) {
            [tv promptText:@"Type here" initial:@"" secure:NO done:^(NSString *text) { [IBServices openLink:text]; }];
        }
        return;
    }
    [[IBTV shared] handleKey:(IBKey)b.tag];
}

- (void)poll {
    IBTV *tv = [IBTV shared];
    self.status.text = [NSString stringWithFormat:@"%@\nWeb remote: http://%@:8080", tv.outputDescription ?: @"", IBLocalIPAddress()];
    NSDictionary *prompt = tv.textPrompt;
    if (prompt && self.field.hidden) {
        self.field.hidden = NO;
        self.field.placeholder = prompt[@"title"];
        self.field.secureTextEntry = [prompt[@"secure"] boolValue];
        self.field.text = prompt[@"value"];
        [self.view bringSubviewToFront:self.field];
        [self.field becomeFirstResponder];
        [self wake];
    } else if (!prompt && !self.field.hidden) {
        self.field.hidden = YES;
        [self.field resignFirstResponder];
    } else if (prompt && !self.field.isFirstResponder && ![self.field.text isEqualToString:prompt[@"value"]]) {
        self.field.text = prompt[@"value"];  // typed from the web remote
    }
}

- (void)fieldChanged {
    [[IBTV shared] updatePromptText:self.field.text];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [[IBTV shared] submitPrompt:textField.text];
    return NO;
}

// Dim the phone panel while it only serves as a remote next to the TV.
- (void)wake {
    if (!self.tvAttached) return;
    [UIScreen mainScreen].brightness = 0.6;
    [self.dimTimer invalidate];
    self.dimTimer = [NSTimer scheduledTimerWithTimeInterval:45 target:self selector:@selector(dim) userInfo:nil repeats:NO];
}

- (void)dim {
    if (self.tvAttached && !self.field.isFirstResponder) [UIScreen mainScreen].brightness = 0.02;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self wake];
    [super touchesBegan:touches withEvent:event];
}

@end

/* ================= app delegate ================= */

@interface IBAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window, *tvWindow;
@property (nonatomic, strong) IBPhoneController *phone;
@property (nonatomic, strong) NSNetService *bonjour;
@end

@implementation IBAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    app.idleTimerDisabled = YES;
    app.statusBarHidden = YES;
    NSString *ua = [IBSettings get:@"debugWebUA"];  // experiment: browser identity of the web views
    if (ua.length) [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"UserAgent": ua}];

    [IBRemoteAPI startServers];
    [IBServices start];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.phone = [IBPhoneController new];
    self.window.rootViewController = self.phone;
    [self.window makeKeyAndVisible];

    [[IBTV shared] showHome];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(screensChanged) name:UIScreenDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(screensChanged) name:UIScreenDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(screensChanged) name:@"IBTVPictureChanged" object:nil];
    [self screensChanged];

    self.bonjour = [[NSNetService alloc] initWithDomain:@"" type:@"_http._tcp." name:@"iBox" port:8080];
    [self.bonjour publish];
    return YES;
}

- (UIScreenMode *)bestModeFor:(UIScreen *)screen {
    UIScreenMode *best = screen.preferredMode;
    for (UIScreenMode *m in screen.availableModes) {
        // The A4 drives 720p comfortably; 1080p modes only cost frame rate.
        if (m.size.height > 720) continue;
        if (!best || best.size.height > 720 || m.size.width * m.size.height > best.size.width * best.size.height) best = m;
    }
    return best ?: screen.currentMode;
}

- (void)screensChanged {
    IBTV *tv = [IBTV shared];
    UIScreen *external = nil;
    for (UIScreen *s in [UIScreen screens]) {
        if (s != [UIScreen mainScreen]) external = s;
    }
    if (!external) {
        self.tvWindow.hidden = YES;
        self.tvWindow = nil;
        [self.phone setTVAttached:NO];
        return;
    }
    UIScreenMode *mode = [self bestModeFor:external];
    if (mode) external.currentMode = mode;
    // Overscan compensation shrinks the picture for TVs that crop its edges. HDMI TVs and
    // monitors usually show every pixel, so fill the screen there; analog (SD) TVs crop,
    // so they keep the shrink. Settings > "TV picture" overrides it.
    NSString *fit = [IBSettings get:@"tvPicture"] ?: @"auto";
    BOOL shrink = [fit isEqualToString:@"shrink"] || ([fit isEqualToString:@"auto"] && mode.size.height < 600);
    external.overscanCompensation = shrink ? UIScreenOverscanCompensationScale : UIScreenOverscanCompensationInsetApplicationFrame;
    CGSize px = external.bounds.size;
    CGFloat par = mode.pixelAspectRatio > 0 ? mode.pixelAspectRatio : 1;

    self.tvWindow = [[UIWindow alloc] initWithFrame:external.bounds];
    self.tvWindow.screen = external;
    self.tvWindow.backgroundColor = [UIColor blackColor];
    UIViewController *vc = [UIViewController new];
    vc.wantsFullScreenLayout = YES;
    vc.view = [[UIView alloc] initWithFrame:external.bounds];
    // Transparent: UIKit puts the root view back on top of the window's subviews when the
    // window appears, and a black one hid the whole TV interface. The window is black.
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    self.tvWindow.rootViewController = vc;

    [tv.view removeFromSuperview];
    tv.view.transform = CGAffineTransformIdentity;
    // Lay out in square units, then squeeze back for non-square (analog TV) pixels.
    [tv layoutForSize:CGSizeMake(roundf(px.width * par), px.height)];
    tv.view.center = CGPointMake(px.width / 2, px.height / 2);
    tv.view.transform = CGAffineTransformMakeScale(1 / par, 1);
    // Straight on the window, not in the root view: with overscan compensation off, UIKit
    // lays the root view out to the screen's inset applicationFrame at some point, which
    // shifted the whole picture right and down (black border left and top).
    [self.tvWindow addSubview:tv.view];
    self.tvWindow.hidden = NO;
    [self.tvWindow bringSubviewToFront:tv.view];

    tv.outputDescription = [NSString stringWithFormat:@"TV output %.0fx%.0f%@", mode.size.width, mode.size.height,
                            px.height < 600 ? @" (SD)" : @""];
    [self.phone setTVAttached:YES];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Back from the lock screen or another app: iOS may have taken the web remote's
    // listening sockets while iBox was suspended.
    [IBRemoteAPI ensureServers];
    [self.bonjour stop];
    [self.bonjour publish];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [UIScreen mainScreen].brightness = 0.5;
}

@end

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([IBAppDelegate class]));
    }
}
