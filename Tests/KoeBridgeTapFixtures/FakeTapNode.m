#import "KoeBridgeTapFixtures.h"

@implementation KBFakeTapNode
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                 format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    _installs++;
    _requested = format;
    _partialTap = [block copy];
    if (_afterRetainTap != nil) { _afterRetainTap(); }
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
    if (_fixtureClient != nil) { _fixtureClient = format; }
    if (_afterInstall != nil) { _afterInstall(); }
}

- (AVAudioFormat *)inputFormatForBus:(AVAudioNodeBus)bus {
    AVAudioFormat *format = _fixtureHardware ?: [super inputFormatForBus:bus];
    if (_afterHardwareRead != nil) { _afterHardwareRead(); }
    return format;
}

- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus {
    return _fixtureClient ?: [super outputFormatForBus:bus];
}

- (void)removeTapOnBus:(AVAudioNodeBus)bus {
    _removes++;
    if (_raiseOnRemove) {
        [NSException raise:NSInternalInconsistencyException format:@"Fixture remove failed"];
    }
    _partialTap = nil;
}
@end

@implementation KBFakeMicrophoneEngine {
    BOOL _didReadStopResult;
}
- (BOOL)isRunning {
    if (_stops > 0 && _didReadStopResult) {
        if (_raiseOnIndependentStopReadback) {
            [NSException raise:NSInternalInconsistencyException format:@"Fixture independent readback failed"];
        }
        if (_runningOnIndependentStopReadback) { return YES; }
    }
    if (_stops > 0) { _didReadStopResult = YES; }
    if (_stops > 0 && _raiseOnRunningReadAfterStop) {
        [NSException raise:NSInternalInconsistencyException format:@"Fixture running readback failed"];
    }
    return _fixtureRunning;
}

- (void)prepare {
    _prepares++;
    if (_raiseOnPrepare) {
        [NSException raise:NSInternalInconsistencyException format:@"Fixture prepare failed"];
    }
}

- (BOOL)startAndReturnError:(NSError **)outError {
    _starts++;
    if (_failStart) {
        if (outError != NULL) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:nil];
        return NO;
    }
    _fixtureRunning = YES;
    if (_afterStart != nil) { _afterStart(); }
    return YES;
}

- (void)stop {
    _stops++;
    _didReadStopResult = NO;
    if (_raiseOnStop) {
        [NSException raise:NSInternalInconsistencyException format:@"Fixture stop failed"];
    }
    _fixtureRunning = _remainRunningAfterStop;
    if (_raiseAfterStopping) {
        [NSException raise:NSInternalInconsistencyException format:@"Fixture stop returned no proof"];
    }
}
@end
