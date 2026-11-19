#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KBTapResult) {
    KBTapResultInstalled,
    KBTapResultFormatMismatch,
    KBTapResultUnknownException
};

FOUNDATION_EXPORT KBTapResult KBInstallInputTap(AVAudioNode *node, AVAudioFormat *format,
                                                AVAudioNodeTapBlock block);

NS_ASSUME_NONNULL_END
