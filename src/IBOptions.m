#import "IBOptions.h"
#import "IBHTTP.h"
#import <QuartzCore/QuartzCore.h>

@implementation IBOption
+ (instancetype)optionWithTitle:(NSString *)title choices:(NSArray *)choices selected:(NSInteger)selected
                          apply:(void (^)(NSInteger))apply {
    IBOption *o = [IBOption new];
    o.title = title;
    o.choices = choices;
    o.selected = MAX(0, MIN(selected, (NSInteger)choices.count - 1));
    o.apply = apply;
    return o;
}
@end

/* ================= panel ================= */

@interface IBOptionsPanel ()
@property (nonatomic, strong) NSArray *options;
@property (nonatomic, strong) NSMutableArray *rows;  // @[title label, value label, row view]
@property (nonatomic, strong) UILabel *header, *hint;
@property (nonatomic) NSInteger focus;
@property (nonatomic) NSInteger pendingRow;          // -1: nothing waiting to be applied
@property (nonatomic, strong) NSTimer *applyTimer;
@property (nonatomic) CGFloat fs;
@end

@implementation IBOptionsPanel

+ (instancetype)panelWithOptions:(NSArray *)options {
    IBOptionsPanel *p = [[IBOptionsPanel alloc] initWithFrame:CGRectZero];
    p.options = options;
    p.pendingRow = -1;
    p.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.1 alpha:0.9];
    p.layer.cornerRadius = 12;
    p.layer.borderColor = IBColor(0x3A4566).CGColor;
    p.layer.borderWidth = 1;
    p.header = [p label:YES];
    p.header.text = @"Options";
    p.hint = [p label:NO];
    p.hint.textColor = IBColor(0x7D879F);
    p.hint.text = @"↑ ↓ choose   ← → change   OK / Back close";
    p.rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < options.count; i++) {
        UIView *row = [[UIView alloc] init];
        row.layer.cornerRadius = 8;
        [p addSubview:row];
        UILabel *t = [p label:NO], *v = [p label:YES];
        t.textColor = IBColor(0xAAB3CC);
        v.textAlignment = NSTextAlignmentRight;
        [p.rows addObject:@[t, v, row]];
    }
    [p refresh];
    return p;
}

- (UILabel *)label:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    l.font = IBFont(20, bold);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:l];
    return l;
}

- (void)layoutInBounds:(CGRect)bounds {
    CGFloat fs = MAX(15, roundf(bounds.size.height * 0.029)), m = roundf(bounds.size.width * 0.05);
    self.fs = fs;
    CGFloat rowH = fs * 2.1, w = MIN(bounds.size.width - 2 * m, fs * 30);
    CGFloat h = fs * 2.6 + rowH * self.options.count + fs * 2.2;
    self.frame = CGRectMake(bounds.size.width - m - w, MAX(m * 0.6, (bounds.size.height - h) / 2 - fs * 2), w, h);
    CGFloat pad = fs * 1.1;
    self.header.font = IBFont(fs * 1.2, YES);
    self.header.frame = CGRectMake(pad, fs * 0.7, w - 2 * pad, fs * 1.6);
    CGFloat y = fs * 2.6;
    for (NSArray *r in self.rows) {
        UILabel *t = r[0], *v = r[1];
        UIView *row = r[2];
        row.frame = CGRectMake(fs * 0.5, y, w - fs, rowH - fs * 0.2);
        t.font = IBFont(fs, NO);
        v.font = IBFont(fs, YES);
        t.frame = CGRectMake(pad, y, w * 0.34, rowH - fs * 0.2);
        v.frame = CGRectMake(pad + w * 0.34, y, w - 2 * pad - w * 0.34, rowH - fs * 0.2);
        y += rowH;
    }
    self.hint.font = IBFont(fs * 0.72, NO);
    self.hint.frame = CGRectMake(pad, h - fs * 1.8, w - 2 * pad, fs * 1.3);
}

- (void)refresh {
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        IBOption *o = self.options[i];
        UILabel *t = self.rows[i][0], *v = self.rows[i][1];
        UIView *row = self.rows[i][2];
        BOOL focused = (NSInteger)i == self.focus;
        t.text = o.title;
        NSString *value = o.choices.count ? o.choices[o.selected] : @"—";
        BOOL many = o.choices.count > 1;
        v.text = focused && many ? [NSString stringWithFormat:@"‹  %@  ›", value] : value;
        v.textColor = many ? [UIColor whiteColor] : IBColor(0x7D879F);
        row.backgroundColor = focused ? IBColor(0x24304D) : [UIColor clearColor];
        row.layer.borderWidth = focused ? 1 : 0;
        row.layer.borderColor = IBColor(0x00A4DC).CGColor;
    }
}

- (void)commit {
    [self.applyTimer invalidate];
    self.applyTimer = nil;
    NSInteger r = self.pendingRow;
    self.pendingRow = -1;
    if (r < 0 || r >= (NSInteger)self.options.count) return;
    IBOption *o = self.options[r];
    if (o.apply) o.apply(o.selected);
}

- (BOOL)handleKey:(IBKey)key {
    NSInteger n = self.options.count;
    switch (key) {
        case IBKeyUp:
            if (n) self.focus = (self.focus + n - 1) % n;
            break;
        case IBKeyDown:
            if (n) self.focus = (self.focus + 1) % n;
            break;
        case IBKeyLeft: case IBKeyRight: {
            if (!n) break;
            IBOption *o = self.options[self.focus];
            if (o.choices.count < 2) break;
            if (self.pendingRow >= 0 && self.pendingRow != self.focus) [self commit];
            NSInteger c = o.choices.count;
            o.selected = (o.selected + (key == IBKeyRight ? 1 : c - 1)) % c;
            self.pendingRow = self.focus;
            [self.applyTimer invalidate];
            self.applyTimer = [NSTimer scheduledTimerWithTimeInterval:0.9 target:self selector:@selector(commit)
                                                             userInfo:nil repeats:NO];
            break;
        }
        case IBKeySelect: case IBKeyBack: case IBKeyInfo: case IBKeyHome:
            [self commit];
            return NO;
        default:
            break;
    }
    [self refresh];
    return YES;
}

- (NSArray *)stateSnapshot {
    NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.options.count; i++) {
        IBOption *o = self.options[i];
        [a addObject:@{@"title": o.title ?: @"", @"choices": o.choices ?: @[], @"selected": @(o.selected),
                       @"focused": @((NSInteger)i == self.focus)}];
    }
    return a;
}

- (void)dealloc {
    [_applyTimer invalidate];
}
@end

/* ================= subtitles ================= */

@interface IBSubtitleTrack ()
@property (nonatomic, strong) NSArray *cues;  // @[start, end, text], sorted by start
@end

@implementation IBSubtitleTrack

static double CueTime(NSString *s) {  // "01:02:03.456", "02:03.456" or SRT's "01:02:03,456"
    NSArray *p = [[s stringByReplacingOccurrencesOfString:@"," withString:@"."] componentsSeparatedByString:@":"];
    double t = 0;
    for (NSString *x in p) t = t * 60 + [x doubleValue];
    return t;
}

static NSString *CleanCue(NSString *text) {
    static NSRegularExpression *tags, *ass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL];
        ass = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}" options:0 error:NULL];
    });
    NSMutableString *m = [text mutableCopy];
    [tags replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    [ass replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    [m replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&nbsp;" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\\N" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (instancetype)trackWithText:(NSString *)text {
    NSMutableArray *cues = [NSMutableArray array];
    NSString *norm = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray *blocks = [norm componentsSeparatedByString:@"\n\n"];
    for (NSString *block in blocks) {
        NSArray *lines = [block componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSRange arrow = [lines[i] rangeOfString:@"-->"];
            if (arrow.location == NSNotFound) continue;
            NSString *start = [[lines[i] substringToIndex:arrow.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *rest = [[lines[i] substringFromIndex:NSMaxRange(arrow)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *end = [rest componentsSeparatedByString:@" "][0];  // drop WebVTT cue settings
            NSString *body = CleanCue([[lines subarrayWithRange:NSMakeRange(i + 1, lines.count - i - 1)] componentsJoinedByString:@"\n"]);
            if (body.length) [cues addObject:@[@(CueTime(start)), @(CueTime(end)), body]];
            break;
        }
    }
    [cues sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    IBSubtitleTrack *t = [IBSubtitleTrack new];
    t.cues = cues;
    return t;
}

+ (void)load:(NSString *)url done:(void (^)(IBSubtitleTrack *, NSString *))done {
    [IBHTTP get:url headers:nil completion:^(IBHTTPResponse *response, NSError *error) {
        if (error || !response.body.length) return done(nil, error.localizedDescription ?: @"empty subtitles");
        NSString *text = [[NSString alloc] initWithData:response.body encoding:NSUTF8StringEncoding]
                      ?: [[NSString alloc] initWithData:response.body encoding:NSISOLatin1StringEncoding];
        IBSubtitleTrack *t = [self trackWithText:text ?: @""];
        if (!t.count) return done(nil, @"no subtitle lines found");
        done(t, nil);
    }];
}

- (NSUInteger)count { return self.cues.count; }

- (NSString *)textAt:(NSTimeInterval)t {
    // Binary search for the last cue starting before t, then look back for overlaps.
    NSInteger lo = 0, hi = (NSInteger)self.cues.count - 1, found = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if ([self.cues[mid][0] doubleValue] <= t) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (NSInteger i = found; i >= 0 && i > found - 8; i--) {
        NSArray *c = self.cues[i];
        if ([c[1] doubleValue] > t) [lines insertObject:c[2] atIndex:0];
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : nil;
}
@end

@interface IBSubtitleView ()
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, copy) NSString *shown;
@end

@implementation IBSubtitleView
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    self.layer.cornerRadius = 6;
    _label = [[UILabel alloc] init];
    _label.backgroundColor = [UIColor clearColor];
    _label.textColor = [UIColor whiteColor];
    _label.numberOfLines = 0;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.shadowColor = [UIColor blackColor];
    _label.shadowOffset = CGSizeMake(1, 1);
    [self addSubview:_label];
    self.hidden = YES;
    return self;
}

- (void)setText:(NSString *)text inBounds:(CGRect)bounds raised:(BOOL)raised {
    if (!text.length) {
        self.hidden = YES;
        self.shown = nil;
        return;
    }
    CGFloat fs = MAX(18, roundf(bounds.size.height * 0.045));
    self.label.font = IBFont(fs, YES);
    if (![text isEqualToString:self.shown] || self.hidden) {
        self.shown = text;
        self.label.text = text;
    }
    CGFloat maxW = bounds.size.width * 0.84;
    CGSize ts = [text sizeWithFont:self.label.font constrainedToSize:CGSizeMake(maxW, fs * 6) lineBreakMode:NSLineBreakByWordWrapping];
    CGFloat w = ts.width + fs * 1.2, h = ts.height + fs * 0.5;
    CGFloat bottom = bounds.size.height * (raised ? 0.8 : 0.93);
    self.frame = CGRectIntegral(CGRectMake((bounds.size.width - w) / 2, bottom - h, w, h));
    self.label.frame = CGRectInset(self.bounds, fs * 0.6, fs * 0.25);
    self.hidden = NO;
}
@end
