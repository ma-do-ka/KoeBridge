#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware-free native test doubles, linked only by test targets.
@interface KBFakeTapNode : AVAudioMixerNode
@property(nonatomic) BOOL switchDeviceDuringInstall;
@property(nonatomic) BOOL raiseUnknown;
@property(nonatomic) BOOL raiseOnRemove;
@property(nonatomic, readonly) unsigned removes;
@property(nonatomic, nullable) AVAudioFormat *fixtureHardware;
@property(nonatomic, nullable) AVAudioFormat *fixtureClient;
@property(nonatomic, nullable, copy) void (^afterInstall)(void);
@property(nonatomic, nullable, copy) void (^afterHardwareRead)(void);
@property(nonatomic) unsigned currentDeviceID;
@property(nonatomic, readonly) unsigned installs;
@property(nonatomic, readonly, nullable) AVAudioFormat *requested;
@property(nonatomic, readonly, nullable) AVAudioNodeTapBlock partialTap;
@end

@interface KBFakeMicrophoneEngine : AVAudioEngine
@property(nonatomic) BOOL fixtureRunning;
@property(nonatomic) BOOL raiseOnPrepare;
@property(nonatomic) BOOL failStart;
@property(nonatomic) BOOL raiseOnStop;
@property(nonatomic) BOOL remainRunningAfterStop;
@property(nonatomic, readonly) unsigned prepares;
@property(nonatomic, readonly) unsigned starts;
@property(nonatomic, readonly) unsigned stops;
@property(nonatomic, nullable, copy) void (^afterStart)(void);
@end

NS_ASSUME_NONNULL_END
