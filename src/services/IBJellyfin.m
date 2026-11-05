#import "IBServices.h"
#import "IBOptions.h"
#import "IBPlayer.h"
#import "IBHTTP.h"
#import "IBTV.h"
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

// Jellyfin client. Video is negotiated through PlaybackInfo with a device profile
// matching the iPhone 4 decoder (H.264 Main/Baseline <= level 3.1, AAC stereo), so
// the server direct-plays compatible files and transcodes everything else to HLS.

static const double kTicks = 10000000.0;

@implementation IBJellyfin

+ (NSString *)server {
    NSString *s = [[IBSettings get:@"jellyfinURL"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0) return nil;
    if (![s hasPrefix:@"http"]) s = [@"http://" stringByAppendingString:s];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

+ (NSString *)token { return [IBSettings get:@"jellyfinToken"]; }
+ (NSString *)userId { return [IBSettings get:@"jellyfinUserId"]; }

+ (NSDictionary *)authHeaders {
    NSString *auth = [NSString stringWithFormat:@"MediaBrowser Client=\"iBox\", Device=\"%@\", DeviceId=\"%@\", Version=\"1.0\"%@",
                      [UIDevice currentDevice].name, [IBSettings deviceId],
                      self.token.length ? [NSString stringWithFormat:@", Token=\"%@\"", self.token] : @""];
    NSMutableDictionary *h = [@{@"X-Emby-Authorization": auth} mutableCopy];
    if (self.token.length) h[@"X-Emby-Token"] = self.token;
    return h;
}

+ (void)login:(void (^)(NSString *error))done {
    NSString *server = [self server];
    if (!server) return done(@"Set your Jellyfin server address in Settings (or from the web remote).");
    NSString *user = [IBSettings get:@"jellyfinUser"];
    if (!user.length) return done(@"Set your Jellyfin user name in Settings.");
    [IBSettings update:@{@"jellyfinToken": @"", @"jellyfinUserId": @""}];
    [IBHTTP postJSON:[server stringByAppendingString:@"/Users/AuthenticateByName"] headers:[self authHeaders]
              object:@{@"Username": user, @"Pw": [IBSettings get:@"jellyfinPassword"] ?: @""}
          completion:^(id json, NSError *error) {
        NSString *token = IBString(IBDict(json)[@"AccessToken"]);
        NSString *uid = IBString(IBDict(IBDict(json)[@"User"])[@"Id"]);
        if (error || !token || !uid) {
            return done([NSString stringWithFormat:@"Jellyfin login failed: %@", error.localizedDescription ?: @"bad response"]);
        }
        [IBSettings update:@{@"jellyfinToken": token, @"jellyfinUserId": uid}];
        done(nil);
    }];
}

// Calls the API, logging in first (or again after a 401) when needed.
+ (void)api:(NSString *)path method:(NSString *)method body:(id)body done:(void (^)(id json, NSString *error))done {
    [self api:path method:method body:body retry:YES done:done];
}

+ (void)api:(NSString *)path method:(NSString *)method body:(id)body retry:(BOOL)retry
       done:(void (^)(id json, NSString *error))done {
    if (!self.token.length || !self.userId.length) {
        return [self login:^(NSString *error) {
            if (error) return done(nil, error);
            [self api:path method:method body:body retry:NO done:done];
        }];
    }
    path = [path stringByReplacingOccurrencesOfString:@"{uid}" withString:self.userId];
    NSMutableDictionary *h = [[self authHeaders] mutableCopy];
    h[@"Accept"] = @"application/json";
    NSData *data = nil;
    if (body) {
        h[@"Content-Type"] = @"application/json";
        data = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    }
    [IBHTTP request:[[self server] stringByAppendingString:path] method:method ?: @"GET" headers:h body:data
         completion:^(IBHTTPResponse *resp, NSError *error) {
        if (resp.status == 401 && retry) {
            [IBSettings update:@{@"jellyfinToken": @""}];
            return [self api:path method:method body:body retry:NO done:done];
        }
        if (error) return done(nil, [NSString stringWithFormat:@"Jellyfin: %@", error.localizedDescription]);
        done([resp json] ?: @{}, nil);
    }];
}

/* ---------------- images & items ---------------- */

+ (NSString *)image:(NSDictionary *)item wide:(BOOL)wide {
    NSString *server = [self server];
    NSDictionary *tags = IBDict(item[@"ImageTags"]);
    NSString *(^url)(NSString *, NSString *, NSString *) = ^(NSString *itemId, NSString *type, NSString *tag) {
        return [NSString stringWithFormat:@"%@/Items/%@/Images/%@?%@=%d&quality=80%@", server, itemId, type,
                wide ? @"maxWidth" : @"maxHeight", wide ? 480 : 420, tag ? [@"&tag=" stringByAppendingString:tag] : @""];
    };
    if (wide) {
        if (tags[@"Thumb"]) return url(item[@"Id"], @"Thumb", tags[@"Thumb"]);
        if ([item[@"Type"] isEqual:@"Episode"] && tags[@"Primary"]) return url(item[@"Id"], @"Primary", tags[@"Primary"]);
        if (IBArray(item[@"BackdropImageTags"]).count) return url(item[@"Id"], @"Backdrop", IBArray(item[@"BackdropImageTags"])[0]);
        if (IBString(item[@"ParentThumbItemId"])) return url(item[@"ParentThumbItemId"], @"Thumb", IBString(item[@"ParentThumbImageTag"]));
        if (IBString(item[@"ParentBackdropItemId"])) return url(item[@"ParentBackdropItemId"], @"Backdrop", nil);
    }
    if (tags[@"Primary"]) return url(item[@"Id"], @"Primary", tags[@"Primary"]);
    if (IBString(item[@"SeriesPrimaryImageTag"])) return url(item[@"SeriesId"], @"Primary", item[@"SeriesPrimaryImageTag"]);
    if (IBString(item[@"AlbumPrimaryImageTag"])) return url(item[@"AlbumId"], @"Primary", item[@"AlbumPrimaryImageTag"]);
    return nil;
}

+ (NSString *)subtitleFor:(NSDictionary *)item {
    NSString *type = IBString(item[@"Type"]);
    if ([type isEqual:@"Episode"]) {
        return [NSString stringWithFormat:@"%@ • S%@E%@", IBString(item[@"SeriesName"]) ?: @"",
                IBString(item[@"ParentIndexNumber"]) ?: @"?", IBString(item[@"IndexNumber"]) ?: @"?"];
    }
    if ([type isEqual:@"Audio"]) return [IBArray(item[@"Artists"]) componentsJoinedByString:@", "];
    if ([type isEqual:@"MusicAlbum"]) return IBString(item[@"AlbumArtist"]);
    if (item[@"ProductionYear"]) return IBString(item[@"ProductionYear"]);
    return nil;
}

+ (IBShape)shapeFor:(NSDictionary *)item {
    NSString *type = IBString(item[@"Type"]);
    if ([type isEqual:@"Episode"] || [type isEqual:@"Video"] || [type isEqual:@"CollectionFolder"] ||
        [type isEqual:@"UserView"] || [type isEqual:@"Folder"] || [type isEqual:@"TvChannel"]) return IBShapeWide;
    if ([type isEqual:@"MusicAlbum"] || [type isEqual:@"MusicArtist"] || [type isEqual:@"Playlist"]) return IBShapeSquare;
    if ([type isEqual:@"Audio"]) return IBShapeRow;
    return IBShapePoster;
}

+ (NSArray *)itemsFrom:(NSArray *)list shape:(IBShape)forced {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *it in list) {
        IBShape shape = forced ?: [self shapeFor:it];
        NSString *title = [it[@"Type"] isEqual:@"Episode"] && forced == IBShapeWide && it[@"SeriesName"]
                              ? IBString(it[@"SeriesName"]) : IBString(it[@"Name"]);
        NSString *subtitle = [it[@"Type"] isEqual:@"Episode"] && forced == IBShapeWide && it[@"SeriesName"]
                                 ? [NSString stringWithFormat:@"S%@E%@ • %@", IBString(it[@"ParentIndexNumber"]) ?: @"?",
                                    IBString(it[@"IndexNumber"]) ?: @"?", IBString(it[@"Name"]) ?: @""]
                                 : [self subtitleFor:it];
        IBItem *item = [[IBItem itemWithTitle:title subtitle:subtitle image:[self image:it wide:shape == IBShapeWide]
                                       action:^{ [self open:it siblings:list]; }] withShape:shape];
        item.progress = [IBDict(it[@"UserData"])[@"PlayedPercentage"] floatValue] / 100.0f;
        [items addObject:item];
    }
    return items;
}

/* ---------------- pages ---------------- */

static NSString *const kFields = @"Fields=PrimaryImageAspectRatio,ProductionYear,ParentId&EnableImageTypes=Primary,Thumb,Backdrop&ImageTypeLimit=1";

// Jellyfin's LAN discovery: UDP broadcast "Who is JellyfinServer?" to port 7359,
// servers answer with {"Address", "Id", "Name"}.
+ (void)discover:(void (^)(NSArray *servers))done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *found = [NSMutableArray array];
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd >= 0) {
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, sizeof on);
            struct timeval tv = {0, 300000};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            struct sockaddr_in to = {0};
            to.sin_len = sizeof to;
            to.sin_family = AF_INET;
            to.sin_port = htons(7359);
            to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
            const char *probe = "Who is JellyfinServer?";
            sendto(fd, probe, strlen(probe), 0, (struct sockaddr *)&to, sizeof to);
            CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + 2.5;
            while (CFAbsoluteTimeGetCurrent() < end) {
                char buf[2048];
                ssize_t n = recv(fd, buf, sizeof buf, 0);
                if (n <= 0) continue;
                id json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buf length:(NSUInteger)n] options:0 error:NULL];
                if (IBString(IBDict(json)[@"Address"]) && ![[found valueForKey:@"Address"] containsObject:IBDict(json)[@"Address"]]) {
                    [found addObject:json];
                }
            }
            close(fd);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(found); });
    });
}

+ (IBPage *)setupPage {
    return [IBPage pageWithTitle:@"Connect to Jellyfin" shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        [self discover:^(NSArray *servers) {
            NSMutableArray *items = [NSMutableArray array];
            void (^askLogin)(NSString *) = ^(NSString *url) {
                [IBSettings update:@{@"jellyfinURL": url, @"jellyfinToken": @"", @"jellyfinUserId": @""}];
                [[IBTV shared] promptText:@"Jellyfin user name" initial:[IBSettings get:@"jellyfinUser"] secure:NO done:^(NSString *user) {
                    [IBSettings set:@"jellyfinUser" value:user];
                    [[IBTV shared] promptText:@"Jellyfin password" initial:@"" secure:YES done:^(NSString *pw) {
                        [IBSettings set:@"jellyfinPassword" value:pw];
                        [self login:^(NSString *error) {
                            if (error) return [[IBTV shared] toast:error];
                            [[IBTV shared] popPage];
                            [[IBTV shared] pushPage:[self rootPage]];
                        }];
                    }];
                }];
            };
            if (servers.count) [items addObject:[IBItem header:@"Servers found on your network"]];
            for (NSDictionary *s in servers) {
                [items addObject:[[IBItem itemWithTitle:IBString(s[@"Name"]) ?: @"Jellyfin" subtitle:IBString(s[@"Address"]) image:nil
                                                 action:^{ askLogin(IBString(s[@"Address"])); }] withShape:IBShapeRow]];
            }
            [items addObject:[[IBItem itemWithTitle:@"Enter a server address…" subtitle:@"e.g. http://192.168.1.10:8096" image:nil action:^{
                [[IBTV shared] promptText:@"Jellyfin server address" initial:@"http://" secure:NO done:^(NSString *text) {
                    if (text.length > 7) askLogin(text);
                }];
            }] withShape:IBShapeRow]];
            done(items, servers.count ? nil : @"No Jellyfin server answered on this network — enter its address instead.");
        }];
    }];
}

+ (IBPage *)rootPage {
    if (![self server] || ![IBSettings get:@"jellyfinUser"].length) return [self setupPage];
    IBPage *page = [IBPage pageWithTitle:@"Jellyfin" shape:IBShapeWide loader:^(IBPage *p, IBPageDone done) {
        NSMutableArray *items = [NSMutableArray array];
        [items addObject:[[IBItem itemWithTitle:@"Search" subtitle:@"Movies, shows, music" image:nil action:^{
            [[IBTV shared] promptText:@"Search Jellyfin" initial:@"" secure:NO done:^(NSString *text) {
                if (text.length) [[IBTV shared] pushPage:[self searchPage:text]];
            }];
        }] withShape:IBShapeRow]];
        IBItem *account = [[IBItem itemWithTitle:@"Switch server or user" subtitle:[self server] image:nil
                                         action:^{ [[IBTV shared] pushPage:[self setupPage]]; }] withShape:IBShapeRow];
        [self api:[NSString stringWithFormat:@"/Users/{uid}/Items/Resume?Limit=12&MediaTypes=Video&%@", kFields] method:nil body:nil
             done:^(id resume, NSString *error) {
            if (error) {
                [items addObject:account];
                return done(items, error);
            }
            NSArray *r = IBArray(IBDict(resume)[@"Items"]);
            if (r.count) {
                [items addObject:[IBItem header:@"Continue watching"]];
                [items addObjectsFromArray:[self itemsFrom:r shape:IBShapeWide]];
            }
            [self api:[NSString stringWithFormat:@"/Shows/NextUp?UserId={uid}&Limit=12&%@", kFields] method:nil body:nil
                 done:^(id next, NSString *e2) {
                NSArray *n = IBArray(IBDict(next)[@"Items"]);
                if (n.count) {
                    [items addObject:[IBItem header:@"Next up"]];
                    [items addObjectsFromArray:[self itemsFrom:n shape:IBShapeWide]];
                }
                [self api:@"/Users/{uid}/Views" method:nil body:nil done:^(id views, NSString *e3) {
                    NSArray *v = IBArray(IBDict(views)[@"Items"]);
                    if (v.count) [items addObject:[IBItem header:@"Libraries"]];
                    for (NSDictionary *view in v) {
                        IBItem *i = [[IBItem itemWithTitle:IBString(view[@"Name"]) subtitle:nil image:[self image:view wide:YES]
                                                    action:^{ [[IBTV shared] pushPage:[self libraryPage:view]]; }] withShape:IBShapeWide];
                        i.color = IBColor(0x2A2350);
                        [items addObject:i];
                    }
                    [items addObject:[IBItem header:@"Account"]];
                    [items addObject:account];
                    done(items, e3);
                }];
            }];
        }];
    }];
    page.reloadOnShow = YES;
    return page;
}

+ (IBPage *)libraryPage:(NSDictionary *)view {
    NSString *type = IBString(view[@"CollectionType"]) ?: @"";
    NSString *include = [type isEqual:@"movies"] ? @"Movie" : [type isEqual:@"tvshows"] ? @"Series"
                      : [type isEqual:@"music"] ? @"MusicAlbum" : [type isEqual:@"boxsets"] ? @"BoxSet"
                      : [type isEqual:@"playlists"] ? @"Playlist" : nil;
    NSString *q = include
        ? [NSString stringWithFormat:@"ParentId=%@&IncludeItemTypes=%@&Recursive=true&SortBy=SortName&%@", view[@"Id"], include, kFields]
        : [NSString stringWithFormat:@"ParentId=%@&SortBy=IsFolder,SortName&%@", view[@"Id"], kFields];
    return [self listPage:IBString(view[@"Name"]) query:q start:0];
}

+ (IBPage *)listPage:(NSString *)title query:(NSString *)query start:(NSInteger)start {
    const NSInteger pageSize = 240;
    return [IBPage pageWithTitle:title shape:IBShapePoster loader:^(IBPage *p, IBPageDone done) {
        NSString *path = [NSString stringWithFormat:@"/Users/{uid}/Items?%@&StartIndex=%ld&Limit=%ld", query, (long)start, (long)pageSize];
        [self api:path method:nil body:nil done:^(id json, NSString *error) {
            NSArray *list = IBArray(IBDict(json)[@"Items"]);
            NSMutableArray *items = [[self itemsFrom:list shape:0] mutableCopy];
            NSInteger total = [IBDict(json)[@"TotalRecordCount"] integerValue];
            if (start + (NSInteger)list.count < total) {
                [items addObject:[[IBItem itemWithTitle:@"More…" subtitle:[NSString stringWithFormat:@"%ld more", (long)(total - start - list.count)]
                                                 image:nil action:^{
                    [[IBTV shared] pushPage:[self listPage:title query:query start:start + pageSize]];
                }] withShape:IBShapeRow]];
            }
            done(items, error);
        }];
    }];
}

+ (IBPage *)searchPage:(NSString *)text {
    NSString *q = [NSString stringWithFormat:@"searchTerm=%@&Recursive=true&IncludeItemTypes=Movie,Series,Episode,MusicAlbum,MusicArtist,Audio&%@",
                   [IBHTTP escape:text], kFields];
    return [self listPage:[NSString stringWithFormat:@"“%@”", text] query:q start:0];
}

+ (void)open:(NSDictionary *)item siblings:(NSArray *)siblings {
    NSString *type = IBString(item[@"Type"]);
    NSString *itemId = IBString(item[@"Id"]);
    IBTV *tv = [IBTV shared];
    if ([type isEqual:@"Series"]) {
        IBPage *seasons = [IBPage pageWithTitle:IBString(item[@"Name"]) shape:IBShapePoster loader:^(IBPage *p, IBPageDone done) {
            [self api:[NSString stringWithFormat:@"/Shows/%@/Seasons?UserId={uid}&%@", itemId, kFields] method:nil body:nil
                 done:^(id json, NSString *error) {
                done([self itemsFrom:IBArray(IBDict(json)[@"Items"]) shape:IBShapePoster], error);
            }];
        }];
        [tv pushPage:seasons];
    } else if ([type isEqual:@"Season"]) {
        NSString *seriesId = IBString(item[@"SeriesId"]);
        IBPage *eps = [IBPage pageWithTitle:[NSString stringWithFormat:@"%@ — %@", IBString(item[@"SeriesName"]) ?: @"", IBString(item[@"Name"])]
                                      shape:IBShapeWide loader:^(IBPage *p, IBPageDone done) {
            [self api:[NSString stringWithFormat:@"/Shows/%@/Episodes?SeasonId=%@&UserId={uid}&%@", seriesId, itemId, kFields]
               method:nil body:nil done:^(id json, NSString *error) {
                NSArray *list = IBArray(IBDict(json)[@"Items"]);
                NSMutableArray *items = [NSMutableArray array];
                for (NSDictionary *ep in list) {
                    IBItem *i = [IBItem itemWithTitle:[NSString stringWithFormat:@"%@. %@", IBString(ep[@"IndexNumber"]) ?: @"", IBString(ep[@"Name"])]
                                             subtitle:[self runtime:ep] image:[self image:ep wide:YES]
                                               action:^{ [self open:ep siblings:list]; }];
                    i.progress = [IBDict(ep[@"UserData"])[@"PlayedPercentage"] floatValue] / 100.0f;
                    [items addObject:i];
                }
                done(items, error);
            }];
        }];
        eps.reloadOnShow = YES;
        [tv pushPage:eps];
    } else if ([type isEqual:@"MusicAlbum"] || [type isEqual:@"Playlist"]) {
        [tv pushPage:[self tracksPage:item]];
    } else if ([type isEqual:@"MusicArtist"]) {
        [tv pushPage:[self listPage:IBString(item[@"Name"])
                              query:[NSString stringWithFormat:@"ArtistIds=%@&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=ProductionYear,SortName&SortOrder=Descending&%@", itemId, kFields]
                              start:0]];
    } else if ([type isEqual:@"Audio"]) {
        NSArray *tracks = [siblings filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Audio'"]];
        NSUInteger idx = [tracks indexOfObject:item];
        [tv playQueue:[self audioQueue:tracks] index:idx == NSNotFound ? 0 : (NSInteger)idx];
    } else if ([item[@"IsFolder"] boolValue]) {
        [tv pushPage:[self listPage:IBString(item[@"Name"])
                              query:[NSString stringWithFormat:@"ParentId=%@&SortBy=IsFolder,SortName&%@", itemId, kFields] start:0]];
    } else {
        [tv pushPage:[self detailPage:item siblings:siblings]];
    }
}

+ (NSString *)runtime:(NSDictionary *)item {
    double ticks = [item[@"RunTimeTicks"] doubleValue];
    return ticks > 0 ? [NSString stringWithFormat:@"%.0f min", ticks / kTicks / 60] : nil;
}

+ (IBPage *)tracksPage:(NSDictionary *)album {
    NSString *albumId = IBString(album[@"Id"]);
    BOOL playlist = [album[@"Type"] isEqual:@"Playlist"];
    return [IBPage pageWithTitle:IBString(album[@"Name"]) shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        NSString *path = playlist
            ? [NSString stringWithFormat:@"/Playlists/%@/Items?UserId={uid}&%@", albumId, kFields]
            : [NSString stringWithFormat:@"/Users/{uid}/Items?ParentId=%@&SortBy=ParentIndexNumber,IndexNumber,SortName&IncludeItemTypes=Audio&Recursive=true&%@", albumId, kFields];
        [self api:path method:nil body:nil done:^(id json, NSString *error) {
            NSArray *tracks = IBArray(IBDict(json)[@"Items"]);
            NSArray *queue = [self audioQueue:tracks];
            NSMutableArray *items = [NSMutableArray array];
            if (tracks.count) {
                [items addObject:[[IBItem itemWithTitle:@"►  Play all" subtitle:[NSString stringWithFormat:@"%lu tracks", (unsigned long)tracks.count]
                                                 image:[self image:album wide:NO] action:^{
                    [[IBTV shared] playQueue:queue index:0];
                }] withShape:IBShapeRow]];
                [items addObject:[[IBItem itemWithTitle:@"Shuffle" subtitle:nil image:nil action:^{
                    NSMutableArray *shuffled = [queue mutableCopy];
                    for (NSUInteger i = shuffled.count; i > 1; i--) [shuffled exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((u_int32_t)i)];
                    [[IBTV shared] playQueue:shuffled index:0];
                }] withShape:IBShapeRow]];
            }
            for (NSUInteger i = 0; i < tracks.count; i++) {
                NSDictionary *t = tracks[i];
                [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"%@  %@", IBString(t[@"IndexNumber"]) ?: @"•", IBString(t[@"Name"])]
                                               subtitle:[self subtitleFor:t] image:nil action:^{
                    [[IBTV shared] playQueue:queue index:(NSInteger)i];
                }] withShape:IBShapeRow]];
            }
            done(items, error);
        }];
    }];
}

/* ---------------- playback ---------------- */

+ (NSDictionary *)deviceProfile {
    return [self deviceProfile:4000000];
}

+ (NSDictionary *)deviceProfile:(long)bitrate {
    BOOL sd = [IBTV shared].size.height <= 576;
    NSString *maxW = sd ? @"1024" : @"1280", *maxH = sd ? @"576" : @"720";
    NSMutableArray *subs = [NSMutableArray array];
    // Text subtitles come as a separate WebVTT file that iBox draws itself (the video
    // can then direct-play); picture subtitles are burned in by the server.
    for (NSString *f in @[@"srt", @"subrip", @"ass", @"ssa", @"vtt", @"webvtt", @"smi", @"ttml", @"mov_text"]) {
        [subs addObject:@{@"Format": f, @"Method": @"External"}];
    }
    for (NSString *f in @[@"pgssub", @"dvdsub", @"dvbsub", @"sub"]) {
        [subs addObject:@{@"Format": f, @"Method": @"Encode"}];
    }
    return @{
        @"Name": @"iBox (iPhone 4)",
        @"MaxStreamingBitrate": @(bitrate),
        @"MaxStaticBitrate": @8000000,
        @"MusicStreamingTranscodingBitrate": @192000,
        @"DirectPlayProfiles": @[
            @{@"Container": @"mp4,m4v,mov", @"Type": @"Video", @"VideoCodec": @"h264", @"AudioCodec": @"aac,mp3"},
            @{@"Container": @"mp3", @"Type": @"Audio", @"AudioCodec": @"mp3"},
            @{@"Container": @"m4a,aac", @"Type": @"Audio", @"AudioCodec": @"aac"},
        ],
        @"TranscodingProfiles": @[
            @{@"Container": @"ts", @"Type": @"Video", @"VideoCodec": @"h264", @"AudioCodec": @"aac", @"Protocol": @"hls",
              @"Context": @"Streaming", @"MaxAudioChannels": @"2", @"MinSegments": @"1", @"BreakOnNonKeyFrames": @YES},
            @{@"Container": @"mp3", @"Type": @"Audio", @"AudioCodec": @"mp3", @"Protocol": @"http",
              @"Context": @"Streaming", @"MaxAudioChannels": @"2"},
        ],
        @"CodecProfiles": @[
            @{@"Type": @"Video", @"Codec": @"h264", @"Conditions": @[
                @{@"Condition": @"EqualsAny", @"Property": @"VideoProfile", @"Value": @"main|baseline|constrained baseline", @"IsRequired": @NO},
                @{@"Condition": @"LessThanEqual", @"Property": @"VideoLevel", @"Value": @"31", @"IsRequired": @NO},
                @{@"Condition": @"LessThanEqual", @"Property": @"Width", @"Value": maxW, @"IsRequired": @NO},
                @{@"Condition": @"LessThanEqual", @"Property": @"Height", @"Value": maxH, @"IsRequired": @NO},
                @{@"Condition": @"LessThanEqual", @"Property": @"VideoBitDepth", @"Value": @"8", @"IsRequired": @NO},
                @{@"Condition": @"LessThanEqual", @"Property": @"VideoFramerate", @"Value": @"30", @"IsRequired": @NO},
            ]},
            @{@"Type": @"VideoAudio", @"Codec": @"aac,mp3", @"Conditions": @[
                @{@"Condition": @"LessThanEqual", @"Property": @"AudioChannels", @"Value": @"2", @"IsRequired": @NO},
            ]},
        ],
        @"SubtitleProfiles": subs,
        @"ContainerProfiles": @[],
        @"ResponseProfiles": @[],
    };
}

+ (void)report:(NSString *)event media:(IBMedia *)m position:(NSTimeInterval)pos paused:(BOOL)paused info:(NSDictionary *)info {
    if (!info[@"PlaySessionId"]) return;
    NSMutableDictionary *body = [@{@"ItemId": info[@"ItemId"], @"MediaSourceId": info[@"MediaSourceId"] ?: info[@"ItemId"],
                                   @"PlaySessionId": info[@"PlaySessionId"], @"PositionTicks": @((long long)(pos * kTicks)),
                                   @"IsPaused": @(paused), @"CanSeek": @YES, @"PlayMethod": info[@"PlayMethod"] ?: @"Transcode"} mutableCopy];
    NSString *path = @"/Sessions/Playing/Progress";
    if ([event isEqual:@"start"]) path = @"/Sessions/Playing";
    if ([event isEqual:@"stop"]) path = @"/Sessions/Playing/Stopped";
    if ([event isEqual:@"pause"]) body[@"EventName"] = paused ? @"pause" : @"unpause";
    [self api:path method:@"POST" body:body done:^(id json, NSString *error) {}];
    if ([event isEqual:@"stop"] && [info[@"PlayMethod"] isEqual:@"Transcode"]) {
        [self api:[NSString stringWithFormat:@"/Videos/ActiveEncodings?DeviceId=%@&PlaySessionId=%@", [IBSettings deviceId], info[@"PlaySessionId"]]
           method:@"DELETE" body:nil done:^(id json, NSString *error) {}];
    }
}

+ (NSString *)captionsURLFor:(NSDictionary *)stream itemId:(NSString *)itemId source:(NSString *)sourceId {
    NSString *delivery = IBString(stream[@"DeliveryUrl"]);
    NSString *url = delivery.length ? [[self server] stringByAppendingString:delivery]
        : [NSString stringWithFormat:@"%@/Videos/%@/%@/Subtitles/%@/0/Stream.vtt", [self server], itemId, sourceId ?: itemId, stream[@"Index"]];
    if ([url rangeOfString:@"api_key="].location == NSNotFound) {
        url = [url stringByAppendingFormat:@"%@api_key=%@", [url rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", [self token]];
    }
    return url;
}

+ (BOOL)isTextSubtitle:(NSDictionary *)stream {
    if (stream[@"IsTextSubtitleStream"]) return [stream[@"IsTextSubtitleStream"] boolValue];
    NSString *codec = [IBString(stream[@"Codec"]) lowercaseString] ?: @"";
    return ![@[@"pgssub", @"pgs", @"dvdsub", @"dvbsub", @"vobsub"] containsObject:codec];
}

+ (IBMedia *)mediaFor:(NSDictionary *)item audioIndex:(NSNumber *)audio subtitleIndex:(NSNumber *)subtitle {
    IBMedia *m = [IBMedia new];
    m.title = [item[@"Type"] isEqual:@"Episode"] ? [NSString stringWithFormat:@"%@ \u2014 %@", IBString(item[@"SeriesName"]), IBString(item[@"Name"])]
                                                 : IBString(item[@"Name"]);
    m.subtitle = [self subtitleFor:item];
    m.artworkURL = [self image:item wide:NO];
    NSString *itemId = IBString(item[@"Id"]);
    __block NSDictionary *info = @{@"ItemId": itemId};
    // Choices that the in-player options panel can change (then the item restarts).
    NSMutableDictionary *choice = [NSMutableDictionary dictionaryWithDictionary:@{@"bitrate": @4000000}];
    if (audio) choice[@"audio"] = audio;
    if (subtitle) choice[@"subtitle"] = subtitle;
    m.resolver = ^(IBMedia *media, IBResolveDone done) {
        long bitrate = [choice[@"bitrate"] longValue];
        NSMutableString *q = [NSMutableString stringWithFormat:@"/Items/%@/PlaybackInfo?UserId={uid}&IsPlayback=true&AutoOpenLiveStream=true&MaxStreamingBitrate=%ld", itemId, bitrate];
        if (choice[@"audio"]) [q appendFormat:@"&AudioStreamIndex=%@", choice[@"audio"]];
        if (choice[@"subtitle"]) [q appendFormat:@"&SubtitleStreamIndex=%@", choice[@"subtitle"]];
        [self api:q method:@"POST" body:@{@"DeviceProfile": [self deviceProfile:bitrate]} done:^(id json, NSString *error) {
            NSDictionary *src = [IBArray(IBDict(json)[@"MediaSources"]) firstObject];
            if (error || !src) return done(nil, error ?: @"Jellyfin returned no media source");
            NSString *session = IBString(IBDict(json)[@"PlaySessionId"]) ?: @"";
            NSString *url, *method;
            if (IBString(src[@"TranscodingUrl"])) {
                url = [[self server] stringByAppendingString:src[@"TranscodingUrl"]];
                method = @"Transcode";
            } else {
                // Jellyfin reports e.g. "mov,mp4,m4a,3gp,3g2,mj2"; AVPlayer needs one plain extension.
                NSString *container = [[IBString(src[@"Container"]) ?: @"mp4" componentsSeparatedByString:@","] firstObject];
                if ([@[@"mov", @"m4v", @"mp4", @"m4a", @"3gp"] containsObject:container]) container = @"mp4";
                url = [NSString stringWithFormat:@"%@/Videos/%@/stream.%@?Static=true&MediaSourceId=%@&PlaySessionId=%@&api_key=%@",
                       [self server], itemId, container, IBString(src[@"Id"]), session, [self token]];
                method = @"DirectPlay";
            }
            info = @{@"ItemId": itemId, @"MediaSourceId": IBString(src[@"Id"]) ?: itemId, @"PlaySessionId": session, @"PlayMethod": method};
            NSArray *streams = IBArray(src[@"MediaStreams"]);
            choice[@"streams"] = streams;
            choice[@"source"] = IBString(src[@"Id"]) ?: itemId;
            if (!choice[@"audio"] && src[@"DefaultAudioStreamIndex"]) choice[@"audio"] = src[@"DefaultAudioStreamIndex"];
            if (!choice[@"subtitle"] && src[@"DefaultSubtitleStreamIndex"]) choice[@"subtitle"] = src[@"DefaultSubtitleStreamIndex"];
            NSDictionary *sub = [[streams filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Subtitle' AND Index == %@", choice[@"subtitle"] ?: @(-99)]] firstObject];
            media.captionsURL = sub && [self isTextSubtitle:sub] ? [self captionsURLFor:sub itemId:itemId source:choice[@"source"]] : nil;
            media.note = [method isEqual:@"Transcode"] ? @"Transcoding" : @"Direct play";
            done(url, nil);
        }];
    };
    m.onEvent = ^(IBMedia *media, NSString *event, NSTimeInterval pos, BOOL paused) {
        [self report:event media:media position:pos paused:paused info:info];
    };
    m.options = ^NSArray *(IBMedia *media) {
        NSArray *streams = choice[@"streams"] ?: IBArray(item[@"MediaStreams"]);
        NSArray *audios = [streams filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Audio'"]];
        NSArray *subs = [streams filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Subtitle'"]];
        IBPlayer *player = [IBTV shared].player;
        NSMutableArray *rows = [NSMutableArray array];
        if (audios.count > 1) {
            NSArray *labels = [audios valueForKey:@"DisplayTitle"];
            NSUInteger sel = [[audios valueForKey:@"Index"] indexOfObject:choice[@"audio"] ?: @(-1)];
            [rows addObject:[IBOption optionWithTitle:@"Audio" choices:labels selected:sel == NSNotFound ? 0 : sel apply:^(NSInteger i) {
                choice[@"audio"] = audios[i][@"Index"];
                [player restartCurrent];
            }]];
        }
        if (subs.count) {
            NSMutableArray *labels = [NSMutableArray arrayWithObject:@"Off"];
            for (NSDictionary *st in subs) {
                [labels addObject:[NSString stringWithFormat:@"%@%@", IBString(st[@"DisplayTitle"]) ?: @"Subtitles",
                                   [self isTextSubtitle:st] ? @"" : @" (burned in)"]];
            }
            NSUInteger cur = [[subs valueForKey:@"Index"] indexOfObject:choice[@"subtitle"] ?: @(-99)];
            if (!media.captionsURL && cur != NSNotFound && [self isTextSubtitle:subs[cur]]) cur = NSNotFound;  // turned off
            [rows addObject:[IBOption optionWithTitle:@"Subtitles" choices:labels selected:cur == NSNotFound ? 0 : cur + 1 apply:^(NSInteger i) {
                NSDictionary *old = [[subs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Index == %@", choice[@"subtitle"] ?: @(-99)]] firstObject];
                BOOL burned = old && ![self isTextSubtitle:old];  // the running stream has them in the picture
                NSDictionary *st = i > 0 ? subs[i - 1] : nil;
                choice[@"subtitle"] = st ? st[@"Index"] : @(-1);
                if (burned || (st && ![self isTextSubtitle:st])) {
                    [player restartCurrent];  // the server has to (un)burn them
                } else {
                    [player setCaptionsURL:st ? [self captionsURLFor:st itemId:itemId source:choice[@"source"]] : nil];
                }
            }]];
        }
        NSArray *rates = @[@4000000, @2000000, @1000000, @500000];
        NSUInteger sel = [rates indexOfObject:choice[@"bitrate"]];
        [rows addObject:[IBOption optionWithTitle:@"Quality" choices:@[@"Best (4 Mbps)", @"2 Mbps", @"1 Mbps", @"0.5 Mbps"]
                                         selected:sel == NSNotFound ? 0 : sel apply:^(NSInteger i) {
            choice[@"bitrate"] = rates[i];
            [player restartCurrent];
        }]];
        return rows;
    };
    return m;
}

+ (NSArray *)audioQueue:(NSArray *)tracks {
    NSMutableArray *queue = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        NSString *itemId = IBString(t[@"Id"]);
        IBMedia *m = [IBMedia new];
        m.title = IBString(t[@"Name"]);
        m.subtitle = [self subtitleFor:t];
        m.artworkURL = [self image:t wide:NO];
        m.audioOnly = YES;
        NSString *session = [[NSUUID class] respondsToSelector:@selector(UUID)] ? [[NSUUID UUID] UUIDString] : itemId;
        m.url = [NSString stringWithFormat:@"%@/Audio/%@/universal?UserId=%@&DeviceId=%@&api_key=%@&Container=mp3,aac,m4a%%7Caac&AudioCodec=aac,mp3&TranscodingContainer=mp3&TranscodingProtocol=http&MaxStreamingBitrate=320000&PlaySessionId=%@",
                 [self server], itemId, [self userId], [IBSettings deviceId], [self token], session];
        NSDictionary *info = @{@"ItemId": itemId, @"PlaySessionId": session, @"PlayMethod": @"DirectStream"};
        m.onEvent = ^(IBMedia *media, NSString *event, NSTimeInterval pos, BOOL paused) {
            [self report:event media:media position:pos paused:paused info:info];
        };
        [queue addObject:m];
    }
    return queue;
}

+ (IBPage *)detailPage:(NSDictionary *)summary siblings:(NSArray *)siblings {
    NSString *itemId = IBString(summary[@"Id"]);
    NSMutableDictionary *state = [NSMutableDictionary dictionary];  // item, audio, subtitle
    IBPage *page = [IBPage pageWithTitle:IBString(summary[@"Name"]) shape:IBShapeRow loader:^(IBPage *p, IBPageDone done) {
        void (^build)(NSDictionary *) = ^(NSDictionary *item) {
            state[@"item"] = item;
            NSArray *streams = IBArray(item[@"MediaStreams"]);
            NSArray *audios = [streams filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Audio'"]];
            NSArray *subs = [streams filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == 'Subtitle'"]];
            if (!state[@"audio"]) {
                NSDictionary *def = [[audios filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"IsDefault == YES"]] firstObject] ?: audios.firstObject;
                state[@"audio"] = def ? def[@"Index"] : [NSNull null];
                NSDictionary *forced = [[subs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"IsForced == YES OR IsDefault == YES"]] firstObject];
                state[@"subtitle"] = forced ? forced[@"Index"] : @(-1);
            }
            NSNumber *audio = state[@"audio"] == [NSNull null] ? nil : state[@"audio"];
            NSNumber *subtitle = state[@"subtitle"];

            double posTicks = [IBDict(item[@"UserData"])[@"PlaybackPositionTicks"] doubleValue];
            NSArray *videoSiblings = [siblings filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Type == %@", item[@"Type"] ?: @""]];
            NSUInteger me = [[videoSiblings valueForKey:@"Id"] indexOfObject:itemId];
            void (^play)(NSTimeInterval) = ^(NSTimeInterval start) {
                NSMutableArray *queue = [NSMutableArray array];
                IBMedia *first = [self mediaFor:item audioIndex:audio subtitleIndex:subtitle.intValue >= 0 ? subtitle : nil];
                first.startAt = start;
                [queue addObject:first];
                // Episodes keep playing through the rest of the season.
                if ([item[@"Type"] isEqual:@"Episode"] && me != NSNotFound) {
                    for (NSUInteger i = me + 1; i < videoSiblings.count; i++) {
                        [queue addObject:[self mediaFor:videoSiblings[i] audioIndex:nil subtitleIndex:nil]];
                    }
                }
                [[IBTV shared] playQueue:queue index:0];
            };

            NSMutableArray *items = [NSMutableArray array];
            NSString *art = [self image:item wide:NO];
            if (posTicks > 0) {
                [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"►  Resume from %@", IBFormatTime(posTicks / kTicks)]
                                               subtitle:nil image:art action:^{ play(posTicks / kTicks); }] withShape:IBShapeRow]];
            }
            [items addObject:[[IBItem itemWithTitle:posTicks > 0 ? @"►  Play from the beginning" : @"►  Play"
                                           subtitle:[self runtime:item] image:posTicks > 0 ? nil : art
                                             action:^{ play(0); }] withShape:IBShapeRow]];
            if (audios.count > 1) {
                NSDictionary *cur = [[audios filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Index == %@", audio ?: @(-1)]] firstObject];
                [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"Audio: %@", IBString(cur[@"DisplayTitle"]) ?: @"Default"]
                                               subtitle:@"OK to change" image:nil action:^{
                    NSUInteger i = [audios indexOfObject:cur];
                    state[@"audio"] = audios[(i == NSNotFound ? 0 : i + 1) % audios.count][@"Index"];
                    [[IBTV shared] reloadTopPage];
                }] withShape:IBShapeRow]];
            }
            if (subs.count) {
                NSDictionary *cur = [[subs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"Index == %@", subtitle]] firstObject];
                [items addObject:[[IBItem itemWithTitle:[NSString stringWithFormat:@"Subtitles: %@", IBString(cur[@"DisplayTitle"]) ?: @"Off"]
                                               subtitle:@"OK to change (also in the player: press Down)" image:nil action:^{
                    NSUInteger i = cur ? [subs indexOfObject:cur] : NSNotFound;
                    NSUInteger next = i == NSNotFound ? 0 : i + 1;
                    state[@"subtitle"] = next < subs.count ? subs[next][@"Index"] : @(-1);
                    [[IBTV shared] reloadTopPage];
                }] withShape:IBShapeRow]];
            }
            NSString *overview = IBString(item[@"Overview"]);
            if (overview.length) {
                [items addObject:[IBItem header:@"About"]];
                [items addObject:[[IBItem itemWithTitle:overview subtitle:[NSString stringWithFormat:@"%@%@",
                                                                          IBString(item[@"ProductionYear"]) ?: @"",
                                                                          item[@"OfficialRating"] ? [@"  •  " stringByAppendingString:item[@"OfficialRating"]] : @""]
                                                 image:nil action:nil] withShape:IBShapeRow]];
            }
            done(items, nil);
        };
        if (state[@"item"]) return build(state[@"item"]);
        [self api:[NSString stringWithFormat:@"/Users/{uid}/Items/%@?Fields=MediaStreams,Overview,ProductionYear", itemId]
           method:nil body:nil done:^(id json, NSString *error) {
            if (error) return done(nil, error);
            build(IBDict(json));
        }];
    }];
    return page;
}

@end
