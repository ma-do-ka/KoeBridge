#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

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
FOUNDATION_EXPORT BOOL KBStartMicrophoneEngine(AVAudioEngine *engine,
                                               NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSNumber * _Nullable KBReadMicrophoneEngineRunning(AVAudioEngine *engine);
FOUNDATION_EXPORT BOOL KBRemoveInputTap(AVAudioNode *node);

// Read-only graph accessors, boxed the same way: a thrown NSException is
// returned as nil rather than aborting the process on the caller's queue.
FOUNDATION_EXPORT AVAudioFormat * _Nullable KBReadMicrophoneNodeFormat(AVAudioNode *node,
                                                                      BOOL input,
                                                                      AVAudioNodeBus bus);
FOUNDATION_EXPORT AVAudioEngine * _Nullable KBReadMicrophoneNodeEngine(AVAudioNode *node);
FOUNDATION_EXPORT NSNumber * _Nullable KBReadMicrophoneNodeOutputCount(AVAudioNode *node);
FOUNDATION_EXPORT NSArray<AVAudioConnectionPoint *> * _Nullable
    KBReadMicrophoneEngineConnectionPoints(AVAudioEngine *engine, AVAudioNode *node,
                                           AVAudioNodeBus bus);
FOUNDATION_EXPORT AudioUnit _Nullable KBReadMicrophoneInputNodeAudioUnit(AVAudioInputNode *node);
FOUNDATION_EXPORT AVAudioInputNode * _Nullable KBReadMicrophoneEngineInputNode(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
