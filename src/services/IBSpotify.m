#import "IBServices.h"
#import "IBHTTP.h"
#import "IBTV.h"

// Spotify catalog on iOS 6. Playlists/albums/tracks are read from Spotify's public
// embed pages (no account needed); search uses the Web API with your own client
// credentials. Spotify's full-length audio is DRM-protected and has no iOS 6 client,
// so each track plays as its YouTube video (YouTube's own player, kept visible as
// its terms require), falling back to Spotify's 30 s preview.

@implementation IBSpotify

static NSString *gToken;
static NSDate *gTokenExpiry;

+ (NSArray *)parseLink:(NSString *)link {  // @[type, id]
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"(?:open\\.spotify\\.com/(?:intl-[a-z]+/)?(?:embed/)?|spotify:)(track|album|playlist|artist)[/:]([A-Za-z0-9]{22})"
                                                                        options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:link options:0 range:NSMakeRange(0, link.length)];
    if (!m) return nil;
    return @[[[link substringWithRange:[m rangeAtIndex:1]] lowercaseString], [link substringWithRange:[m rangeAtIndex:2]]];
}

+ (void)fetchEntity:(NSString *)type id:(NSString *)entityId done:(void (^)(NSDictionary *entity, NSString *error))done {
    NSString *url = [NSString stringWithFormat:@"https://open.spotify.com/embed/%@/%@", type, entityId];
    [IBHTTP get:url headers:@{@"Accept": @"text/html", @"Accept-Language": @"en"} completion:^(IBHTTPResponse *resp, NSError *error) {
        if (error) return done(nil, [NSString stringWithFormat:@"Spotify: %@", error.localizedDescription]);
        NSString *html = [resp text] ?: @"";
        NSRange start = [html rangeOfString:@"<script id=\"__NEXT_DATA__\" type=\"application/json\">"];
        if (start.location == NSNotFound) return done(nil, @"Spotify: unexpected page format");
        NSUInteger from = NSMaxRange(start);
        NSRange end = [html rangeOfString:@"</script>" options:0 range:NSMakeRange(from, html.length - from)];
        if (end.location == NSNotFound) return done(nil, @"Spotify: unexpected page format");
        NSData *json = [[html substringWithRange:NSMakeRange(from, end.location - from)] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *root = IBDict([NSJSONSerialization JSONObjectWithData:json options:0 error:NULL]);
        NSDictionary *entity = IBDict(IBDict(IBDict(IBDict(IBDict(root[@"props"])[@"pageProps"])[@"state"])[@"data"])[@"entity"]);
        if (!entity.count) return done(nil, @"Spotify: this item is not available");
        done(entity, nil);
    }];
}

+ (NSString *)coverOf:(NSDictionary *)entity {
    NSString *c = IBString(IBDict([IBArray(IBDict(entity[@"coverArt"])[@"sources"]) firstObject])[@"url"]);
    if (c) return c;
    return IBString(IBDict([IBArray(IBDict(entity[@"visualIdentity"])[@"image"]) firstObject])[@"url"]);
}

// A YouTube-player queue entry for a Spotify track: the song's YouTube video plays
// (found by "artist title"); if that fails, Spotify's 30 s preview plays instead.
+ (NSDictionary *)trackEntry:(NSString *)title artist:(NSString *)artist cover:(NSString *)cover preview:(NSString *)preview trackId:(NSString *)trackId {
    IBMedia *m = [IBMedia new];
    m.title = title;
    m.subtitle = artist;
    m.artworkURL = cover;
    m.audioOnly = YES;
    m.note = @"Spotify preview (30 s)";
    m.resolver = ^(IBMedia *media, IBResolveDone done) {
        if (preview || !trackId) return done(preview, preview ? nil : @"no Spotify preview for this track");
        [self fetchEntity:@"track" id:trackId done:^(NSDictionary *entity, NSString *error) {
            NSString *url = IBString(IBDict(entity[@"audioPreview"])[@"url"]);
            done(url, url ? nil : @"no Spotify preview for this track");
        }];
    };
    return @{@"query": [NSString stringWithFormat:@"%@ %@", artist ?: @"", title ?: @""],
             @"title": title ?: @"", @"channel": artist ?: @"", @"thumb": cover ?: @"", @"preview": m};
}

+ (void)remember:(NSString *)link title:(NSString *)title image:(NSString *)image kind:(NSString *)kind {
    NSMutableArray *recents = [IBArray([IBSettings object:@"spotifyRecents"]) mutableCopy];
    for (NSDictionary *r in [recents copy]) {
        if ([r[@"link"] isEqual:link]) [recents removeObject:r];
    }
    [recents insertObject:@{@"link": link, @"title": title ?: @"", @"image": image ?: @"", @"kind": kind} atIndex:0];
    while (recents.count > 24) [recents removeLastObject];
    [IBSettings setObject:recents forKey:@"spotifyRecents"];
}

+ (IBPage *)entityPage:(NSString *)type id:(NSString *)entityId link:(NSString *)link {
    return [IBPage pageWithTitle:[type capitalizedString] shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        [self fetchEntity:type id:entityId done:^(NSDictionary *entity, NSString *error) {
            if (error) return done(nil, error);
            NSString *name = IBString(entity[@"name"]) ?: IBString(entity[@"title"]);
            NSString *cover = [self coverOf:entity];
            p.title = name;
            [self remember:link title:name image:cover kind:type];
            NSArray *tracks = IBArray(entity[@"trackList"]);
            NSMutableArray *queue = [NSMutableArray array];
            for (NSDictionary *t in tracks) {
                NSArray *parts = [IBString(t[@"uri"]) componentsSeparatedByString:@":"];
                [queue addObject:[self trackEntry:IBString(t[@"title"]) artist:IBString(t[@"subtitle"]) cover:cover
                                          preview:IBString(IBDict(t[@"audioPreview"])[@"url"]) trackId:parts.lastObject]];
            }
            NSMutableArray *items = [NSMutableArray array];
            if (queue.count) {
                [items addObject:[[IBItem itemWithTitle:@"►  Play all" subtitle:[NSString stringWithFormat:@"%@ • %lu tracks", IBString(entity[@"subtitle"]) ?: @"Spotify", (unsigned long)queue.count]
                                                 image:cover action:^{ [IBYouTube playQueue:queue index:0]; }] withShape:IBShapeRow]];
                [items addObject:[[IBItem itemWithTitle:@"Shuffle" subtitle:nil image:nil action:^{
                    NSMutableArray *shuffled = [queue mutableCopy];
                    for (NSUInteger i = shuffled.count; i > 1; i--) [shuffled exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((u_int32_t)i)];
                    [IBYouTube playQueue:shuffled index:0];
                }] withShape:IBShapeRow]];
            }
            for (NSUInteger i = 0; i < tracks.count; i++) {
                NSDictionary *t = tracks[i];
                long secs = [t[@"duration"] longValue] / 1000;
                [items addObject:[[IBItem itemWithTitle:IBString(t[@"title"])
                                               subtitle:[NSString stringWithFormat:@"%@  •  %@", IBString(t[@"subtitle"]) ?: @"", IBFormatTime(secs)]
                                                  image:nil action:^{ [IBYouTube playQueue:queue index:(NSInteger)i]; }] withShape:IBShapeRow]];
            }
            done(items, tracks.count ? nil : @"No tracks found");
        }];
    }];
}

+ (BOOL)openLink:(NSString *)link {
    NSArray *parsed = [self parseLink:link];
    if (!parsed) {
        [[IBTV shared] toast:@"Not a Spotify track, album, playlist or artist link"];
        return NO;
    }
    NSString *type = parsed[0], *entityId = parsed[1];
    NSString *canonical = [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", type, entityId];
    if ([type isEqual:@"track"]) {
        [self fetchEntity:@"track" id:entityId done:^(NSDictionary *entity, NSString *error) {
            if (error) return [[IBTV shared] toast:error];
            NSString *artists = [[IBArray(entity[@"artists"]) valueForKey:@"name"] componentsJoinedByString:@", "];
            NSString *cover = [self coverOf:entity];
            [self remember:canonical title:IBString(entity[@"name"]) image:cover kind:@"track"];
            [IBYouTube playQueue:@[[self trackEntry:IBString(entity[@"name"]) artist:artists cover:cover
                                                preview:IBString(IBDict(entity[@"audioPreview"])[@"url"]) trackId:entityId]] index:0];
        }];
    } else {
        [[IBTV shared] pushPage:[self entityPage:type id:entityId link:canonical]];
    }
    return YES;
}

/* ---------------- Web API search (optional) ---------------- */

+ (void)withToken:(void (^)(NSString *token, NSString *error))done {
    NSString *cid = [IBSettings get:@"spotifyClientId"], *secret = [IBSettings get:@"spotifyClientSecret"];
    if (!cid.length || !secret.length) return done(nil, @"Add a Spotify client ID and secret in Settings to search (developer.spotify.com).");
    if (gToken && [gTokenExpiry timeIntervalSinceNow] > 60) return done(gToken, nil);
    NSData *creds = [[NSString stringWithFormat:@"%@:%@", cid, secret] dataUsingEncoding:NSUTF8StringEncoding];
    [IBHTTP request:@"https://accounts.spotify.com/api/token" method:@"POST"
            headers:@{@"Authorization": [@"Basic " stringByAppendingString:[creds base64Encoding]],
                      @"Content-Type": @"application/x-www-form-urlencoded"}
               body:[@"grant_type=client_credentials" dataUsingEncoding:NSUTF8StringEncoding]
         completion:^(IBHTTPResponse *resp, NSError *error) {
        NSDictionary *json = IBDict([resp json]);
        if (error || !json[@"access_token"]) return done(nil, [NSString stringWithFormat:@"Spotify login failed: %@", error.localizedDescription ?: @"?"]);
        gToken = json[@"access_token"];
        gTokenExpiry = [NSDate dateWithTimeIntervalSinceNow:[json[@"expires_in"] doubleValue]];
        done(gToken, nil);
    }];
}

+ (IBPage *)searchPage:(NSString *)query {
    return [IBPage pageWithTitle:[NSString stringWithFormat:@"“%@”", query] shape:IBShapeSquare loader:^(IBPage *p, IBPageDone done) {
        [self withToken:^(NSString *token, NSString *error) {
            if (error) return done(@[], error);
            NSString *url = [NSString stringWithFormat:@"https://api.spotify.com/v1/search?type=track,album,playlist&limit=10&market=%@&q=%@",
                             [IBServices country], [IBHTTP escape:query]];
            [IBHTTP getJSON:url headers:@{@"Authorization": [@"Bearer " stringByAppendingString:token]} completion:^(id json, NSError *e2) {
                if (e2) return done(nil, [NSString stringWithFormat:@"Spotify: %@", e2.localizedDescription]);
                NSMutableArray *items = [NSMutableArray array];
                NSArray *tracks = IBArray(IBDict(IBDict(json)[@"tracks"])[@"items"]);
                NSMutableArray *queue = [NSMutableArray array];
                if (tracks.count) [items addObject:[IBItem header:@"Tracks"]];
                for (NSDictionary *t in tracks) {
                    if (![t isKindOfClass:[NSDictionary class]]) continue;
                    NSString *artists = [[IBArray(t[@"artists"]) valueForKey:@"name"] componentsJoinedByString:@", "];
                    NSString *cover = IBString(IBDict([IBArray(IBDict(t[@"album"])[@"images"]) firstObject])[@"url"]);
                    [queue addObject:[self trackEntry:IBString(t[@"name"]) artist:artists cover:cover
                                              preview:IBString(t[@"preview_url"]) trackId:IBString(t[@"id"])]];
                    NSUInteger idx = queue.count - 1;
                    [items addObject:[IBItem itemWithTitle:IBString(t[@"name"]) subtitle:artists image:cover action:^{
                        [IBYouTube playQueue:queue index:(NSInteger)idx];
                    }]];
                }
                for (NSString *kind in @[@"albums", @"playlists"]) {
                    NSArray *list = IBArray(IBDict(IBDict(json)[kind])[@"items"]);
                    BOOL headerAdded = NO;
                    for (NSDictionary *a in list) {
                        if (![a isKindOfClass:[NSDictionary class]]) continue;
                        if (!headerAdded) { [items addObject:[IBItem header:[kind capitalizedString]]]; headerAdded = YES; }
                        NSString *sub = [kind isEqual:@"albums"] ? [[IBArray(a[@"artists"]) valueForKey:@"name"] componentsJoinedByString:@", "]
                                                                 : IBString(IBDict(a[@"owner"])[@"display_name"]);
                        NSString *link = IBString(IBDict(a[@"external_urls"])[@"spotify"]);
                        [items addObject:[IBItem itemWithTitle:IBString(a[@"name"]) subtitle:sub
                                                         image:IBString(IBDict([IBArray(a[@"images"]) firstObject])[@"url"])
                                                        action:^{ [self openLink:link]; }]];
                    }
                }
                done(items, nil);
            }];
        }];
    }];
}

+ (IBPage *)rootPage {
    IBPage *page = [IBPage pageWithTitle:@"Spotify" shape:IBShapeSquare loader:^(IBPage *p, IBPageDone done) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[[IBItem itemWithTitle:@"Open a Spotify link" subtitle:@"Playlist, album, artist or track — or share it from the web remote"
                                         image:nil action:^{
            [[IBTV shared] promptText:@"Paste a Spotify link" initial:@"" secure:NO done:^(NSString *text) { [self openLink:text]; }];
        }] withShape:IBShapeRow]];
        [items addObject:[[IBItem itemWithTitle:@"Search Spotify" subtitle:[IBSettings get:@"spotifyClientId"].length ? nil : @"Needs a Spotify client ID/secret in Settings"
                                         image:nil action:^{
            [[IBTV shared] promptText:@"Search Spotify" initial:@"" secure:NO done:^(NSString *text) {
                if (text.length) [[IBTV shared] pushPage:[self searchPage:text]];
            }];
        }] withShape:IBShapeRow]];
        [items addObject:[[IBItem itemWithTitle:@"Today's Top Hits" subtitle:@"Spotify playlist" image:nil action:^{
            [self openLink:@"https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"];
        }] withShape:IBShapeRow]];
        NSArray *recents = IBArray([IBSettings object:@"spotifyRecents"]);
        if (recents.count) [items addObject:[IBItem header:@"Recently opened"]];
        for (NSDictionary *r in recents) {
            IBItem *i = [IBItem itemWithTitle:r[@"title"] subtitle:[r[@"kind"] capitalizedString] image:r[@"image"]
                                       action:^{ [self openLink:r[@"link"]]; }];
            i.color = IBColor(0x123A22);
            [items addObject:i];
        }
        [items addObject:[IBItem header:@"About"]];
        [items addObject:[[IBItem itemWithTitle:@"Full tracks play as their YouTube video"
                                       subtitle:@"Spotify's own audio can't play on iOS 6; the 30 s preview is used if YouTube has no match"
                                          image:nil action:nil] withShape:IBShapeRow]];
        done(items, nil);
    }];
    page.reloadOnShow = YES;
    return page;
}

@end
