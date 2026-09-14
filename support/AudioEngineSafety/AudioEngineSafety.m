#import "AudioEngineSafety.h"
#import <math.h>

static NSError *MMAudioException(NSException *exception) {
    // Do not hide unrelated programming errors behind a microphone failure.
    if (![exception.name isEqualToString:@"com.apple.coreaudio.avfaudio"]) {
        @throw exception;
    }
    return [NSError errorWithDomain:@"com.muckstack.myman.audio-engine" code:1
                          userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Microphone setup failed."}];
}

NSError *MMSetVoiceProcessing(AVAudioEngine *engine, BOOL enabled) {
    @try {
        NSError *error = nil;
        [engine.inputNode setVoiceProcessingEnabled:enabled error:&error];
        return error;
    } @catch (NSException *exception) {
        return MMAudioException(exception);
    }
}

NSError *MMPrepareAudioEngine(AVAudioEngine *engine) {
    @try {
        [engine.inputNode outputFormatForBus:0];
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return MMAudioException(exception);
    }
}

NSError *MMInstallInputTap(AVAudioEngine *engine, AVAudioNodeTapBlock block) {
    @try {
        AVAudioInputNode *input = engine.inputNode;
        AVAudioFormat *format = [input outputFormatForBus:0];
        if (!isfinite(format.sampleRate) || format.sampleRate <= 0 || format.channelCount == 0) {
            return [NSError errorWithDomain:@"com.muckstack.myman.audio-engine" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"The microphone has no usable input format. Reconnect it and try again."}];
        }
        [input installTapOnBus:0 bufferSize:4096 format:nil block:block];
        return nil;
    } @catch (NSException *exception) {
        return MMAudioException(exception);
    }
}

NSError *MMStartAudioEngine(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if ([engine startAndReturnError:&error]) { return nil; }
        return error ?: [NSError errorWithDomain:@"com.muckstack.myman.audio-engine" code:3
                                       userInfo:@{NSLocalizedDescriptionKey: @"The microphone could not start."}];
    } @catch (NSException *exception) {
        return MMAudioException(exception);
    }
}
