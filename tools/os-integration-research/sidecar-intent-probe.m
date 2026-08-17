#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id call0(id obj, const char *name) {
    SEL sel=sel_registerName(name);
    return [obj respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(obj, sel) : nil;
}
static long callLong0(id obj, const char *name) {
    SEL sel=sel_registerName(name);
    return [obj respondsToSelector:sel] ? ((long(*)(id,SEL))objc_msgSend)(obj, sel) : -1;
}
static NSString *callString0(id obj, const char *sel) {
    id value = call0(obj, sel);
    return value ? [value description] : @"<nil>";
}
static void dumpState(id manager, NSString *reason) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSArray *devices = call0(manager, "devices") ?: @[];
    NSArray *connected = call0(manager, "connectedDevices") ?: @[];
    fprintf(stdout, "%.3f reason=%s devices=%lu connected=%lu\n", now,
            reason.UTF8String, (unsigned long)devices.count, (unsigned long)connected.count);
    for (id device in devices) {
        NSString *name = callString0(device, "name");
        NSString *ident = callString0(device, "identifier");
        NSString *model = callString0(device, "model");
        long status = callLong0(device, "status");
        BOOL isConnected = [connected containsObject:device];
        fprintf(stdout, "  name=%s id=%s model=%s status=%ld connected=%d\n",
                name.UTF8String, ident.UTF8String, model.UTF8String, status, isConnected);
    }
    fflush(stdout);
}
static void darwinCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    id manager = (__bridge id)observer;
    dumpState(manager, [NSString stringWithFormat:@"darwin:%@", (__bridge NSString *)name]);
}
int main(int argc, const char **argv) { @autoreleasepool {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/Versions/A/SidecarCore", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "SidecarCore dlopen failed: %s\n", dlerror()); return 1; }
    fprintf(stdout,"host=%s\n",[[NSProcessInfo processInfo].operatingSystemVersionString UTF8String]);
    Class cls = NSClassFromString(@"SidecarDisplayManager");
    if (!cls) { fprintf(stderr, "SidecarDisplayManager missing\n"); return 2; }
    id manager = call0((id)cls, "sharedManager");
    if (!manager) { fprintf(stderr, "sharedManager nil\n"); return 3; }

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(manager), darwinCallback,
                                    CFSTR(".com.apple.sidecar-display-agent.status"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(manager), darwinCallback,
                                    CFSTR("com.apple.sidecar-display-agent.status"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    double seconds = argc > 1 ? atof(argv[1]) : 60.0;
    dumpState(manager, @"start");
    NSTimeInterval end = [NSDate date].timeIntervalSince1970 + seconds;
    NSString *last = nil;
    while ([NSDate date].timeIntervalSince1970 < end) {
        NSArray *devices = call0(manager, "devices") ?: @[];
        NSArray *connected = call0(manager, "connectedDevices") ?: @[];
        NSMutableArray *parts = [NSMutableArray array];
        for (id device in devices) {
            [parts addObject:[NSString stringWithFormat:@"%@|%@|%ld|%d",
              callString0(device,"identifier"), callString0(device,"name"),
              callLong0(device,"status"), [connected containsObject:device]]];
        }
        NSString *snapshot = [parts componentsJoinedByString:@";"];
        if (![snapshot isEqualToString:last]) { dumpState(manager, @"change"); last = snapshot; }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    dumpState(manager, @"end");
} return 0; }
