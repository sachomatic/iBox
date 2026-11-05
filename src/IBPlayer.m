#import "IBPlayer.h"
#import "IBServices.h"
#import "IBOptions.h"
#import "IBRemoteAPI.h"
#import "IBHTTP.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static void *kItemStatusContext = &kItemStatusContext;

@interface IBPlayerSurface : UIView
@end
@implementation IBPlayerSurface
+ (Class)layerClass { return [AVPlayerLayer class]; }
@end

@interface IBPlayer ()
@property (nonatomic, strong) AVPlayer *avPlayer;
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSMutableArray *mutableQueue;
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, readwrite) BOOL visible;
@property (nonatomic) BOOL userPaused;
@property (nonatomic) NSInteger generation;
@property (nonatomic) NSTimeInterval lastReport;
@property (nonatomic) NSTimeInterval noPictureSince;  // playback position when we first saw sound without picture


@property (nonatomic, strong) UIView *root;
@property (nonatomic, strong) IBPlayerSurface *surface;
@property (nonatomic, strong) UIImageView *backdrop, *artwork;
@property (nonatomic, strong) UIView *osd, *barTrack, *barFill;
@property (nonatomic, strong) CAGradientLayer *osdGradient;
@property (nonatomic, strong) UILabel *titleLabel, *subtitleLabel, *timeLabel, *noteLabel, *stateLabel, *hintLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSTimer *osdTimer;

@property (nonatomic, copy) NSString *resolvedURL;        // the source URL AVPlayer is playing (before the proxy)
@property (nonatomic, copy) NSString *playableURL;        // what AVPlayer really opened
@property (nonatomic) BOOL restarting;                    // restartCurrent: keep the options panel open
@property (nonatomic, strong) IBOptionsPanel *optionsPanel;
@property (nonatomic, strong) IBSubtitleView *captionView;
@property (nonatomic, strong) IBSubtitleTrack *captions;
@property (nonatomic, copy) NSString *captionsLoaded;     // URL of `captions`
@property (nonatomic, strong) NSTimer *captionTimer;
@end

@implementation IBPlayer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _mutableQueue = [NSMutableArray array];
    _avPlayer = [[AVPlayer alloc] init];
    _avPlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause;

    _root = [[UIView alloc] init];
    _root.backgroundColor = [UIColor blackColor];
    _root.clipsToBounds = YES;

    _backdrop = [[UIImageView alloc] init];
    _backdrop.contentMode = UIViewContentModeScaleAspectFill;
    _backdrop.alpha = 0.25;
    [_root addSubview:_backdrop];

    _surface = [[IBPlayerSurface alloc] init];
    ((AVPlayerLayer *)_surface.layer).player = _avPlayer;
    ((AVPlayerLayer *)_surface.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [_root addSubview:_surface];

    _artwork = [[UIImageView alloc] init];
    _artwork.contentMode = UIViewContentModeScaleAspectFill;
    _artwork.clipsToBounds = YES;
    _artwork.layer.cornerRadius = 8;
    _artwork.backgroundColor = IBColor(0x1D2438);
    [_root addSubview:_artwork];

    _osd = [[UIView alloc] init];
    _osdGradient = [CAGradientLayer layer];
    _osdGradient.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.85].CGColor];
    [_osd.layer addSublayer:_osdGradient];
    [_root addSubview:_osd];
    _captionView = [[IBSubtitleView alloc] init];
    [_root insertSubview:_captionView belowSubview:_osd];

    _titleLabel = [self label:YES];
    _subtitleLabel = [self label:NO];
    _subtitleLabel.textColor = IBColor(0xB8C0D6);
    _timeLabel = [self label:NO];
    _timeLabel.textAlignment = NSTextAlignmentRight;
    _noteLabel = [self label:NO];
    _noteLabel.textColor = IBColor(0xF5C451);
    _stateLabel = [self label:YES];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel = [self label:NO];
    _hintLabel.textColor = IBColor(0x8C95AD);
    _hintLabel.text = @"\u2193  Options (audio, subtitles, quality)     OK  Pause     \u2190 \u2192  Seek";

    _barTrack = [[UIView alloc] init];
    _barTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    [_osd addSubview:_barTrack];
    _barFill = [[UIView alloc] init];
    _barFill.backgroundColor = IBColor(0x00A4DC);
    [_barTrack addSubview:_barFill];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [_root addSubview:_spinner];

    __weak IBPlayer *weakSelf = self;
    _timeObserver = [_avPlayer addPeriodicTimeObserverForInterval:CMTimeMake(1, 2) queue:dispatch_get_main_queue()
                                                       usingBlock:^(CMTime t) { [weakSelf tick]; }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemEnded:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemStalled:)
                                                 name:AVPlayerItemPlaybackStalledNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    return self;
}

- (UILabel *)label:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    l.font = IBFont(20, bold);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.osd addSubview:l];
    return l;
}

- (NSArray *)queue { return self.mutableQueue; }
- (IBMedia *)currentMedia {
    return self.index >= 0 && self.index < (NSInteger)self.mutableQueue.count ? self.mutableQueue[self.index] : nil;
}
- (BOOL)isPlaying { return self.item != nil && self.avPlayer.rate > 0; }

/* ---------------- layout ---------------- */

- (void)layoutInView:(UIView *)parent {
    CGSize s = parent.bounds.size;
    CGFloat fs = MAX(15, roundf(s.height * 0.029)), m = roundf(s.width * 0.05);
    self.root.frame = parent.bounds;
    self.backdrop.frame = self.root.bounds;
    self.surface.frame = self.root.bounds;
    BOOL audio = self.currentMedia.audioOnly;
    CGFloat art = s.height * 0.5;
    self.artwork.frame = CGRectMake(m, s.height * 0.16, art, art);
    self.artwork.hidden = !audio;
    self.hintLabel.hidden = audio;
    self.backdrop.hidden = !audio;

    CGFloat osdH = fs * 7.5;
    if (audio) {
        // Now-playing layout: details to the right of the artwork, always visible.
        CGFloat x = m + art + fs * 2, w = s.width - x - m;
        self.osd.frame = CGRectMake(x, s.height * 0.16, w, art);
        self.osdGradient.hidden = YES;
        int lines = art >= fs * 13 ? 2 : 1;  // short screens (composite, preview) get one title line
        CGFloat y = art * 0.06;
        self.noteLabel.frame = CGRectMake(0, y, w, fs * 1.3);
        y += fs * 1.6;
        self.titleLabel.font = IBFont(fs * 1.9, YES);
        self.titleLabel.numberOfLines = lines;
        self.titleLabel.frame = CGRectMake(0, y, w, fs * 2.3 * lines);
        y += fs * 2.3 * lines + fs * 0.3;
        self.subtitleLabel.font = IBFont(fs * 1.2, NO);
        self.subtitleLabel.frame = CGRectMake(0, y, w, fs * 1.6);
        self.barTrack.frame = CGRectMake(0, art - fs * 2.4, w, 6);
        self.timeLabel.frame = CGRectMake(0, art - fs * 1.6, w, fs * 1.4);
        self.stateLabel.frame = CGRectMake(0, art - fs * 1.6, fs * 6, fs * 1.4);
        self.stateLabel.textAlignment = NSTextAlignmentLeft;
    } else {
        self.osd.frame = CGRectMake(0, s.height - osdH, s.width, osdH);
        self.osdGradient.hidden = NO;
        self.titleLabel.font = IBFont(fs * 1.35, YES);
        self.titleLabel.numberOfLines = 1;
        self.titleLabel.frame = CGRectMake(m, fs * 1.2, s.width - 2 * m, fs * 1.8);
        self.subtitleLabel.font = IBFont(fs * 0.9, NO);
        self.subtitleLabel.frame = CGRectMake(m, fs * 3.0, s.width * 0.6, fs * 1.3);
        self.noteLabel.frame = CGRectMake(s.width * 0.6, fs * 3.0, s.width * 0.4 - m, fs * 1.3);
        self.barTrack.frame = CGRectMake(m, fs * 4.9, s.width - 2 * m - fs * 9, 6);
        self.timeLabel.frame = CGRectMake(s.width - m - fs * 8.5, fs * 4.4, fs * 8.5, fs * 1.4);
        self.hintLabel.frame = CGRectMake(m, fs * 5.6, s.width - 2 * m - fs * 9, fs * 1.3);
        self.hintLabel.font = IBFont(fs * 0.75, NO);
        self.stateLabel.frame = CGRectMake(0, -s.height * 0.45, s.width, fs * 2);
        self.stateLabel.textAlignment = NSTextAlignmentCenter;
    }
    self.noteLabel.font = IBFont(fs * 0.85, YES);
    self.timeLabel.font = IBFont(fs * 0.85, NO);
    self.stateLabel.font = IBFont(fs * (audio ? 0.85 : 2), YES);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.osdGradient.frame = self.osd.bounds;
    [CATransaction commit];
    self.spinner.center = CGPointMake(s.width / 2, s.height / 2);
    ((AVPlayerLayer *)self.surface.layer).videoGravity = [self videoGravity];
    if (self.optionsPanel) [self.optionsPanel layoutInBounds:self.root.bounds];
    [self tick];
}

- (NSString *)videoGravity {
    NSString *zoom = [IBSettings get:@"videoZoom"];
    if ([zoom isEqualToString:@"fill"]) return AVLayerVideoGravityResizeAspectFill;
    if ([zoom isEqualToString:@"stretch"]) return AVLayerVideoGravityResize;
    return AVLayerVideoGravityResizeAspect;
}

/* ---------------- queue ---------------- */

- (void)playQueue:(NSArray *)queue index:(NSInteger)index inView:(UIView *)parent {
    [self reportEvent:@"stop"];
    [self.mutableQueue setArray:queue];
    self.index = MAX(0, MIN(index, (NSInteger)queue.count - 1));
    if (!self.root.superview || self.root.superview != parent) [parent addSubview:self.root];
    [self show];
    [self startCurrent];
}

- (void)enqueue:(NSArray *)media {
    if (!self.currentMedia) {
        [self playQueue:media index:0 inView:[IBTV shared].view];
        return;
    }
    [self.mutableQueue addObjectsFromArray:media];
    [[IBTV shared] toast:[NSString stringWithFormat:@"Added %lu to queue", (unsigned long)media.count]];
}

- (void)show {
    UIView *parent = [IBTV shared].view;
    if (!self.currentMedia) return;
    if (self.root.superview != parent) [parent addSubview:self.root];
    [parent bringSubviewToFront:self.root];
    self.visible = YES;
    self.root.hidden = NO;
    [self layoutInView:parent];
    [self flashOSD];
    [[IBTV shared] playerVisibilityChanged];
}

- (void)hide {
    self.visible = NO;
    self.root.hidden = YES;
    [[IBTV shared] playerVisibilityChanged];
}

- (void)startCurrent {
    IBMedia *m = self.currentMedia;
    if (!m) return;
    [IBYouTube releaseMedia];  // the A4's single video decoder must be free for AVPlayer
    if (!m.audioOnly) [IBYouTube cancelWarmup];  // and its CPU shouldn't build YouTube's player meanwhile
    NSInteger gen = ++self.generation;
    [self detachItem];
    if (!self.restarting) [self closeOptions];
    self.restarting = NO;
    [self showCaptions:nil];
    self.userPaused = NO;
    self.titleLabel.text = m.title;
    self.subtitleLabel.text = m.subtitle;
    self.noteLabel.text = m.note;
    self.artwork.image = nil;
    self.backdrop.image = nil;
    [self layoutInView:self.root.superview ?: [IBTV shared].view];
    if (m.artworkURL) {
        [IBImageLoader load:m.artworkURL maxPixels:600 completion:^(UIImage *image) {
            if (gen != self.generation) return;
            self.artwork.image = image;
            self.backdrop.image = image;
        }];
    }
    [self.spinner startAnimating];

    void (^go)(NSString *) = ^(NSString *url) {
        if (gen != self.generation) return;
        self.resolvedURL = url;
        NSString *playable = IBPlayableURLWithHeaders(url, self.currentMedia.headers);
        if (self.currentMedia.proxyParams.count && [playable hasPrefix:@"http://127.0.0.1:8080/proxy?"]) {
            NSMutableString *withChoices = [playable mutableCopy];
            for (NSString *k in self.currentMedia.proxyParams) {
                [withChoices appendFormat:@"&%@=%@", k, [IBHTTP escape:[self.currentMedia.proxyParams[k] description]]];
            }
            playable = withChoices;
        }
        [self showCaptions:self.currentMedia.captionsURL];
        NSURL *u = [NSURL URLWithString:playable];
        if (!u) u = [NSURL URLWithString:[playable stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
        if (!u) {
            [self failed:@"Invalid media URL"];
            return;
        }
        NSLog(@"iBox: playing %@", u);
        self.playableURL = u.absoluteString;
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:u];
        self.item = item;

        [item addObserver:self forKeyPath:@"status" options:0 context:kItemStatusContext];
        [self.avPlayer replaceCurrentItemWithPlayerItem:item];
        [self.avPlayer play];
        self.lastReport = 0;
        self.noPictureSince = -1;
    };
    if (m.url) {
        go(m.url);
    } else if (m.resolver) {
        m.resolver(m, ^(NSString *url, NSString *error) {
            if (gen != self.generation) return;
            if (url) go(url);
            else [self failed:error ?: @"Could not find a stream"];
            // Resolvers may refine the metadata (e.g. preview vs full track).
            self.noteLabel.text = m.note;
            self.subtitleLabel.text = m.subtitle;
        });
    } else {
        [self failed:@"Nothing to play"];
    }
}

- (void)detachItem {
    if (self.item) {
        [self.item removeObserver:self forKeyPath:@"status" context:kItemStatusContext];
        self.item = nil;
    }
    [self.avPlayer replaceCurrentItemWithPlayerItem:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kItemStatusContext) return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = object;
        if (item != self.item) return;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            [self.spinner stopAnimating];
            IBMedia *m = self.currentMedia;
            if (m.startAt > 1) {
                [self.avPlayer seekToTime:CMTimeMakeWithSeconds(m.startAt, 1)];
                m.startAt = 0;
            }
            if (!self.userPaused) [self.avPlayer play];
            [self reportEvent:@"start"];
            [self flashOSD];
        } else if (item.status == AVPlayerItemStatusFailed) {
            NSError *e = item.error;
            NSString *detail = e.localizedFailureReason ?: e.localizedDescription;
            NSInteger code = e.code;
            NSError *underlying = e.userInfo[NSUnderlyingErrorKey];
            if (underlying) code = underlying.code;
            if (code == -12911 || code == -11828 || code == -11829 || code == -11821 ||
                [detail ?: @"" rangeOfString:@"-12911"].location != NSNotFound) {
                detail = @"format not supported by the iPhone 4 (needs H.264 Main/Baseline up to 720p, AAC/MP3)";
            }
            [self failed:[NSString stringWithFormat:@"Playback failed: %@", detail ?: @"unsupported stream"]];
        }
    });
}

- (void)failed:(NSString *)message {
    [self.spinner stopAnimating];
    [[IBTV shared] toast:[NSString stringWithFormat:@"%@ — %@", self.currentMedia.title ?: @"", message]];
    // Skip to the next item only for playlists/albums; a failed live channel stays put.
    if (!self.currentMedia.live && self.index + 1 < (NSInteger)self.mutableQueue.count) {
        self.index++;
        [self startCurrent];
    } else {
        [self stop];
    }
}

- (void)itemEnded:(NSNotification *)n {
    if (n.object != self.item) return;
    [self reportEvent:@"stop"];
    if (self.index + 1 < (NSInteger)self.mutableQueue.count) {
        self.index++;
        [self startCurrent];
    } else {
        [self stop];
    }
}

- (void)itemFailed:(NSNotification *)n {
    if (n.object != self.item) return;
    [self failed:@"stream interrupted"];
}

- (void)itemStalled:(NSNotification *)n {
    if (n.object != self.item) return;
    [self.spinner startAnimating];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (n.object == self.item && !self.userPaused) [self.avPlayer play];
    });
}

/* ---------------- transport ---------------- */

- (NSTimeInterval)position {
    double t = CMTimeGetSeconds(self.avPlayer.currentTime);
    return isnan(t) ? 0 : t;
}

- (NSTimeInterval)duration {
    if (!self.item) return 0;
    CMTime d = self.item.duration;
    if (CMTIME_IS_INDEFINITE(d) || CMTIME_IS_INVALID(d)) return 0;
    double s = CMTimeGetSeconds(d);
    return isnan(s) ? 0 : s;
}

- (void)reportEvent:(NSString *)event {
    IBMedia *m = self.currentMedia;
    if (!m.onEvent || !self.item) return;
    m.onEvent(m, event, [self position], self.userPaused);
}

- (void)togglePause {
    if (!self.item) return;
    self.userPaused = !self.userPaused;  // by intent: while buffering the rate is 0 even though it plays
    if (self.userPaused) [self.avPlayer pause];
    else [self.avPlayer play];
    [self reportEvent:@"pause"];
    [self flashOSD];
}

- (void)stop {
    [self reportEvent:@"stop"];
    self.generation++;
    [self closeOptions];
    [self showCaptions:nil];
    [self detachItem];
    [self.spinner stopAnimating];
    [self.mutableQueue removeAllObjects];
    self.index = 0;
    [self hide];
}

- (void)next {
    if (self.index + 1 >= (NSInteger)self.mutableQueue.count) return;
    [self reportEvent:@"stop"];
    self.index++;
    [self startCurrent];
}

- (void)previous {
    if ([self position] > 5 || self.index == 0) {
        [self seekTo:0];
        return;
    }
    [self reportEvent:@"stop"];
    self.index--;
    [self startCurrent];
}

- (void)seekBy:(NSTimeInterval)delta {
    [self seekTo:[self position] + delta];
}

- (void)seekTo:(NSTimeInterval)seconds {
    if (!self.item || self.currentMedia.live) return;
    NSTimeInterval d = [self duration];
    if (d > 0) seconds = MIN(seconds, d - 2);
    [self.avPlayer seekToTime:CMTimeMakeWithSeconds(MAX(0, seconds), 1)];
    [self flashOSD];
}

- (BOOL)handleKey:(IBKey)key {
    if (!self.currentMedia) return NO;
    BOOL audio = self.currentMedia.audioOnly;
    if (self.optionsPanel && self.visible) {
        if (![self.optionsPanel handleKey:key]) [self closeOptions];
        if (key == IBKeyHome) { [self stop]; return NO; }
        return YES;
    }
    if (self.visible && !audio && (key == IBKeyDown || key == IBKeyInfo)) {
        [self openOptions];
        return YES;
    }
    if (!self.visible) {
        switch (key) {
            case IBKeyPlayPause: [self togglePause]; return YES;
            case IBKeyNext: [self next]; return YES;
            case IBKeyPrev: [self previous]; return YES;
            default: return NO;
        }
    }
    switch (key) {
        case IBKeySelect:
            // Info bar hidden: OK (a tap on the iPhone) first brings it back; OK again pauses.
            if (!audio && self.osd.alpha < 0.5) [self flashOSD];
            else [self togglePause];
            break;
        case IBKeyPlayPause: [self togglePause]; break;
        case IBKeyLeft: if (audio && [self duration] == 0) [self previous]; else [self seekBy:-10]; break;
        case IBKeyRight: if (audio && [self duration] == 0) [self next]; else [self seekBy:30]; break;
        case IBKeyNext: [self next]; break;
        case IBKeyPrev: [self previous]; break;
        case IBKeyUp: case IBKeyDown: case IBKeyInfo: [self flashOSD]; break;
        case IBKeyBack:
            if (audio) [self hide]; else [self stop];
            break;
        case IBKeyHome:
            if (audio) [self hide]; else [self stop];
            return NO;  // let the TV go home too
    }
    return YES;
}

/* ---------------- options panel ---------------- */

- (BOOL)optionsOpen { return self.optionsPanel != nil; }

- (void)openOptions {
    if (self.optionsPanel || !self.currentMedia) return;
    [self.osdTimer invalidate];
    self.osd.alpha = 1;
    IBOptionsPanel *panel = [IBOptionsPanel panelWithOptions:[self buildOptions]];
    self.optionsPanel = panel;
    [self.root addSubview:panel];
    [panel layoutInBounds:self.root.bounds];
    [self updateCaptions];
}

- (void)closeOptions {
    if (!self.optionsPanel) return;
    [self.optionsPanel commit];
    [self.optionsPanel removeFromSuperview];
    self.optionsPanel = nil;
    [self flashOSD];
}

static NSString *HeightLabel(int h) { return [NSString stringWithFormat:@"%dp", h]; }

- (NSArray *)buildOptions {
    IBMedia *m = self.currentMedia;
    NSMutableArray *rows = [NSMutableArray array];
    if (m.options) [rows addObjectsFromArray:m.options(m) ?: @[]];
    NSArray *titles = [rows valueForKey:@"title"];
    __weak IBPlayer *weakSelf = self;
    NSDictionary *info = [IBRemoteAPI masterInfo:self.resolvedURL];

    if (![titles containsObject:@"Audio"]) {
        NSArray *names = info[@"audio"];
        if (names.count > 1) {  // HLS alternate languages, picked by the proxy
            NSString *cur = m.proxyParams[@"ib_audio"] ?: info[@"defaultAudio"];
            NSUInteger sel = [names indexOfObject:cur];
            [rows addObject:[IBOption optionWithTitle:@"Audio" choices:names selected:sel == NSNotFound ? 0 : sel apply:^(NSInteger i) {
                if (!m.proxyParams) m.proxyParams = [NSMutableDictionary dictionary];
                m.proxyParams[@"ib_audio"] = names[i];
                [weakSelf restartCurrent];
            }]];
        } else {
            NSMutableArray *tracks = [NSMutableArray array];  // audio tracks of a file
            for (AVPlayerItemTrack *t in self.item.tracks) {
                if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) [tracks addObject:t];
            }
            if (tracks.count > 1) {
                NSMutableArray *labels = [NSMutableArray array];
                NSInteger sel = 0;
                for (NSUInteger i = 0; i < tracks.count; i++) {
                    AVPlayerItemTrack *t = tracks[i];
                    NSString *lang = t.assetTrack.languageCode;
                    NSString *name = lang.length ? [[NSLocale currentLocale] displayNameForKey:NSLocaleLanguageCode value:lang] : nil;
                    [labels addObject:[NSString stringWithFormat:@"Track %lu%@", (unsigned long)i + 1, name.length ? [@" \u2014 " stringByAppendingString:name] : @""]];
                    if (t.enabled) sel = i;
                }
                [rows addObject:[IBOption optionWithTitle:@"Audio" choices:labels selected:sel apply:^(NSInteger i) {
                    for (NSUInteger k = 0; k < tracks.count; k++) ((AVPlayerItemTrack *)tracks[k]).enabled = (NSInteger)k == i;
                }]];
            }
        }
    }
    if (![titles containsObject:@"Subtitles"] && m.captionsURL) {
        [rows addObject:[IBOption optionWithTitle:@"Subtitles" choices:@[@"Off", @"On"] selected:self.captions ? 1 : 0 apply:^(NSInteger i) {
            [weakSelf showCaptions:i ? m.captionsURL : nil];
        }]];
    }
    NSArray *heights = info[@"heights"];
    if (![titles containsObject:@"Quality"] && heights.count > 1) {
        NSMutableArray *labels = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"Auto (up to %@)", HeightLabel([heights[0] intValue])]];
        for (NSNumber *h in heights) [labels addObject:HeightLabel(h.intValue)];
        NSUInteger sel = m.proxyParams[@"ib_maxh"] ? [heights indexOfObject:@([m.proxyParams[@"ib_maxh"] intValue])] : NSNotFound;
        [rows addObject:[IBOption optionWithTitle:@"Quality" choices:labels selected:sel == NSNotFound ? 0 : sel + 1 apply:^(NSInteger i) {
            if (!m.proxyParams) m.proxyParams = [NSMutableDictionary dictionary];
            if (i == 0) [m.proxyParams removeObjectForKey:@"ib_maxh"];
            else m.proxyParams[@"ib_maxh"] = [heights[i - 1] stringValue];
            [weakSelf restartCurrent];
        }]];
    }
    NSArray *zooms = @[@"fit", @"fill", @"stretch"];
    NSUInteger z = [zooms indexOfObject:[IBSettings get:@"videoZoom"] ?: @"fit"];
    [rows addObject:[IBOption optionWithTitle:@"Picture" choices:@[@"Fit", @"Fill (crop)", @"Stretch"]
                                     selected:z == NSNotFound ? 0 : z apply:^(NSInteger i) {
        [IBSettings set:@"videoZoom" value:zooms[i]];
        ((AVPlayerLayer *)weakSelf.surface.layer).videoGravity = [weakSelf videoGravity];
    }]];
    return rows;
}

- (void)restartCurrent {
    IBMedia *m = self.currentMedia;
    if (!m) return;
    NSTimeInterval pos = [self position];
    BOOL live = m.live || [self duration] == 0;
    [self reportEvent:@"stop"];
    m.startAt = live ? 0 : pos;
    self.restarting = YES;
    [self startCurrent];
}

/* ---------------- captions (subtitles drawn by iBox) ---------------- */

- (void)setCaptionsURL:(NSString *)url {
    self.currentMedia.captionsURL = url;
    [self showCaptions:url];
}

- (void)showCaptions:(NSString *)url {
    if (!url) {
        self.captions = nil;
        self.captionsLoaded = nil;
        [self.captionTimer invalidate];
        self.captionTimer = nil;
        [self.captionView setText:nil inBounds:self.root.bounds raised:NO];
        return;
    }
    if ([url isEqualToString:self.captionsLoaded]) return;
    self.captionsLoaded = url;
    NSInteger gen = self.generation;
    [IBSubtitleTrack load:url done:^(IBSubtitleTrack *track, NSString *error) {
        if (gen != self.generation || ![url isEqualToString:self.captionsLoaded]) return;
        if (!track) {
            self.captionsLoaded = nil;
            [[IBTV shared] toast:[NSString stringWithFormat:@"Subtitles unavailable: %@", error ?: @"unknown error"]];
            return;
        }
        self.captions = track;
        [self.captionTimer invalidate];
        self.captionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateCaptions)
                                                           userInfo:nil repeats:YES];
        [self updateCaptions];
    }];
}

- (void)updateCaptions {
    if (!self.captions) return;
    BOOL raised = self.osd.alpha > 0.5 || self.optionsPanel;
    [self.captionView setText:[self.captions textAt:[self position]] inBounds:self.root.bounds raised:raised];
}

/* ---------------- OSD ---------------- */

- (void)flashOSD {
    [self.osdTimer invalidate];
    self.osd.alpha = 1;
    [self tick];
    if (self.currentMedia.audioOnly || self.optionsPanel) return;
    self.osdTimer = [NSTimer scheduledTimerWithTimeInterval:4.5 target:self selector:@selector(fadeOSD)
                                                   userInfo:nil repeats:NO];
}

- (void)fadeOSD {
    if (self.userPaused || self.optionsPanel) return;
    [UIView animateWithDuration:0.6 animations:^{ self.osd.alpha = 0; }];
}

- (void)tick {
    if (!self.currentMedia) return;
    NSTimeInterval pos = [self position], dur = [self duration];
    BOOL live = self.currentMedia.live || (self.item.status == AVPlayerItemStatusReadyToPlay && dur == 0);
    self.timeLabel.text = live ? @"LIVE" : [NSString stringWithFormat:@"%@ / %@", IBFormatTime(pos), IBFormatTime(dur)];
    self.barTrack.hidden = live;
    self.hintLabel.text = live ? @"↓  Options (audio, subtitles, quality)     OK  Pause     ↑  Info"
                               : @"↓  Options (audio, subtitles, quality)     OK  Pause     ← →  Seek     ↑  Info";
    CGRect tb = self.barTrack.bounds;
    self.barFill.frame = CGRectMake(0, 0, dur > 0 ? tb.size.width * MIN(1, pos / dur) : 0, tb.size.height);
    self.stateLabel.text = self.userPaused ? (self.currentMedia.audioOnly ? @"|| Paused" : @"|| Paused") : nil;
    if (self.avPlayer.rate > 0 && self.spinner.isAnimating && pos > 0) [self.spinner stopAnimating];
    // AVPlayer's clock also runs when only the audio plays. A video stream that has a
    // video track but no decoded picture after ~10 s is a format the A4 can't decode.
    IBMedia *m = self.currentMedia;
    // readyForDisplay turns on only once a frame has actually been decoded. (Don't use
    // AVPlayerItemVideoOutput to check this: on iOS 6 it wedges the A4's media stack.)
    BOOL noPicture = !((AVPlayerLayer *)self.surface.layer).readyForDisplay;
    if (!m.audioOnly && self.avPlayer.rate > 0 && pos > 0.5 && [self hasVideoTrack] && noPicture) {
        if (self.noPictureSince < 0) self.noPictureSince = pos;
        if (pos - self.noPictureSince > 10) {
            self.noPictureSince = -1;
            return [self failed:@"the video can't be decoded by the iPhone 4 (sound only)"];
        }
    } else {
        self.noPictureSince = -1;
    }
    if (pos - self.lastReport >= 10 || pos < self.lastReport) {
        self.lastReport = pos;
        if (pos > 0) [self reportEvent:@"progress"];
    }
}

// From AVPlayer's access log: one event per variant it played, so several events mean
// quality switches (on iOS 6 those replay a few seconds and stutter).
- (NSDictionary *)streamStats {
    NSArray *events = self.item.accessLog.events;
    NSInteger stalls = 0;
    NSMutableArray *bitrates = [NSMutableArray array];
    for (AVPlayerItemAccessLogEvent *e in events) {
        stalls += MAX(0, e.numberOfStalls);
        [bitrates addObject:@((long)(e.indicatedBitrate / 1000))];
    }
    AVPlayerItemAccessLogEvent *last = events.lastObject;
    NSMutableArray *log = [NSMutableArray array];
    for (AVPlayerItemAccessLogEvent *e in events) {
        [log addObject:@{@"start": @([e.playbackStartDate timeIntervalSinceReferenceDate]), @"offset": @(e.playbackStartOffset),
                         @"requests": @(e.numberOfMediaRequests), @"downloaded": @(e.segmentsDownloadedDuration),
                         @"watched": @(e.durationWatched), @"stalls": @(e.numberOfStalls),
                         @"kbps": @((long)(e.indicatedBitrate / 1000)), @"dropped": @(e.numberOfDroppedVideoFrames)}];
    }
    NSMutableArray *errors = [NSMutableArray array];
    for (AVPlayerItemErrorLogEvent *e in self.item.errorLog.events) {
        [errors addObject:@{@"date": @([e.date timeIntervalSinceReferenceDate]), @"status": @(e.errorStatusCode),
                            @"domain": e.errorDomain ?: @"", @"comment": e.errorComment ?: @"", @"uri": [e.URI lastPathComponent] ?: @""}];
    }
    NSMutableArray *seekable = [NSMutableArray array], *loaded = [NSMutableArray array];
    for (NSValue *v in self.item.seekableTimeRanges) {
        CMTimeRange t = v.CMTimeRangeValue;
        [seekable addObject:@[@(CMTimeGetSeconds(t.start)), @(CMTimeGetSeconds(CMTimeRangeGetEnd(t)))]];
    }
    for (NSValue *v in self.item.loadedTimeRanges) {
        CMTimeRange t = v.CMTimeRangeValue;
        [loaded addObject:@[@(CMTimeGetSeconds(t.start)), @(CMTimeGetSeconds(CMTimeRangeGetEnd(t)))]];
    }
    return @{@"variants": bitrates, @"stalls": @(stalls), @"log": log, @"errors": errors,
             @"seekable": seekable, @"loaded": loaded,
             @"observedKbps": @((long)(MAX(0, last.observedBitrate) / 1000)),
             @"droppedFrames": @(MAX(0, last.numberOfDroppedVideoFrames))};
}

- (BOOL)hasVideoTrack {
    for (AVPlayerItemTrack *t in self.item.tracks) {
        if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) return YES;
    }
    return NO;
}

- (NSDictionary *)state {
    IBMedia *m = self.currentMedia;
    if (!m) return nil;
    CGSize picture = self.item.presentationSize;
    return @{@"title": m.title ?: @"", @"subtitle": m.subtitle ?: @"", @"artwork": m.artworkURL ?: @"",
             @"width": @(picture.width), @"height": @(picture.height), @"videoTrack": @([self hasVideoTrack]),
             @"picture": @(((AVPlayerLayer *)self.surface.layer).readyForDisplay),
             @"stream": [self streamStats],
             @"position": @([self position]), @"duration": @([self duration]), @"paused": @(self.userPaused),
             @"audio": @(m.audioOnly), @"visible": @(self.visible), @"index": @(self.index),
             @"count": @(self.mutableQueue.count), @"note": m.note ?: @"", @"osd": @(self.osd.alpha),
             @"options": self.optionsPanel ? [self.optionsPanel stateSnapshot] : [NSNull null],
             @"captions": @(self.captions != nil), @"source": self.resolvedURL ?: @"", @"playable": self.playableURL ?: @"",
             @"choices": m.proxyParams ?: @{}};
}

@end
