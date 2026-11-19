#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware-free native test double, linked only by the self-test executable.
@interface KBFakeTapNode : AVAudioMixerNode
@property(nonatomic) BOOL switchDeviceDuringInstall;
@property(nonatomic) BOOL raiseUnknown;
@property(nonatomic) unsigned currentDeviceID;
@property(nonatomic, readonly) unsigned installs;
@property(nonatomic, readonly, nullable) AVAudioFormat *requested;
@property(nonatomic, readonly, nullable) AVAudioNodeTapBlock partialTap;
@end

NS_ASSUME_NONNULL_END
