#import "IBTV.h"
#import "IBPlayer.h"
#import "IBServices.h"
#import <QuartzCore/QuartzCore.h>

IBKey IBKeyFromName(NSString *name, BOOL *ok) {
    NSDictionary *map = @{@"up": @(IBKeyUp), @"down": @(IBKeyDown), @"left": @(IBKeyLeft), @"right": @(IBKeyRight),
                          @"select": @(IBKeySelect), @"ok": @(IBKeySelect), @"back": @(IBKeyBack), @"home": @(IBKeyHome),
                          @"playpause": @(IBKeyPlayPause), @"next": @(IBKeyNext), @"prev": @(IBKeyPrev), @"info": @(IBKeyInfo)};
    NSNumber *n = map[[name lowercaseString]];
    if (ok) *ok = n != nil;
    return (IBKey)n.integerValue;
}

/* ================= card view ================= */

@interface IBCardView : UIView
@property (nonatomic, strong) IBItem *item;
@property (nonatomic) IBShape shape;
@property (nonatomic, strong) UIView *art;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *glyphLabel, *titleLabel, *subtitleLabel;
@property (nonatomic, strong) UIView *progressBar;
@property (nonatomic) BOOL hasFocus;
@property (nonatomic) BOOL imageRequested;
@end

@implementation IBCardView

- (instancetype)initWithItem:(IBItem *)item shape:(IBShape)shape frame:(CGRect)frame fontSize:(CGFloat)fs {
    if (!(self = [super initWithFrame:frame])) return nil;
    _item = item;
    _shape = shape;
    CGFloat w = frame.size.width, h = frame.size.height;

    if (shape == IBShapeHeader) {
        _titleLabel = [self label:CGRectMake(0, 0, w, h) size:fs * 1.15 bold:YES];
        _titleLabel.text = item.title;
        _titleLabel.textColor = IBColor(0x9AA4BF);
        return self;
    }

    _art = [[UIView alloc] init];
    _art.backgroundColor = item.color ?: IBColor(0x1D2438);
    _art.layer.cornerRadius = 6;
    _art.layer.masksToBounds = YES;
    _art.layer.borderColor = [UIColor whiteColor].CGColor;
    [self addSubview:_art];

    _imageView = [[UIImageView alloc] init];
    _imageView.contentMode = item.fitImage ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds = YES;
    [_art addSubview:_imageView];

    _glyphLabel = [self label:CGRectZero size:fs * 2 bold:YES];
    _glyphLabel.textAlignment = NSTextAlignmentCenter;
    _glyphLabel.text = item.glyph ?: (item.imageURL ? nil : [self initials:item.title]);
    _glyphLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    [_art addSubview:_glyphLabel];

    if (shape == IBShapeRow) {
        _art.frame = self.bounds;
        CGFloat thumb = item.imageURL || item.glyph ? h : 0;
        _imageView.frame = CGRectMake(0, 0, thumb, h);
        _glyphLabel.frame = _imageView.frame;
        _glyphLabel.font = IBFont(fs * 1.1, YES);
        _art.backgroundColor = IBColor(0x161C2D);
        CGFloat x = thumb + fs * 0.8;
        BOOL sub = item.subtitle.length > 0;
        _titleLabel = [self label:CGRectMake(x, sub ? h * 0.12 : 0, w - x - fs, sub ? h * 0.46 : h) size:fs bold:YES];
        _subtitleLabel = [self label:CGRectMake(x, h * 0.55, w - x - fs, h * 0.36) size:fs * 0.8 bold:NO];
        [_art addSubview:_titleLabel];
        [_art addSubview:_subtitleLabel];
    } else if (shape == IBShapeTile) {
        _art.frame = self.bounds;
        _imageView.frame = self.bounds;
        _glyphLabel.frame = CGRectMake(fs * 0.8, fs * 0.6, w, h * 0.45);
        _glyphLabel.textAlignment = NSTextAlignmentLeft;
        _glyphLabel.font = IBFont(h * 0.3, YES);
        _titleLabel = [self label:CGRectMake(fs * 0.8, h - fs * 3.2, w - fs * 1.6, fs * 1.4) size:fs * 1.15 bold:YES];
        _subtitleLabel = [self label:CGRectMake(fs * 0.8, h - fs * 1.8, w - fs * 1.6, fs * 1.2) size:fs * 0.78 bold:NO];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
        [_art addSubview:_titleLabel];
        [_art addSubview:_subtitleLabel];
    } else {
        CGFloat artH = h - fs * 2.9;
        _art.frame = CGRectMake(0, 0, w, artH);
        _imageView.frame = _art.bounds;
        _glyphLabel.frame = _art.bounds;
        _titleLabel = [self label:CGRectMake(2, artH + fs * 0.3, w - 4, fs * 1.3) size:fs bold:YES];
        _subtitleLabel = [self label:CGRectMake(2, artH + fs * 1.55, w - 4, fs * 1.2) size:fs * 0.78 bold:NO];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        if (item.progress > 0.01) {
            UIView *track = [[UIView alloc] initWithFrame:CGRectMake(0, artH - 5, w, 5)];
            track.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
            [_art addSubview:track];
            _progressBar = [[UIView alloc] initWithFrame:CGRectMake(0, artH - 5, w * MIN(1, item.progress), 5)];
            _progressBar.backgroundColor = IBColor(0x00A4DC);
            [_art addSubview:_progressBar];
        }
    }
    _titleLabel.text = item.title;
    _subtitleLabel.text = item.subtitle;
    if (!_subtitleLabel.textColor || shape != IBShapeTile) _subtitleLabel.textColor = IBColor(0x8C95AD);
    [self setFocused:NO animated:NO];
    return self;
}

- (NSString *)initials:(NSString *)title {
    NSArray *words = [title componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableString *s = [NSMutableString string];
    for (NSString *w in words) {
        if (w.length && s.length < 2) [s appendString:[[w substringToIndex:1] uppercaseString]];
    }
    return s;
}

- (UILabel *)label:(CGRect)frame size:(CGFloat)size bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    l.font = IBFont(size, bold);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:l];
    return l;
}

- (void)loadImageIfNeeded {
    if (self.imageRequested || !self.item.imageURL) return;
    self.imageRequested = YES;
    CGFloat px = MAX(self.imageView.bounds.size.width, self.imageView.bounds.size.height) * 1.1;
    NSString *url = self.item.imageURL;
    __weak IBCardView *weakSelf = self;
    [IBImageLoader load:url maxPixels:px completion:^(UIImage *image) {
        IBCardView *s = weakSelf;
        if (!s || ![s.item.imageURL isEqualToString:url]) return;
        if (image) {
            s.imageView.image = image;
            s.glyphLabel.hidden = s.shape != IBShapeTile;
        } else if (!s.glyphLabel.text) {
            s.glyphLabel.text = [s initials:s.item.title];
        }
    }];
}

- (void)setFocused:(BOOL)focused animated:(BOOL)animated {
    _hasFocus = focused;
    void (^apply)(void) = ^{
        if (self.shape == IBShapeRow) {
            self.art.backgroundColor = focused ? IBColor(0x2F3B5E) : IBColor(0x161C2D);
            self.art.layer.borderWidth = focused ? 2 : 0;
        } else {
            self.transform = focused ? CGAffineTransformMakeScale(1.07, 1.07) : CGAffineTransformIdentity;
            self.art.layer.borderWidth = focused ? 3 : 0;
            self.titleLabel.textColor = focused || self.shape == IBShapeTile ? [UIColor whiteColor] : IBColor(0xC9CFDD);
        }
    };
    if (animated) [UIView animateWithDuration:0.15 animations:apply];
    else apply();
}
@end

/* ================= battery ================= */

// The phone's charge as a small battery glyph + percentage (the box often runs
// unplugged: the TV and the iPhone don't share a power socket).
@interface IBBatteryView : UIView
@property (nonatomic) float level;     // 0...1, < 0 unknown
@property (nonatomic) BOOL charging;
@property (nonatomic, strong) UILabel *label;
@end

@implementation IBBatteryView
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    _label = [[UILabel alloc] init];
    _label.backgroundColor = [UIColor clearColor];
    _label.textColor = IBColor(0xC9D1E6);
    _label.textAlignment = NSTextAlignmentRight;
    [self addSubview:_label];
    return self;
}
- (CGFloat)iconWidth { return roundf(self.bounds.size.height * 1.15); }
- (void)layoutSubviews {
    CGFloat h = self.bounds.size.height, iw = [self iconWidth];
    self.label.font = IBFont(h * 0.72, YES);
    self.label.frame = CGRectMake(0, 0, self.bounds.size.width - iw - h * 0.25, h);
}
- (void)update {
    self.label.text = self.level < 0 ? @"" : [NSString stringWithFormat:@"%d%%", (int)roundf(self.level * 100)];
    self.label.textColor = self.level >= 0 && self.level <= 0.2f && !self.charging ? IBColor(0xFF6B6B) : IBColor(0xC9D1E6);
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGFloat h = self.bounds.size.height, iw = [self iconWidth];
    CGFloat bh = roundf(h * 0.52), bw = iw - roundf(h * 0.12);
    CGRect body = CGRectMake(self.bounds.size.width - iw, roundf((h - bh) / 2), bw, bh);
    CGContextRef c = UIGraphicsGetCurrentContext();
    UIColor *line = IBColor(0xC9D1E6);
    [line setStroke];
    UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(body, 1, 1) cornerRadius:bh * 0.18];
    outline.lineWidth = MAX(1.5f, h * 0.07f);
    [outline stroke];
    [line setFill];
    CGFloat nubH = bh * 0.4;
    CGContextFillRect(c, CGRectMake(CGRectGetMaxX(body), CGRectGetMidY(body) - nubH / 2, roundf(h * 0.1), nubH));
    if (self.level >= 0) {
        CGRect inner = CGRectInset(body, outline.lineWidth + 1.5f, outline.lineWidth + 1.5f);
        inner.size.width = MAX(1, inner.size.width * MIN(1, self.level));
        UIColor *fill = self.charging ? IBColor(0x1ED760) : self.level <= 0.2f ? IBColor(0xFF4D4F)
                      : self.level <= 0.5f ? IBColor(0xF5B83D) : IBColor(0xEEF1F8);
        [fill setFill];
        UIRectFill(inner);
    }
    if (self.charging) {  // lightning bolt
        CGFloat x = CGRectGetMidX(body), y = CGRectGetMidY(body), u = bh * 0.42;
        UIBezierPath *bolt = [UIBezierPath bezierPath];
        [bolt moveToPoint:CGPointMake(x + u * 0.25, y - u)];
        [bolt addLineToPoint:CGPointMake(x - u * 0.45, y + u * 0.12)];
        [bolt addLineToPoint:CGPointMake(x - u * 0.02, y + u * 0.12)];
        [bolt addLineToPoint:CGPointMake(x - u * 0.25, y + u)];
        [bolt addLineToPoint:CGPointMake(x + u * 0.45, y - u * 0.12)];
        [bolt addLineToPoint:CGPointMake(x + u * 0.02, y - u * 0.12)];
        [bolt closePath];
        [[UIColor colorWithWhite:0.05 alpha:1] setStroke];
        bolt.lineWidth = 1.5;
        [bolt stroke];
        [[UIColor whiteColor] setFill];
        [bolt fill];
    }
}
@end

NSDictionary *IBBatteryInfo(void) {
    UIDevice *d = [UIDevice currentDevice];
    if (!d.batteryMonitoringEnabled) d.batteryMonitoringEnabled = YES;
    NSString *state = @"unknown";
    switch (d.batteryState) {
        case UIDeviceBatteryStateUnplugged: state = @"unplugged"; break;
        case UIDeviceBatteryStateCharging: state = @"charging"; break;
        case UIDeviceBatteryStateFull: state = @"full"; break;
        default: break;
    }
    return @{@"level": @(d.batteryLevel < 0 ? -1 : (int)roundf(d.batteryLevel * 100)), @"state": state};
}

/* ================= TV ================= */

@interface IBTV ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) CAGradientLayer *background;
@property (nonatomic, strong) UILabel *logoLabel, *titleLabel, *clockLabel, *hintLabel, *statusLabel, *nowPlayingLabel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray *stack;
@property (nonatomic, strong) NSMutableArray *cards;
@property (nonatomic, strong) IBPlayer *player;
@property (nonatomic, strong) UIView *promptPanel;
@property (nonatomic, strong) UILabel *promptTitle, *promptValue;
@property (nonatomic, copy) void (^promptDone)(NSString *);
@property (nonatomic, strong) NSDictionary *textPrompt;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, copy) BOOL (^overlayKeys)(IBKey);
@property (nonatomic, copy) void (^overlayClose)(void);
@property (nonatomic) CGSize size;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) NSInteger busyCount;
@property (nonatomic, copy) NSString *lastToast;
@property (nonatomic, strong) NSDate *lastToastDate;
@property (nonatomic, strong) IBBatteryView *battery;
@property (nonatomic, strong) UIView *saver;              // screensaver (protects old TVs from burn-in)
@property (nonatomic, strong) UIWindow *chromeWindow;
@property (nonatomic, strong) UIView *chromeRoot;
@property (nonatomic, strong) UILabel *saverClock, *saverLine;
@property (nonatomic, strong) NSTimer *saverTimer;
@property (nonatomic, strong) NSDate *lastActivity;
@property (nonatomic) int batteryWarned;  // lowest threshold already announced
@end

@implementation IBTV

+ (instancetype)shared {
    static IBTV *tv;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tv = [IBTV new]; });
    return tv;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _stack = [NSMutableArray array];
    _cards = [NSMutableArray array];
    _view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1280, 720)];
    _view.backgroundColor = IBColor(0x0B0F1A);
    _view.clipsToBounds = YES;
    _background = [CAGradientLayer layer];
    _background.colors = @[(id)IBColor(0x141B2E).CGColor, (id)IBColor(0x080B13).CGColor];
    [_view.layer addSublayer:_background];

    _logoLabel = [self label:YES];
    _logoLabel.text = @"iBox";
    _titleLabel = [self label:NO];
    _titleLabel.textColor = IBColor(0xAAB3CC);
    _clockLabel = [self label:YES];
    _clockLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel = [self label:NO];
    _statusLabel.textAlignment = NSTextAlignmentRight;
    _statusLabel.textColor = IBColor(0x8C95AD);
    _nowPlayingLabel = [self label:NO];
    _nowPlayingLabel.textColor = IBColor(0x1ED760);
    _hintLabel = [self label:NO];
    _hintLabel.textColor = IBColor(0x5D6680);

    _scroll = [[UIScrollView alloc] init];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.clipsToBounds = YES;
    [_view addSubview:_scroll];

    _emptyLabel = [self label:NO];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textColor = IBColor(0x8C95AD);

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [_view addSubview:_spinner];

    _battery = [[IBBatteryView alloc] init];
    [_view addSubview:_battery];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    _batteryWarned = 101;
    _lastActivity = [NSDate date];
    for (NSString *n in @[UIDeviceBatteryLevelDidChangeNotification, UIDeviceBatteryStateDidChangeNotification]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryChanged) name:n object:nil];
    }

    _player = [[IBPlayer alloc] init];

    [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self layoutForSize:_view.bounds.size];
    return self;
}

- (UILabel *)label:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    l.font = IBFont(20, bold);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:l];
    return l;
}

- (CGFloat)margin { return roundf(self.size.width * 0.05); }
- (CGFloat)headerHeight { return roundf(self.size.height * 0.15); }

- (void)layoutForSize:(CGSize)size {
    self.size = size;
    self.view.bounds = CGRectMake(0, 0, size.width, size.height);
    self.fontSize = MAX(15, roundf(size.height * 0.029));
    CGFloat fs = self.fontSize, m = [self margin], hh = [self headerHeight];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.background.frame = self.view.bounds;
    [CATransaction commit];

    CGFloat top = roundf(size.height * 0.05);
    self.logoLabel.font = IBFont(fs * 1.7, YES);
    self.logoLabel.frame = CGRectMake(m, top, fs * 4.2, fs * 2);
    self.titleLabel.font = IBFont(fs * 1.25, NO);
    self.titleLabel.frame = CGRectMake(m + fs * 4.4, top + fs * 0.35, size.width * 0.45, fs * 1.6);
    self.clockLabel.font = IBFont(fs * 1.5, YES);
    self.clockLabel.frame = CGRectMake(size.width - m - fs * 12, top - fs * 0.1, fs * 12, fs * 1.8);
    self.battery.frame = CGRectMake(0, top + fs * 0.05, fs * 5.2, fs * 1.5);  // x set in batteryChanged (left of the clock text)
    self.statusLabel.font = IBFont(fs * 0.78, NO);
    self.statusLabel.frame = CGRectMake(size.width * 0.4, top + fs * 1.75, size.width * 0.6 - m, fs * 1.2);
    self.nowPlayingLabel.font = IBFont(fs * 0.8, YES);
    self.nowPlayingLabel.frame = CGRectMake(m, top + fs * 2.1, size.width * 0.5, fs * 1.2);
    self.hintLabel.font = IBFont(fs * 0.72, NO);
    self.hintLabel.frame = CGRectMake(m, size.height - roundf(size.height * 0.045) - fs, size.width - 2 * m, fs * 1.1);
    self.hintLabel.text = @"↑ ↓ ← →  move   •   OK  select   •   Back   •   Home";
    self.scroll.frame = CGRectMake(0, hh, size.width, size.height - hh - roundf(size.height * 0.09));
    self.emptyLabel.font = IBFont(fs * 1.1, NO);
    self.emptyLabel.frame = CGRectMake(m, size.height * 0.35, size.width - 2 * m, size.height * 0.3);
    self.spinner.center = CGPointMake(size.width / 2, size.height / 2);
    [self.player layoutInView:self.view];
    if (self.overlay) self.overlay.frame = self.view.bounds;
    [self layoutPrompt];
    [self tick];
    if (self.stack.count) [self renderTop];
}

- (void)tick {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm";
    f.timeZone = [IBServices timeZone];
    NSString *weather = [IBServices weatherSummary];
    self.clockLabel.text = weather.length ? [NSString stringWithFormat:@"%@   %@", weather, [f stringFromDate:[NSDate date]]]
                                          : [f stringFromDate:[NSDate date]];
    [self batteryChanged];
    [self checkSaver];
    self.statusLabel.text = [NSString stringWithFormat:@"Remote: http://%@:8080   •   %@", IBLocalIPAddress(),
                             self.outputDescription ?: @"Preview"];
    IBMedia *now = self.player.currentMedia;
    self.nowPlayingLabel.text = now && self.player.isPlaying ? [NSString stringWithFormat:@"♪ %@", now.title] : nil;
}

/* ---------------- chrome (above iOS's own TV-out window) ---------------- */

- (UIView *)chrome {
    UIWindow *tvWindow = self.view.window;
    if (!tvWindow || tvWindow.screen == [UIScreen mainScreen]) return self.view;
    if (!self.chromeWindow || self.chromeWindow.screen != tvWindow.screen) {
        self.chromeWindow.hidden = YES;
        UIWindow *w = [[UIWindow alloc] initWithFrame:tvWindow.screen.bounds];
        w.screen = tvWindow.screen;
        w.frame = tvWindow.frame;
        w.windowLevel = UIWindowLevelStatusBar + 50;  // MPTVOutWindow (web video on the TV) sits at the normal level
        w.backgroundColor = [UIColor clearColor];
        w.opaque = NO;
        w.userInteractionEnabled = NO;
        UIView *root = [[UIView alloc] initWithFrame:w.bounds];
        root.backgroundColor = [UIColor clearColor];
        root.userInteractionEnabled = NO;
        [w addSubview:root];
        w.hidden = NO;
        self.chromeWindow = w;
        self.chromeRoot = root;
    }
    self.chromeRoot.frame = [self.view convertRect:self.view.bounds toView:nil];
    return self.chromeRoot;
}

/* ---------------- screensaver ---------------- */

// After a few idle minutes on menus or the music screen (never over a playing video),
// the TV goes black with a dim clock that moves every few seconds: an old TV's tube or
// panel doesn't keep the shape of iBox's menus.
- (NSTimeInterval)saverDelay {
    NSString *v = [IBSettings get:@"screensaver"];
    return (v ? [v doubleValue] : 5) * 60;
}

- (BOOL)saverAllowed {
    if (self.overlay || self.textPrompt) return NO;  // YouTube, screen share, typing
    IBMedia *m = self.player.currentMedia;
    return !(m && !m.audioOnly && self.player.visible);
}

- (void)checkSaver {
    if (self.saver) {
        if (![self saverAllowed]) [self hideSaver];
        return;
    }
    NSTimeInterval delay = [self saverDelay];
    if (delay > 0 && [self.lastActivity timeIntervalSinceNow] < -delay && [self saverAllowed]) [self showSaver];
}

- (void)noteActivity {
    self.lastActivity = [NSDate date];
    if (self.saver) [self hideSaver];
}

- (void)showSaver {
    UIView *v = [[UIView alloc] initWithFrame:self.view.bounds];
    v.backgroundColor = [UIColor blackColor];
    v.alpha = 0;
    CGFloat fs = self.fontSize;
    self.saverClock = [[UILabel alloc] init];
    self.saverClock.font = IBFont(fs * 3.4, YES);
    self.saverLine = [[UILabel alloc] init];
    self.saverLine.font = IBFont(fs * 0.95, NO);
    for (UILabel *l in @[self.saverClock, self.saverLine]) {
        l.backgroundColor = [UIColor clearColor];
        l.textColor = [UIColor colorWithWhite:0.55 alpha:1];  // dim: it is there to be ignored
        l.textAlignment = NSTextAlignmentCenter;
        [v addSubview:l];
    }
    [self.view addSubview:v];
    self.saver = v;
    [self moveSaver];
    [UIView animateWithDuration:1.5 animations:^{ v.alpha = 1; }];
    self.saverTimer = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(moveSaver) userInfo:nil repeats:YES];
}

- (void)moveSaver {
    if (!self.saver) return;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm";
    f.timeZone = [IBServices timeZone];
    self.saverClock.text = [f stringFromDate:[NSDate date]];
    IBMedia *m = self.player.currentMedia;
    NSString *weather = [IBServices weatherSummary];
    NSMutableArray *parts = [NSMutableArray array];
    if (weather.length) [parts addObject:weather];
    if (m && self.player.isPlaying) [parts addObject:[NSString stringWithFormat:@"\u266A %@", m.title]];
    [parts addObject:@"Press any key"];
    self.saverLine.text = [parts componentsJoinedByString:@"   \u2022   "];
    CGFloat fs = self.fontSize, w = MIN(self.size.width * 0.8, fs * 28), h = fs * 6;
    CGFloat x = arc4random_uniform((uint32_t)MAX(1, self.size.width - w)), y = arc4random_uniform((uint32_t)MAX(1, self.size.height - h));
    UILabel *clock = self.saverClock, *line = self.saverLine;
    [UIView animateWithDuration:0.8 animations:^{ clock.alpha = 0; line.alpha = 0; } completion:^(BOOL done) {
        clock.frame = CGRectMake(x, y, w, fs * 4);
        line.frame = CGRectMake(x, y + fs * 4.2, w, fs * 1.4);
        [UIView animateWithDuration:0.8 animations:^{ clock.alpha = 1; line.alpha = 1; }];
    }];
}

- (void)hideSaver {
    [self.saverTimer invalidate];
    self.saverTimer = nil;
    UIView *v = self.saver;
    self.saver = nil;
    [UIView animateWithDuration:0.3 animations:^{ v.alpha = 0; } completion:^(BOOL done) { [v removeFromSuperview]; }];
}

- (void)batteryChanged {
    UIDevice *d = [UIDevice currentDevice];
    BOOL charging = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    self.battery.level = d.batteryLevel;
    self.battery.charging = charging;
    [self.battery update];
    CGFloat textW = [self.clockLabel.text ?: @"" sizeWithFont:self.clockLabel.font].width;
    CGRect b = self.battery.frame;
    b.origin.x = CGRectGetMaxX(self.clockLabel.frame) - MIN(textW, self.clockLabel.frame.size.width) - b.size.width - self.fontSize * 0.9;
    self.battery.frame = b;
    if (d.batteryLevel < 0) return;
    int pct = (int)roundf(d.batteryLevel * 100);
    if (charging) {
        self.batteryWarned = 101;
        return;
    }
    for (NSNumber *n in @[@5, @10, @20]) {
        int t = n.intValue;
        if (pct <= t && self.batteryWarned > t) {
            self.batteryWarned = t;
            [self toast:[NSString stringWithFormat:@"Battery low: %d%% \u2014 plug the iPhone in (the AV adapter has a charging port)", pct]];
            break;
        }
    }
}

/* ---------------- navigation ---------------- */

- (void)showHome {
    [self.stack removeAllObjects];
    [self pushPage:[IBServices homePage]];
}

- (void)resetUI {
    [self cancelPrompt];
    [self dismissOverlay];
    [self.player stop];
    [IBYouTube hardStop];
    [self showHome];
    [self toast:@"iBox reset"];
}

- (void)pushPage:(IBPage *)page {
    if (!page) return;
    IBPage *top = self.stack.lastObject;
    if (top) top.focusIndex = [self focusedIndex];
    [self.stack addObject:page];
    if (!page.items && page.loader) [self loadPage:page];
    [self renderTop];
}

- (void)popPage {
    if (self.stack.count <= 1) return;
    [self.stack removeLastObject];
    IBPage *top = self.stack.lastObject;
    if (top.reloadOnShow && top.loader) [self loadPage:top];
    [self renderTop];
}

- (void)reloadTopPage {
    IBPage *top = self.stack.lastObject;
    top.focusIndex = [self focusedIndex];
    if (top.loader) [self loadPage:top];
    else [self renderTop];
}

- (BOOL)hasPage:(IBPage *)page {
    return [self.stack indexOfObjectIdenticalTo:page] != NSNotFound;
}

- (void)refreshTitle:(IBPage *)page {
    if (self.stack.lastObject == page && self.stack.count > 1) self.titleLabel.text = page.title;
}

- (void)replaceItems:(NSArray *)items ofPage:(IBPage *)page {
    BOOL onTop = self.stack.lastObject == page;
    NSInteger oldIndex = onTop ? [self focusedIndex] : page.focusIndex;
    IBItem *focused = oldIndex >= 0 && oldIndex < (NSInteger)page.items.count ? page.items[oldIndex] : nil;
    page.items = items;
    NSUInteger found = focused ? [items indexOfObjectIdenticalTo:focused] : NSNotFound;
    page.focusIndex = found != NSNotFound ? (NSInteger)found : MIN(MAX(oldIndex, 0), (NSInteger)items.count - 1);
    if (!onTop) return;
    // Re-render in place: restore the scroll position, then only nudge it if focus left the view.
    CGPoint offset = self.scroll.contentOffset;
    NSInteger focus = page.focusIndex;
    [self renderTop];
    CGFloat maxY = MAX(0, self.scroll.contentSize.height - self.scroll.bounds.size.height);
    [self.scroll setContentOffset:CGPointMake(0, MIN(offset.y, maxY)) animated:NO];
    if (focus >= 0 && focus < (NSInteger)self.cards.count && [self.cards[focus] shape] != IBShapeHeader) {
        [self focus:focus animated:NO];
    }
}

- (void)loadPage:(IBPage *)page {
    [self setBusy:YES];
    __weak IBTV *weakSelf = self;
    page.loader(page, ^(NSArray *items, NSString *error) {
        IBTV *s = weakSelf;
        [s setBusy:NO];
        page.items = items ?: @[];
        if (error) {
            page.emptyText = error;
            [s toast:error];
        }
        if (s.stack.lastObject == page) [s renderTop];
    });
}

- (NSInteger)focusedIndex {
    for (NSUInteger i = 0; i < self.cards.count; i++) {
        if ([(IBCardView *)self.cards[i] hasFocus]) return (NSInteger)i;
    }
    return 0;
}

- (CGSize)cardSize:(IBShape)shape width:(CGFloat)contentW {
    CGFloat fs = self.fontSize, gap = fs * 1.2;
    BOOL narrow = self.size.width < 900;
    int cols;
    CGFloat w, h;
    switch (shape) {
        case IBShapeTile:   cols = narrow ? 3 : 4; w = (contentW - gap * (cols - 1)) / cols; h = w * 0.62; break;
        case IBShapeWide:   cols = narrow ? 3 : 4; w = (contentW - gap * (cols - 1)) / cols; h = w * 9 / 16 + fs * 2.9; break;
        case IBShapePoster: cols = narrow ? 4 : 6; w = (contentW - gap * (cols - 1)) / cols; h = w * 1.5 + fs * 2.9; break;
        case IBShapeSquare: cols = narrow ? 4 : 5; w = (contentW - gap * (cols - 1)) / cols; h = w + fs * 2.9; break;
        case IBShapeRow:    w = contentW; h = fs * 3.2; break;
        case IBShapeHeader: w = contentW; h = fs * 2.0; break;
    }
    return CGSizeMake(floorf(w), floorf(h));
}

- (void)renderTop {
    for (UIView *v in self.cards) [v removeFromSuperview];
    [self.cards removeAllObjects];
    IBPage *page = self.stack.lastObject;
    self.titleLabel.text = self.stack.count > 1 ? page.title : nil;

    CGFloat m = [self margin], fs = self.fontSize, gap = fs * 1.2;
    CGFloat contentW = self.size.width - 2 * m;
    CGFloat x = m, y = fs * 0.6, rowH = 0;
    NSInteger index = 0;
    for (IBItem *item in page.items) {
        IBShape shape = item.hasShape ? item.shape : page.shape;
        CGSize cs = [self cardSize:shape width:contentW];
        BOOL fullRow = shape == IBShapeRow || shape == IBShapeHeader;
        if (x > m && (fullRow || x + cs.width > m + contentW + 1)) {
            x = m;
            y += rowH + (shape == IBShapeRow ? fs * 0.45 : gap);
            rowH = 0;
        }
        if (shape == IBShapeHeader && index > 0) y += fs * 0.6;
        IBCardView *card = [[IBCardView alloc] initWithItem:item shape:shape
                                                      frame:CGRectMake(x, y, cs.width, cs.height) fontSize:fs];
        [self.scroll addSubview:card];
        [self.cards addObject:card];
        rowH = MAX(rowH, cs.height);
        x += cs.width + gap;
        if (fullRow) {
            x = m + contentW + 1;  // force a new row next
        }
        index++;
    }
    self.scroll.contentSize = CGSizeMake(self.size.width, y + rowH + fs * 2);
    self.emptyLabel.text = page.items && page.items.count == 0 ? (page.emptyText ?: @"Nothing here yet.") : nil;

    NSInteger focus = MIN(MAX(page.focusIndex, 0), (NSInteger)self.cards.count - 1);
    if (focus >= 0 && [self.cards[focus] shape] == IBShapeHeader) focus = [self nextFocusable:focus];
    [self.scroll setContentOffset:CGPointZero animated:NO];
    if (focus >= 0 && focus < (NSInteger)self.cards.count) [self focus:focus animated:NO];
    [self loadVisibleImages];
}

- (NSInteger)nextFocusable:(NSInteger)from {
    for (NSInteger i = from; i < (NSInteger)self.cards.count; i++) {
        if ([self.cards[i] shape] != IBShapeHeader) return i;
    }
    return -1;
}

- (void)focus:(NSInteger)index animated:(BOOL)animated {
    for (IBCardView *c in self.cards) {
        if (c.hasFocus) [c setFocused:NO animated:animated];
    }
    IBCardView *card = self.cards[index];
    [card setFocused:YES animated:animated];
    [card.superview bringSubviewToFront:card];
    ((IBPage *)self.stack.lastObject).focusIndex = index;

    // Keep the focused card (and a bit of the next row) visible.
    CGRect f = card.frame;
    CGFloat viewH = self.scroll.bounds.size.height, pad = self.fontSize * 1.5;
    CGFloat offset = self.scroll.contentOffset.y;
    if (CGRectGetMaxY(f) + pad > offset + viewH) offset = CGRectGetMaxY(f) + pad - viewH;
    if (f.origin.y - pad < offset) offset = MAX(0, f.origin.y - pad - (index > 0 ? self.fontSize * 2 : 0));
    if (index <= 1) offset = 0;
    if (offset != self.scroll.contentOffset.y) {
        [self.scroll setContentOffset:CGPointMake(0, offset) animated:animated];
    }
    [self performSelector:@selector(loadVisibleImages) withObject:nil afterDelay:0.3];
}

- (void)loadVisibleImages {
    CGRect visible = CGRectInset(self.scroll.bounds, 0, -self.scroll.bounds.size.height * 0.6);
    for (IBCardView *c in self.cards) {
        if (CGRectIntersectsRect(visible, c.frame)) [c loadImageIfNeeded];
    }
}

- (void)moveFocus:(IBKey)key {
    if (self.cards.count == 0) return;
    NSInteger cur = [self focusedIndex];
    CGRect from = [self.cards[cur] frame];
    CGPoint c = CGPointMake(CGRectGetMidX(from), CGRectGetMidY(from));
    NSInteger best = -1;
    CGFloat bestScore = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)self.cards.count; i++) {
        IBCardView *card = self.cards[i];
        if (i == cur || card.shape == IBShapeHeader) continue;
        CGRect f = card.frame;
        CGPoint p = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        // Horizontal gap between the two cards (0 when they overlap), then centre distance as a tie-break.
        // Leaving a full-width row lands on the leftmost card, like reading order.
        CGFloat tie = from.size.width > self.size.width * 0.5 ? f.origin.x : fabsf(p.x - c.x);
        CGFloat gapX = MAX(0, MAX(f.origin.x - CGRectGetMaxX(from), from.origin.x - CGRectGetMaxX(f))) * 4 + tie * 0.01;
        CGFloat primary, secondary;
        switch (key) {
            case IBKeyUp:    if (CGRectGetMaxY(f) > from.origin.y + 1) continue; primary = c.y - p.y; secondary = gapX; break;
            case IBKeyDown:  if (f.origin.y < CGRectGetMaxY(from) - 1) continue; primary = p.y - c.y; secondary = gapX; break;
            case IBKeyLeft:  if (fabsf(p.y - c.y) > from.size.height / 2 || p.x >= c.x) continue; primary = c.x - p.x; secondary = 0; break;
            case IBKeyRight: if (fabsf(p.y - c.y) > from.size.height / 2 || p.x <= c.x) continue; primary = p.x - c.x; secondary = 0; break;
            default: continue;
        }
        CGFloat score = primary + secondary * 2;
        if (score < bestScore) {
            bestScore = score;
            best = i;
        }
    }
    // Wrap left/right across rows like a list.
    if (best < 0 && key == IBKeyRight) best = [self nextFocusable:cur + 1];
    if (best < 0 && key == IBKeyLeft) {
        for (NSInteger i = cur - 1; i >= 0; i--) {
            if ([self.cards[i] shape] != IBShapeHeader) { best = i; break; }
        }
    }
    if (best >= 0) [self focus:best animated:YES];
}

- (void)handleKey:(IBKey)key {
    BOOL wasSaving = self.saver != nil;
    [self noteActivity];
    if (wasSaving) return;  // the key only wakes the TV up
    if (self.textPrompt) {
        if (key == IBKeyBack) [self cancelPrompt];
        else if (key == IBKeySelect) [self submitPrompt:self.textPrompt[@"value"]];
        return;
    }
    if (self.overlay) {
        if (self.overlayKeys && self.overlayKeys(key)) return;
        if (key == IBKeyBack || key == IBKeyHome) [self dismissOverlay];
        if (key != IBKeyHome) return;
    }
    if ([self.player handleKey:key]) return;

    switch (key) {
        case IBKeyUp: case IBKeyDown: case IBKeyLeft: case IBKeyRight:
            [self moveFocus:key];
            break;
        case IBKeySelect: {
            if (self.cards.count == 0) break;
            IBCardView *card = self.cards[[self focusedIndex]];
            if (card.item.action) {
                [UIView animateWithDuration:0.08 animations:^{ card.alpha = 0.6; }
                                 completion:^(BOOL f) { card.alpha = 1; }];
                card.item.action();
            }
            break;
        }
        case IBKeyBack: [self popPage]; break;
        case IBKeyHome:
            if (self.stack.count > 1) [self showHome];
            break;
        case IBKeyInfo: [self toast:[NSString stringWithFormat:@"iBox at %@ — %@", IBLocalIPAddress(), self.outputDescription ?: @""]]; break;
        default: break;
    }
}

/* ---------------- feedback ---------------- */

- (void)setBusy:(BOOL)busy {
    self.busyCount = MAX(0, self.busyCount + (busy ? 1 : -1));
    if (self.busyCount > 0) {
        [self.view bringSubviewToFront:self.spinner];
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)toast:(NSString *)message {
    if (message.length == 0) return;
    NSLog(@"iBox: %@", message);
    self.lastToast = message;
    self.lastToastDate = [NSDate date];
    CGFloat fs = self.fontSize, maxW = self.size.width * 0.7;
    UILabel *l = [[UILabel alloc] init];
    l.font = IBFont(fs, NO);
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor clearColor];
    l.numberOfLines = 3;
    l.textAlignment = NSTextAlignmentCenter;
    l.text = message;
    CGSize ts = [message sizeWithFont:l.font constrainedToSize:CGSizeMake(maxW, fs * 5) lineBreakMode:NSLineBreakByWordWrapping];
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, ts.width + fs * 2, ts.height + fs * 1.2)];
    box.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    box.layer.cornerRadius = 8;
    box.layer.borderColor = IBColor(0x3A4566).CGColor;
    box.layer.borderWidth = 1;
    l.frame = CGRectInset(box.bounds, fs, fs * 0.6);
    [box addSubview:l];
    box.center = CGPointMake(self.size.width / 2, self.size.height * 0.84);
    UIView *host = [self chrome];  // above YouTube's video too
    box.alpha = 0;
    [host addSubview:box];
    [UIView animateWithDuration:0.2 animations:^{ box.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.4 delay:3.2 options:0 animations:^{ box.alpha = 0; }
                         completion:^(BOOL f2) { [box removeFromSuperview]; }];
    }];
}

/* ---------------- text prompt ---------------- */

- (void)promptText:(NSString *)title initial:(NSString *)initial secure:(BOOL)secure done:(void (^)(NSString *))done {
    self.promptDone = done;
    self.textPrompt = @{@"title": title ?: @"", @"value": initial ?: @"", @"secure": @(secure)};
    if (!self.promptPanel) {
        self.promptPanel = [[UIView alloc] init];
        self.promptPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        UIView *box = [[UIView alloc] init];
        box.tag = 1;
        box.backgroundColor = IBColor(0x1A2133);
        box.layer.cornerRadius = 10;
        box.layer.borderColor = IBColor(0x00A4DC).CGColor;
        box.layer.borderWidth = 2;
        [self.promptPanel addSubview:box];
        self.promptTitle = [[UILabel alloc] init];
        self.promptValue = [[UILabel alloc] init];
        self.promptValue.lineBreakMode = NSLineBreakByTruncatingHead;  // keep the caret end visible
        UILabel *hint = [[UILabel alloc] init];
        hint.tag = 2;
        hint.numberOfLines = 2;
        for (UILabel *l in @[self.promptTitle, self.promptValue, hint]) {
            l.backgroundColor = [UIColor clearColor];
            l.textColor = [UIColor whiteColor];
            [box addSubview:l];
        }
        hint.textColor = IBColor(0x8C95AD);
    }
    self.promptTitle.text = title;
    [self updatePromptText:initial];
    [self layoutPrompt];
    [self.view addSubview:self.promptPanel];
}

- (void)layoutPrompt {
    if (!self.promptPanel) return;
    CGFloat fs = self.fontSize, w = self.size.width * 0.7;
    self.promptPanel.frame = self.view.bounds;
    UIView *box = [self.promptPanel viewWithTag:1];
    box.frame = CGRectMake((self.size.width - w) / 2, self.size.height * 0.3, w, fs * 9);
    self.promptTitle.font = IBFont(fs * 1.2, YES);
    self.promptTitle.frame = CGRectMake(fs * 1.2, fs, w - fs * 2.4, fs * 1.6);
    self.promptValue.font = IBFont(fs * 1.5, NO);
    self.promptValue.frame = CGRectMake(fs * 1.2, fs * 3, w - fs * 2.4, fs * 2.2);
    UILabel *hint = (UILabel *)[box viewWithTag:2];
    hint.font = IBFont(fs * 0.8, NO);
    hint.frame = CGRectMake(fs * 1.2, fs * 5.6, w - fs * 2.4, fs * 2.6);
    hint.text = [NSString stringWithFormat:@"Type on the iPhone screen or at http://%@:8080 — OK to confirm, Back to cancel",
                 IBLocalIPAddress()];
}

- (void)updatePromptText:(NSString *)text {
    if (!self.textPrompt) return;
    NSMutableDictionary *p = [self.textPrompt mutableCopy];
    p[@"value"] = text ?: @"";
    self.textPrompt = p;
    NSString *shown = [p[@"secure"] boolValue] ? [@"" stringByPaddingToLength:[text length] withString:@"•" startingAtIndex:0] : text;
    self.promptValue.text = [NSString stringWithFormat:@"%@▏", shown ?: @""];
}

- (void)submitPrompt:(NSString *)text {
    void (^done)(NSString *) = self.promptDone;
    [self cancelPrompt];
    if (done) done(text ?: @"");
}

- (void)cancelPrompt {
    self.textPrompt = nil;
    self.promptDone = nil;
    [self.promptPanel removeFromSuperview];
}

/* ---------------- overlays & playback ---------------- */

- (void)showOverlay:(UIView *)view keys:(BOOL (^)(IBKey))handler onClose:(void (^)(void))onClose {
    [self dismissOverlay];
    self.overlay = view;
    self.overlayKeys = handler;
    self.overlayClose = onClose;
    view.frame = self.view.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:view];
    if (self.promptPanel.superview) [self.view bringSubviewToFront:self.promptPanel];
}

- (void)dismissOverlay {
    if (!self.overlay) return;
    void (^close)(void) = self.overlayClose;
    UIView *view = self.overlay;
    self.overlay = nil;
    self.overlayKeys = nil;
    self.overlayClose = nil;
    // Let the overlay stop its media while still on screen: pulling a playing web
    // video out of the window first is slow and hard on iOS 6's media daemon.
    if (close) close();
    [view removeFromSuperview];
}

- (void)playQueue:(NSArray *)media index:(NSInteger)index {
    if (media.count == 0) return;
    [self dismissOverlay];
    [self.player playQueue:media index:index inView:self.view];
}

- (void)playMedia:(IBMedia *)media {
    if (media) [self playQueue:@[media] index:0];
}

- (void)playerVisibilityChanged {
    [self tick];
    if (self.promptPanel.superview) [self.view bringSubviewToFront:self.promptPanel];
}

- (NSDictionary *)stateSnapshot {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    IBPage *top = self.stack.lastObject;
    s[@"page"] = top.title ?: @"Home";
    s[@"depth"] = @(self.stack.count);
    NSInteger fi = [self focusedIndex];
    if (fi < (NSInteger)self.cards.count) s[@"focused"] = ((IBCardView *)self.cards[fi]).item.title ?: @"";
    if (self.textPrompt) {
        NSMutableDictionary *p = [self.textPrompt mutableCopy];
        if ([p[@"secure"] boolValue]) p[@"value"] = @"";
        s[@"prompt"] = p;
    }
    s[@"overlay"] = @(self.overlay != nil);
    if (self.lastToast && [self.lastToastDate timeIntervalSinceNow] > -6) s[@"toast"] = self.lastToast;
    s[@"output"] = self.outputDescription ?: @"Preview";
    s[@"battery"] = IBBatteryInfo();
    s[@"screensaver"] = @(self.saver != nil);
    static NSNumber *build;  // changes with every install: the web remote reloads itself
    if (!build) {
        NSDate *d = [[NSFileManager defaultManager] attributesOfItemAtPath:[NSBundle mainBundle].executablePath error:NULL].fileModificationDate;
        build = @((long long)[d timeIntervalSince1970]);
    }
    s[@"build"] = build;
    UIScreen *screen = self.view.window.screen;
    if (screen) {  // where the TV interface really sits (diagnoses borders / shifts)
        NSMutableArray *stack = [NSMutableArray array];  // window subviews, back to front
        for (UIView *v in self.view.window.subviews) {
            [stack addObject:[NSString stringWithFormat:@"%@%@%@", v == self.view ? @"TV" : NSStringFromClass([v class]),
                              v.hidden ? @"(hidden)" : @"", v.opaque && v.backgroundColor && v != self.view ? @"(opaque)" : @""]];
        }
        s[@"geometry"] = [NSString stringWithFormat:@"view %@ in screen %@ (applicationFrame %@), window stack: %@",
                          NSStringFromCGRect([self.view convertRect:self.view.bounds toView:nil]),
                          NSStringFromCGRect(screen.bounds), NSStringFromCGRect(screen.applicationFrame),
                          [stack componentsJoinedByString:@" < "]];
    }
    s[@"ip"] = IBLocalIPAddress();
    NSDictionary *ps = [self.player state] ?: [IBYouTube playerState];
    if (ps) s[@"player"] = ps;
    return s;
}

@end
