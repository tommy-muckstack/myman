#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// AVFAudio can raise Objective-C exceptions that Swift do/catch cannot handle.
// Keep the exception boundary entirely within the Objective-C hardware call.
NSError * _Nullable MMSetVoiceProcessing(AVAudioEngine *engine, BOOL enabled);
NSError * _Nullable MMPrepareAudioEngine(AVAudioEngine *engine);
NSError * _Nullable MMInstallInputTap(AVAudioEngine *engine, AVAudioNodeTapBlock block);
NSError * _Nullable MMStartAudioEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
