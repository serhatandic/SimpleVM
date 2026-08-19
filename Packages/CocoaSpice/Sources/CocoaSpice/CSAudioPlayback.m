#import "CSAudioPlayback.h"
#import "CSMain.h"

#import <AVFoundation/AVFoundation.h>
#import <spice-client.h>
#import <spice/enums.h>

@interface CSAudioPlayback ()

@property (nonatomic) SpicePlaybackChannel *channel;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, strong, nullable) AVAudioFormat *format;
@property (nonatomic) BOOL isPlaying;
@property (nonatomic) BOOL wantsPlayback;
@property (nonatomic) float playbackVolume;
@property (nonatomic) BOOL isMuted;
@property (nonatomic, strong) id engineConfigurationObserver;
@property (nonatomic) BOOL engineRecoveryScheduled;

- (void)startWithFormat:(gint)format
               channels:(gint)channels
              frequency:(gint)frequency;
- (void)startEngine;
- (void)scheduleEngineRecoveryAfter:(dispatch_time_t)delay;
- (void)appendAudio:(gpointer *)audio size:(gint)size;
- (void)stop;

@end

@implementation CSAudioPlayback

static void cs_playback_start(SpicePlaybackChannel *channel,
                              gint format,
                              gint channels,
                              gint frequency,
                              gpointer data)
{
    CSAudioPlayback *self = (__bridge CSAudioPlayback *)data;
    [self startWithFormat:format channels:channels frequency:frequency];
}

static void cs_playback_data(SpicePlaybackChannel *channel,
                             gpointer *audio,
                             gint size,
                             gpointer data)
{
    CSAudioPlayback *self = (__bridge CSAudioPlayback *)data;
    [self appendAudio:audio size:size];
}

static void cs_playback_stop(SpicePlaybackChannel *channel, gpointer data)
{
    CSAudioPlayback *self = (__bridge CSAudioPlayback *)data;
    [self stop];
}

static void cs_playback_volume_changed(GObject *object,
                                       GParamSpec *pspec,
                                       gpointer data)
{
    CSAudioPlayback *self = (__bridge CSAudioPlayback *)data;
    guint16 *volumes = NULL;
    guint channels = 0;
    g_object_get(object,
                 "volume", &volumes,
                 "nchannels", &channels,
                 NULL);
    if (channels > 0 && volumes) {
        self.playbackVolume = (float)volumes[0] / UINT16_MAX;
        self.player.volume = self.isMuted ? 0.0f : self.playbackVolume;
    }
}

static void cs_playback_mute_changed(GObject *object,
                                     GParamSpec *pspec,
                                     gpointer data)
{
    CSAudioPlayback *self = (__bridge CSAudioPlayback *)data;
    gboolean muted = FALSE;
    g_object_get(object, "mute", &muted, NULL);
    self.isMuted = muted;
    self.player.volume = muted ? 0.0f : self.playbackVolume;
}

- (instancetype)initWithChannel:(SpicePlaybackChannel *)channel
{
    self = [super init];
    if (self) {
        _channel = g_object_ref(channel);
        _engine = [[AVAudioEngine alloc] init];
        _player = [[AVAudioPlayerNode alloc] init];
        _playbackVolume = 1.0f;
        [_engine attachNode:_player];
        __weak CSAudioPlayback *weakSelf = self;
        _engineConfigurationObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:AVAudioEngineConfigurationChangeNotification
                        object:_engine
                         queue:nil
                    usingBlock:^(NSNotification *notification) {
            [CSMain.sharedInstance asyncWith:^{
                CSAudioPlayback *strongSelf = weakSelf;
                if (strongSelf.wantsPlayback &&
                    strongSelf.format &&
                    !strongSelf.engine.isRunning) {
                    [strongSelf scheduleEngineRecoveryAfter:
                        dispatch_time(DISPATCH_TIME_NOW,
                                      100 * NSEC_PER_MSEC)];
                }
            }];
        }];

        g_signal_connect(channel,
                         "playback-start",
                         G_CALLBACK(cs_playback_start),
                         (__bridge void *)self);
        g_signal_connect(channel,
                         "playback-data",
                         G_CALLBACK(cs_playback_data),
                         (__bridge void *)self);
        g_signal_connect(channel,
                         "playback-stop",
                         G_CALLBACK(cs_playback_stop),
                         (__bridge void *)self);
        g_signal_connect(channel,
                         "notify::volume",
                         G_CALLBACK(cs_playback_volume_changed),
                         (__bridge void *)self);
        g_signal_connect(channel,
                         "notify::mute",
                         G_CALLBACK(cs_playback_mute_changed),
                         (__bridge void *)self);
    }
    return self;
}

- (void)startWithFormat:(gint)format
               channels:(gint)channels
              frequency:(gint)frequency
{
    self.isPlaying = NO;
    if (format != SPICE_AUDIO_FMT_S16 || channels <= 0 || frequency <= 0) {
        g_warning("Unsupported SPICE audio format: %d", format);
        return;
    }

    self.format = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatInt16
                  sampleRate:(double)frequency
                    channels:(AVAudioChannelCount)channels
                 interleaved:YES];
    if (!self.format) {
        g_warning("Could not create the host audio format.");
        return;
    }

    self.wantsPlayback = YES;
    [self startEngine];
}

- (void)startEngine
{
    self.isPlaying = NO;
    [self.player stop];
    [self.engine stop];
    [self.engine disconnectNodeOutput:self.player];
    [self.engine connect:self.player
                      to:self.engine.mainMixerNode
                  format:self.format];
    [self.engine prepare];
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        g_warning("Could not start host audio output: %s",
                  error.localizedDescription.UTF8String);
        [self scheduleEngineRecoveryAfter:
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)];
        return;
    }
    [self.player play];
    self.isPlaying = YES;
    spice_playback_channel_set_delay(self.channel, 0);
}

- (void)scheduleEngineRecoveryAfter:(dispatch_time_t)delay
{
    if (self.engineRecoveryScheduled || !self.wantsPlayback) {
        return;
    }
    self.engineRecoveryScheduled = YES;
    __weak CSAudioPlayback *weakSelf = self;
    dispatch_after(
        delay,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            [CSMain.sharedInstance asyncWith:^{
                CSAudioPlayback *strongSelf = weakSelf;
                strongSelf.engineRecoveryScheduled = NO;
                if (strongSelf.wantsPlayback &&
                    strongSelf.format &&
                    !strongSelf.engine.isRunning) {
                    [strongSelf startEngine];
                }
            }];
        }
    );
}

- (void)appendAudio:(gpointer *)audio size:(gint)size
{
    if (!self.isPlaying ||
        !self.engine.isRunning ||
        !self.player.isPlaying ||
        !self.format ||
        !audio ||
        size <= 0) {
        return;
    }

    const NSUInteger bytesPerFrame =
        self.format.channelCount * sizeof(int16_t);
    const AVAudioFrameCount frameCount =
        (AVAudioFrameCount)((NSUInteger)size / bytesPerFrame);
    if (frameCount == 0) {
        return;
    }

    AVAudioPCMBuffer *buffer =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format
                                      frameCapacity:frameCount];
    if (!buffer) {
        return;
    }
    buffer.frameLength = frameCount;
    AudioBuffer *audioBuffer = &buffer.mutableAudioBufferList->mBuffers[0];
    const NSUInteger byteCount = frameCount * bytesPerFrame;
    memcpy(audioBuffer->mData, audio, byteCount);
    audioBuffer->mDataByteSize = (UInt32)byteCount;
    [self.player scheduleBuffer:buffer completionHandler:nil];
}

- (void)stop
{
    self.wantsPlayback = NO;
    self.isPlaying = NO;
    [self.player stop];
    [self.engine stop];
    [self.engine reset];
}

- (void)dealloc
{
    if (_engineConfigurationObserver) {
        [NSNotificationCenter.defaultCenter
            removeObserver:_engineConfigurationObserver];
        _engineConfigurationObserver = nil;
    }
    AVAudioPlayerNode *player = _player;
    AVAudioEngine *engine = _engine;
    SpicePlaybackChannel *channel = _channel;
    gpointer data = (__bridge void *)self;
    [CSMain.sharedInstance syncWith:^{
        [player stop];
        [engine stop];
        [engine reset];
        if (channel) {
            g_signal_handlers_disconnect_by_data(channel, data);
            g_object_unref(channel);
        }
    }];
    _channel = NULL;
}

@end
