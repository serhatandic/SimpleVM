#import <Foundation/Foundation.h>

typedef struct _SpicePlaybackChannel SpicePlaybackChannel;

NS_ASSUME_NONNULL_BEGIN

@interface CSAudioPlayback : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithChannel:(SpicePlaybackChannel *)channel
    NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
