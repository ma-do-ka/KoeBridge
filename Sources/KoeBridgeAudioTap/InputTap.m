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

BOOL KBStartMicrophoneEngine(AVAudioEngine *engine, NSError **error) {
    @try { return [engine startAndReturnError:error]; }
    @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:exception.name ?: @"com.koebridge.audio-tap"
                                         code:-10814
                                     userInfo:@{NSLocalizedDescriptionKey:
                exception.reason ?: @"AVAudioEngine start raised an exception"}];
        }
        return NO;
    }
}

NSNumber *KBReadMicrophoneEngineRunning(AVAudioEngine *engine) {
    @try { return @(engine.isRunning); }
    @catch (NSException *exception) { return nil; }
}

BOOL KBRemoveInputTap(AVAudioNode *node) {
    @try { [node removeTapOnBus:0]; return YES; }
    @catch (NSException *exception) { return NO; }
}

AVAudioFormat *KBReadMicrophoneNodeFormat(AVAudioNode *node, BOOL input, AVAudioNodeBus bus) {
    @try { return input ? [node inputFormatForBus:bus] : [node outputFormatForBus:bus]; }
    @catch (NSException *exception) { return nil; }
}

AVAudioEngine *KBReadMicrophoneNodeEngine(AVAudioNode *node) {
    @try { return node.engine; }
    @catch (NSException *exception) { return nil; }
}

NSNumber *KBReadMicrophoneNodeOutputCount(AVAudioNode *node) {
    @try { return @(node.numberOfOutputs); }
    @catch (NSException *exception) { return nil; }
}

NSArray<AVAudioConnectionPoint *> *KBReadMicrophoneEngineConnectionPoints(
        AVAudioEngine *engine, AVAudioNode *node, AVAudioNodeBus bus) {
    @try { return [engine outputConnectionPointsForNode:node outputBus:bus]; }
    @catch (NSException *exception) { return nil; }
}

AudioUnit KBReadMicrophoneInputNodeAudioUnit(AVAudioInputNode *node) {
    @try { return node.audioUnit; }
    @catch (NSException *exception) { return NULL; }
}

AVAudioInputNode *KBReadMicrophoneEngineInputNode(AVAudioEngine *engine) {
    @try { return engine.inputNode; }
    @catch (NSException *exception) { return nil; }
}
