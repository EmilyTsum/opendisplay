#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static id call0(id o, const char *s) { return ((id(*)(id,SEL))objc_msgSend)(o, sel_registerName(s)); }
static id call1(id o, const char *s, id a) { return ((id(*)(id,SEL,id))objc_msgSend)(o, sel_registerName(s), a); }
static long callLong0(id o, const char *s) { return ((long(*)(id,SEL))objc_msgSend)(o, sel_registerName(s)); }
static void setObj(id o, const char *s, id v) { ((void(*)(id,SEL,id))objc_msgSend)(o, sel_registerName(s), v); }
static NSString *desc(id v) { return v ? [v description] : @"<nil>"; }

static BOOL requireSelector(id obj, const char *name) {
    SEL sel=sel_registerName(name);
    if (![obj respondsToSelector:sel]) {
        fprintf(stderr,"error: required private selector missing: %s on %s\n",name,object_getClassName(obj));
        return NO;
    }
    return YES;
}

static void *openSidecarCore(void) {
    const char *paths[]={
        "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
        "/System/Library/PrivateFrameworks/SidecarCore.framework/Versions/A/SidecarCore",
        NULL
    };
    for (int i=0; paths[i]; i++) {
        void *h=dlopen(paths[i],RTLD_LAZY|RTLD_LOCAL);
        if (h) return h;
    }
    return NULL;
}

static void usage(void) {
    puts("sidecar-native-tune — research-only native Sidecar config probe/tuner");
    puts("");
    puts("Usage:");
    puts("  sidecar-native-tune list");
    puts("  sidecar-native-tune dump [--device NAME|UUID|INDEX]");
    puts("  sidecar-native-tune connect [--device NAME|UUID|INDEX] [options] [--apply]");
    puts("  sidecar-native-tune disconnect [--device NAME|UUID|INDEX] --apply");
    puts("");
    puts("Connect options (only the supplied fields are changed from stock config):");
    puts("  --fps N                 e.g. 120");
    puts("  --codec stock|h264|hevc (0=H.264, 1=HEVC on current macOS 26 Sidecar)");
    puts("  --max-mbps N            txMaxBitrate in Mbit/s");
    puts("  --min-mbps N            txMinBitrate in Mbit/s");
    puts("  --low-latency 0|1");
    puts("  --time-sync 0|1");
    puts("  --timeout SEC           completion wait, default 20");
    puts("  --apply                 actually connect/disconnect; otherwise dry-run");
}

static const char *codecName(NSInteger v) {
    if (v == 0) return "H.264";
    if (v == 1) return "HEVC";
    return "unknown";
}

static void printConfig(id cfg, const char *prefix) {
    if (!cfg) { printf("%sconfig=<nil>\n", prefix); return; }
    const char *keys[] = {"framerate","txMaxBitrate","txMinBitrate","lowLatency",
                          "keyFrameInterval","tilesPerFrame","hdr","enableTimeSync","dataLink",
                          "rtcp","rtcpTimeoutInterval","displayID","showSideBar","showTouchBar",
                          "configureDisplayExclusiveMode","service"};
    for (size_t i=0; i<sizeof(keys)/sizeof(keys[0]); i++) {
        SEL sel=sel_registerName(keys[i]);
        if (![cfg respondsToSelector:sel]) { printf("%s%-30s <missing>\n",prefix,keys[i]); continue; }
        id v = call0(cfg, keys[i]);
        printf("%s%-30s %s\n", prefix, keys[i], desc(v).UTF8String);
    }
    if ([cfg respondsToSelector:sel_registerName("codec")]) {
        id codec = call0(cfg, "codec");
        NSInteger cv = [codec integerValue];
        printf("%s%-30s %s (%s)\n", prefix, "codec", desc(codec).UTF8String, codecName(cv));
    } else printf("%s%-30s <missing>\n",prefix,"codec");
    if ([cfg respondsToSelector:sel_registerName("transport")]) printf("%s%-30s %ld\n", prefix, "transport", callLong0(cfg,"transport"));
    else printf("%s%-30s <missing>\n",prefix,"transport");
    if ([cfg respondsToSelector:sel_registerName("size")]) {
        CGSize size = ((CGSize(*)(id,SEL))objc_msgSend)(cfg,sel_registerName("size"));
        printf("%s%-30s %.0fx%.0f\n", prefix, "size", size.width, size.height);
    } else printf("%s%-30s <missing>\n",prefix,"size");
    if ([cfg respondsToSelector:sel_registerName("scale")]) {
        double scale = ((double(*)(id,SEL))objc_msgSend)(cfg,sel_registerName("scale"));
        printf("%s%-30s %.3f\n", prefix, "scale", scale);
    } else printf("%s%-30s <missing>\n",prefix,"scale");
}

static NSArray *allDevices(id mgr) {
    NSArray *d = call0(mgr,"devices");
    return d ?: @[];
}

static void printDeviceLine(id d, NSUInteger idx, NSArray *connected) {
    printf("[%lu] name=%s id=%s model=%s status=%ld connected=%d\n",
           (unsigned long)idx,
           desc(call0(d,"name")).UTF8String,
           desc(call0(d,"identifier")).UTF8String,
           desc(call0(d,"model")).UTF8String,
           callLong0(d,"status"),
           [connected containsObject:d] ? 1 : 0);
}

static id selectDevice(id mgr, NSString *selectorText) {
    NSArray *devices = allDevices(mgr);
    NSArray *connected = call0(mgr,"connectedDevices") ?: @[];
    if (!selectorText.length) {
        if (devices.count == 1) return devices.firstObject;
        if (devices.count == 0) {
            fprintf(stderr,"error: no Sidecar devices are currently visible\n");
            return nil;
        }
        fprintf(stderr,"error: multiple Sidecar devices are visible; choose one with --device\n");
        for (NSUInteger i=0; i<devices.count; i++) printDeviceLine(devices[i],i,connected);
        return nil;
    }

    NSScanner *scanner=[NSScanner scannerWithString:selectorText];
    NSInteger idx=-1;
    if ([scanner scanInteger:&idx] && scanner.isAtEnd && idx >= 0 && (NSUInteger)idx < devices.count) return devices[(NSUInteger)idx];

    NSMutableArray *matches=[NSMutableArray array];
    NSString *needle=selectorText.lowercaseString;
    for (id d in devices) {
        NSString *name=[desc(call0(d,"name")) lowercaseString];
        NSString *ident=[desc(call0(d,"identifier")) lowercaseString];
        if ([name containsString:needle] || [ident isEqualToString:needle]) [matches addObject:d];
    }
    if (matches.count == 1) return matches.firstObject;
    if (matches.count == 0) fprintf(stderr,"error: no device matched '%s'\n",selectorText.UTF8String);
    else fprintf(stderr,"error: '%s' matched more than one device\n",selectorText.UTF8String);
    return nil;
}

static NSString *argValue(NSArray<NSString*> *args, NSString *key) {
    NSUInteger i=[args indexOfObject:key];
    if (i==NSNotFound) return nil;
    if (i+1>=args.count) { fprintf(stderr,"error: %s requires a value\n",key.UTF8String); exit(2); }
    return args[i+1];
}

static BOOL hasArg(NSArray<NSString*> *args, NSString *key) { return [args containsObject:key]; }

static NSNumber *parseIntOpt(NSArray<NSString*> *args, NSString *key, NSInteger minv, NSInteger maxv) {
    NSString *v=argValue(args,key); if (!v) return nil;
    NSScanner *s=[NSScanner scannerWithString:v]; NSInteger n;
    if (![s scanInteger:&n] || !s.isAtEnd || n<minv || n>maxv) {
        fprintf(stderr,"error: invalid %s value '%s'\n",key.UTF8String,v.UTF8String); exit(2);
    }
    return @(n);
}

static NSNumber *parseMbps(NSArray<NSString*> *args, NSString *key) {
    NSString *v=argValue(args,key); if (!v) return nil;
    NSScanner *s=[NSScanner scannerWithString:v]; double n;
    if (![s scanDouble:&n] || !s.isAtEnd || n<=0 || n>5000) {
        fprintf(stderr,"error: invalid %s value '%s'\n",key.UTF8String,v.UTF8String); exit(2);
    }
    return @((long long)llround(n*1000000.0));
}

static void pumpUntil(BOOL *done, NSTimeInterval timeout) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!*done && [until timeIntervalSinceNow]>0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSArray<NSString*> *args=[[NSProcessInfo processInfo] arguments];
    if (argc<2 || hasArg(args,@"--help") || hasArg(args,@"-h")) { usage(); return argc<2?2:0; }

    printf("host=%s\n",[[NSProcessInfo processInfo].operatingSystemVersionString UTF8String]);
    void *h=openSidecarCore();
    if (!h) { fprintf(stderr,"error: SidecarCore could not be loaded: %s\n",dlerror()); return 1; }
    Class mc=NSClassFromString(@"SidecarDisplayManager");
    if (!mc) { fprintf(stderr,"error: SidecarDisplayManager unavailable on this macOS build\n"); return 1; }
    id mgr=call0((id)mc,"sharedManager");
    if (!mgr) { fprintf(stderr,"error: SidecarDisplayManager.sharedManager unavailable\n"); return 1; }
    if (!requireSelector(mgr,"devices") || !requireSelector(mgr,"connectedDevices") ||
        !requireSelector(mgr,"configForDevice:") || !requireSelector(mgr,"connectToDevice:withConfig:completion:") ||
        !requireSelector(mgr,"disconnectFromDevice:completion:")) return 1;

    NSString *cmd=args[1];
    if ([cmd isEqualToString:@"list"]) {
        NSArray *devices=allDevices(mgr), *connected=call0(mgr,"connectedDevices") ?: @[];
        printf("devices=%lu connected=%lu\n",(unsigned long)devices.count,(unsigned long)connected.count);
        for (NSUInteger i=0;i<devices.count;i++) printDeviceLine(devices[i],i,connected);
        return 0;
    }

    NSString *devSel=argValue(args,@"--device");
    id dev=selectDevice(mgr,devSel);
    if (!dev) return 3;

    if ([cmd isEqualToString:@"dump"]) {
        printf("DEVICE name=%s id=%s model=%s status=%ld\n",
               desc(call0(dev,"name")).UTF8String,desc(call0(dev,"identifier")).UTF8String,
               desc(call0(dev,"model")).UTF8String,callLong0(dev,"status"));
        @try { printConfig(call1(mgr,"configForDevice:",dev),"  "); }
        @catch(NSException *e) { fprintf(stderr,"error: config exception: %s\n",e.reason.UTF8String); return 4; }
        return 0;
    }

    BOOL apply=hasArg(args,@"--apply");
    NSTimeInterval timeout=[argValue(args,@"--timeout") doubleValue]; if (timeout<=0) timeout=20.0;

    if ([cmd isEqualToString:@"disconnect"]) {
        if (!apply) {
            printf("DRY RUN: would disconnect Sidecar device %s\n",desc(call0(dev,"name")).UTF8String);
            puts("Re-run with --apply to perform the disconnect.");
            return 0;
        }
        __block BOOL done=NO; __block NSError *result=nil;
        void (^completion)(NSError *)=^(NSError *error){ result=error; done=YES; };
        @try { ((void(*)(id,SEL,id,id))objc_msgSend)(mgr,sel_registerName("disconnectFromDevice:completion:"),dev,completion); }
        @catch(NSException *e) { fprintf(stderr,"error: disconnect exception: %s\n",e.reason.UTF8String); return 5; }
        pumpUntil(&done,timeout);
        if (!done) { fprintf(stderr,"error: disconnect completion timed out\n"); return 6; }
        if (result) { fprintf(stderr,"error: disconnect: %s\n",result.description.UTF8String); return 7; }
        puts("disconnect completed without error");
        return 0;
    }

    if (![cmd isEqualToString:@"connect"]) { usage(); return 2; }

    id stock=nil;
    @try { stock=call1(mgr,"configForDevice:",dev); }
    @catch(NSException *e) { fprintf(stderr,"error: configForDevice exception: %s\n",e.reason.UTF8String); return 4; }
    if (!stock) { fprintf(stderr,"error: stock Sidecar config is nil; refusing to construct a full config from guesses\n"); return 8; }
    if (!requireSelector(stock,"copyWithZone:")) return 8;
    id cfg=call0(stock,"copy");
    if (!cfg) { fprintf(stderr,"error: SidecarDisplayConfig copy failed\n"); return 8; }

    NSNumber *fps=parseIntOpt(args,@"--fps",1,240);
    if (fps) { if(!requireSelector(cfg,"setFramerate:")) return 8; setObj(cfg,"setFramerate:",fps); }
    NSString *codec=argValue(args,@"--codec");
    if (codec && ![codec isEqualToString:@"stock"]) {
        if(!requireSelector(cfg,"setCodec:")) return 8;
        if ([codec caseInsensitiveCompare:@"h264"]==NSOrderedSame || [codec caseInsensitiveCompare:@"h.264"]==NSOrderedSame) setObj(cfg,"setCodec:",@0);
        else if ([codec caseInsensitiveCompare:@"hevc"]==NSOrderedSame || [codec caseInsensitiveCompare:@"h265"]==NSOrderedSame || [codec caseInsensitiveCompare:@"h.265"]==NSOrderedSame) setObj(cfg,"setCodec:",@1);
        else { fprintf(stderr,"error: --codec must be stock, h264, or hevc\n"); return 2; }
    }
    NSNumber *maxb=parseMbps(args,@"--max-mbps"); if (maxb) { if(!requireSelector(cfg,"setTxMaxBitrate:")) return 8; setObj(cfg,"setTxMaxBitrate:",maxb); }
    NSNumber *minb=parseMbps(args,@"--min-mbps"); if (minb) { if(!requireSelector(cfg,"setTxMinBitrate:")) return 8; setObj(cfg,"setTxMinBitrate:",minb); }
    NSNumber *ll=parseIntOpt(args,@"--low-latency",0,1); if (ll) { if(!requireSelector(cfg,"setLowLatency:")) return 8; setObj(cfg,"setLowLatency:",@([ll boolValue])); }
    NSNumber *ts=parseIntOpt(args,@"--time-sync",0,1); if (ts) { if(!requireSelector(cfg,"setEnableTimeSync:")) return 8; setObj(cfg,"setEnableTimeSync:",@([ts boolValue])); }

    puts("=== stock config ==="); printConfig(stock,"  ");
    puts("=== requested config ==="); printConfig(cfg,"  ");

    if (!apply) {
        puts("DRY RUN: no Sidecar connection was started.");
        puts("Re-run the exact command with --apply only after checking the stock/requested diff above.");
        return 0;
    }

    __block BOOL done=NO; __block NSError *result=nil;
    void (^completion)(NSError *)=^(NSError *error){ result=error; done=YES; };
    @try {
        ((void(*)(id,SEL,id,id,id))objc_msgSend)(mgr,sel_registerName("connectToDevice:withConfig:completion:"),dev,cfg,completion);
    } @catch(NSException *e) {
        fprintf(stderr,"error: connect exception: %s\n",e.reason.UTF8String); return 9;
    }
    pumpUntil(&done,timeout);
    if (!done) { fprintf(stderr,"error: connect completion timed out after %.1f seconds\n",timeout); return 10; }
    if (result) { fprintf(stderr,"error: Sidecar connect: %s\n",result.description.UTF8String); return 11; }
    puts("connect completion returned no error");
    puts("Important: this only proves the request was accepted. Verify actual display refresh/codec/bitrate separately.");
    return 0;
} }
