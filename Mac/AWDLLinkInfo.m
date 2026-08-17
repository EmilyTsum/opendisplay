#import "AWDLLinkInfo.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static id _Nullable ODObjectGetterWithError(id object, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSError *__autoreleasing error = nil;
    id (*send)(id, SEL, NSError *__autoreleasing *) = (void *)objc_msgSend;
    id value = send(object, selector, &error);
    return error == nil ? value : nil;
}

static NSNumber * _Nullable ODNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        if ([scanner scanDouble:&number]) return @(number);
    }
    return nil;
}

NSDictionary<NSString *, id> * _Nullable ODCopyAWDLLinkInfo(void) {
    static void *coreWiFi = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coreWiFi = dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi",
                          RTLD_LAZY | RTLD_LOCAL);
    });
    if (!coreWiFi) return nil;

    @try {
        Class cls = NSClassFromString(@"CWFApple80211");
        if (!cls) return nil;
        id (*allocSend)(id, SEL) = (void *)objc_msgSend;
        id allocated = allocSend((id)cls, sel_registerName("alloc"));
        id (*initSend)(id, SEL, id) = (void *)objc_msgSend;
        id radio = initSend(allocated, sel_registerName("initWithInterfaceName:"), @"awdl0");
        if (!radio) return nil;

        NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];

        id channelObject = ODObjectGetterWithError(radio, "channel:");
        if (channelObject) {
            SEL channelSelector = sel_registerName("channel");
            SEL bandSelector = sel_registerName("band");
            SEL widthSelector = sel_registerName("width");
            if ([channelObject respondsToSelector:channelSelector]) {
                unsigned long long (*send)(id, SEL) = (void *)objc_msgSend;
                unsigned long long channel = send(channelObject, channelSelector);
                if (channel > 0 && channel <= NSIntegerMax) result[@"channel"] = @((NSInteger)channel);
            }
            if ([channelObject respondsToSelector:bandSelector]) {
                unsigned (*send)(id, SEL) = (void *)objc_msgSend;
                result[@"band"] = @(send(channelObject, bandSelector));
            }
            if ([channelObject respondsToSelector:widthSelector]) {
                int (*send)(id, SEL) = (void *)objc_msgSend;
                int width = send(channelObject, widthSelector);
                if (width > 0) result[@"widthMHz"] = @(width);
            }
            result[@"channelDescription"] = channelObject.description ?: @"";
        }

        struct { const char *selector; NSString *key; } numberGetters[] = {
            { "txRate:", @"txRateMbps" },
            { "rxRate:", @"rxRateMbps" },
            { "maxLinkSpeed:", @"maxLinkMbps" },
            { "MCSIndex:", @"mcs" },
            { "RSSI:", @"rssi" },
        };
        for (size_t i = 0; i < sizeof(numberGetters) / sizeof(numberGetters[0]); i++) {
            NSNumber *number = ODNumber(ODObjectGetterWithError(radio, numberGetters[i].selector));
            if (number) result[numberGetters[i].key] = number;
        }

        id phy = ODObjectGetterWithError(radio, "activePHYMode:");
        if (phy) {
            NSNumber *number = ODNumber(phy);
            if (number) result[@"phyMode"] = number;
            result[@"phyDescription"] = phy.description ?: @"";
        }

        id master = ODObjectGetterWithError(radio, "AWDLMasterChannel:");
        if (NSNumber *number = ODNumber(master)) result[@"masterChannel"] = number;
        id secondary = ODObjectGetterWithError(radio, "AWDLSecondaryMasterChannel:");
        if (NSNumber *number = ODNumber(secondary)) result[@"secondaryMasterChannel"] = number;

        id sequence = ODObjectGetterWithError(radio, "AWDLSyncChannelSequence:");
        if (sequence) result[@"channelSequence"] = sequence.description ?: @"";

        return result.count > 0 ? result : nil;
    } @catch (__unused NSException *exception) {
        // Private diagnostics must never affect streaming. API drift simply
        // means the AWDL detail row disappears on that OS build.
        return nil;
    }
}
