#import <UIKit/UIKit.h>
#import "IBCore.h"
#import "IBTV.h"

@interface IBPlayer : NSObject
@property (nonatomic, readonly) IBMedia *currentMedia;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL visible;
@property (nonatomic, readonly) NSArray *queue;
@property (nonatomic, readonly) NSInteger index;

- (void)layoutInView:(UIView *)parent;
- (void)playQueue:(NSArray *)queue index:(NSInteger)index inView:(UIView *)parent;
- (void)enqueue:(NSArray *)media;
- (BOOL)handleKey:(IBKey)key;  // YES when consumed
- (void)togglePause;
- (void)stop;
- (void)next;
- (void)previous;
- (void)seekBy:(NSTimeInterval)delta;
- (void)seekTo:(NSTimeInterval)seconds;
- (void)show;
- (void)restartCurrent;                    // re-resolve the current item and resume where it was
- (void)setCaptionsURL:(NSString *)url;    // subtitles drawn by iBox (WebVTT/SRT), nil = off
@property (nonatomic, readonly) BOOL optionsOpen;
- (NSDictionary *)state;
@end
