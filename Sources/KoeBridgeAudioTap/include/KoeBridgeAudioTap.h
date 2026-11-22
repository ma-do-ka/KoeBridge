#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KBTapResult) {
    KBTapResultInstalled,
    KBTapResultFormatMismatch,
    KBTapResultUnknownException
};

FOUNDATION_EXPORT KBTapResult KBInstallInputTap(AVAudioNode *node, AVAudioFormat *format,
                                                AVAudioNodeTapBlock block);

FOUNDATION_EXPORT AVAudioEngine * _Nullable KBCreateMicrophoneEngine(void);
FOUNDATION_EXPORT BOOL KBPrepareMicrophoneEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT BOOL KBStopMicrophoneEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSNumber * _Nullable KBReadMicrophoneEngineRunning(AVAudioEngine *engine);
FOUNDATION_EXPORT BOOL KBRemoveInputTap(AVAudioNode *node);

NS_ASSUME_NONNULL_END
