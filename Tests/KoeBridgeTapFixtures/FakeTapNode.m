#import "KoeBridgeTapFixtures.h"

@implementation KBFakeTapNode
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                 format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    _installs++;
    _requested = format;
    _partialTap = [block copy];
    if (_raiseUnknown) {
        [NSException raise:NSInternalInconsistencyException format:@"Unexpected graph state"];
    }
    if (_switchDeviceDuringInstall) {
        _currentDeviceID = 173;
        if (format.sampleRate != 44100 || format.channelCount != 2) {
            [NSException raise:@"com.apple.coreaudio.avfaudio"
                        format:@"Failed to create tap due to format mismatch (fixture)"];
        }
    }
}
@end
