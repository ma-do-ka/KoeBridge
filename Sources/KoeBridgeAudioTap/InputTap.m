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
