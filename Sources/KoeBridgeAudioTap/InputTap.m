#import "KoeBridgeAudioTap.h"

KBTapResult KBInstallInputTap(AVAudioNode *node, AVAudioFormat *format, AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:0 bufferSize:1024 format:format block:block];
        return KBTapResultInstalled;
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:@"com.apple.coreaudio.avfaudio"] &&
            [exception.reason hasPrefix:@"Failed to create tap due to format mismatch"]) {
            return KBTapResultFormatMismatch;
        }
        return KBTapResultUnknownException;
    }
}

AVAudioEngine *KBCreateMicrophoneEngine(void) {
    @try { return [[AVAudioEngine alloc] init]; }
    @catch (NSException *exception) { return nil; }
}

BOOL KBPrepareMicrophoneEngine(AVAudioEngine *engine) {
    @try { [engine prepare]; return YES; }
    @catch (NSException *exception) { return NO; }
}

BOOL KBStopMicrophoneEngine(AVAudioEngine *engine) {
    @try { [engine stop]; return !engine.isRunning; }
    @catch (NSException *exception) { return NO; }
}

BOOL KBRemoveInputTap(AVAudioNode *node) {
    @try { [node removeTapOnBus:0]; return YES; }
    @catch (NSException *exception) { return NO; }
}
