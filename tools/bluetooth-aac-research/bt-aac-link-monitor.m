#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static id controllerInfo(NSError **error) {
    Class cls = NSClassFromString(@"CBController");
    SEL sel = NSSelectorFromString(@"controllerInfoAndReturnError:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    id (*send)(id, SEL, NSError **) = (void *)objc_msgSend;
    return send((id)cls, sel, error);
}

static NSString *codecLabel(NSInteger codec) {
    // Bluetooth SIG A2DP Audio Codec ID: 0=SBC, 2=MPEG-2/4 AAC.
    switch (codec) {
        case 0: return @"SBC";
        case 2: return @"AAC";
        default: return [NSString stringWithFormat:@"codec-%ld", (long)codec];
    }
}

static id value(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/BluetoothAudio.framework/BluetoothAudio", RTLD_NOW);
        if (!h) {
            fprintf(stderr, "BluetoothAudio dlopen failed: %s\n", dlerror());
            return 2;
        }
        int seconds = argc > 1 ? MAX(1, atoi(argv[1])) : 1;
        for (int tick = 0; tick < seconds; tick++) {
            NSError *error = nil;
            id info = controllerInfo(&error);
            NSArray *items = value(info, @"audioLinkQualityArray");
            NSDate *now = [NSDate date];
            if (!info) {
                printf("%s controllerInfo unavailable error=%s\n",
                       now.description.UTF8String, error.description.UTF8String ?: "none");
            } else if (items.count == 0) {
                printf("%s no active Bluetooth audio link-quality entries\n", now.description.UTF8String);
            } else {
                for (id q in items) {
                    NSInteger codec = [value(q,@"codecType") integerValue];
                    printf("%s device=%s codec=%ld(%s) bitrate=%u kbps rssi=%ld dBm snr=%ld dB noise90=%ld retransmit=%.3f jitter=%.4f s band=%ld aos=%ld\n",
                           now.description.UTF8String,
                           [[value(q,@"deviceName") description] UTF8String] ?: "?",
                           (long)codec, codecLabel(codec).UTF8String,
                           [value(q,@"bitRate") unsignedIntValue],
                           (long)[value(q,@"rssiAverage") integerValue],
                           (long)[value(q,@"signalToNoiseRatio") integerValue],
                           (long)[value(q,@"noiseFloor90") integerValue],
                           [value(q,@"retransmitRate") doubleValue],
                           [value(q,@"jitterBufferSeconds") doubleValue],
                           (long)[value(q,@"btBand") integerValue],
                           (long)[value(q,@"aosState") integerValue]);
                }
            }
            fflush(stdout);
            if (tick + 1 < seconds) [NSThread sleepForTimeInterval:1.0];
        }
    }
    return 0;
}
