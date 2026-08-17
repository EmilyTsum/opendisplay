#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id call0(id o,const char*s){return ((id(*)(id,SEL))objc_msgSend)(o,sel_registerName(s));}
static id call1(id o,const char*s,id a){return ((id(*)(id,SEL,id))objc_msgSend)(o,sel_registerName(s),a);}
static long callLong0(id o,const char*s){return ((long(*)(id,SEL))objc_msgSend)(o,sel_registerName(s));}
static NSString *desc(id v){return v ? [v description] : @"<nil>";}

static void printConfig(id cfg) {
    if (!cfg) { puts("  config=<nil>"); return; }
    const char *keys[]={"framerate","codec","txMaxBitrate","txMinBitrate","lowLatency",
                       "keyFrameInterval","tilesPerFrame","hdr","enableTimeSync","dataLink",
                       "rtcp","rtcpTimeoutInterval","displayID","showSideBar","showTouchBar",
                       "configureDisplayExclusiveMode","service"};
    for(size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++) {
        id v=call0(cfg,keys[i]);
        printf("  %-30s %s\n", keys[i], desc(v).UTF8String);
    }
    printf("  %-30s %ld\n", "transport", callLong0(cfg,"transport"));
    CGSize size=((CGSize(*)(id,SEL))objc_msgSend)(cfg,sel_registerName("size"));
    double scale=((double(*)(id,SEL))objc_msgSend)(cfg,sel_registerName("scale"));
    printf("  %-30s %.0fx%.0f\n", "size", size.width,size.height);
    printf("  %-30s %.3f\n", "scale", scale);
}

int main(void) { @autoreleasepool {
    void *h=dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",RTLD_LAZY|RTLD_LOCAL);
    if(!h){fprintf(stderr,"SidecarCore: %s\n",dlerror());return 1;}
    Class mc=NSClassFromString(@"SidecarDisplayManager");
    id mgr=call0((id)mc,"sharedManager");
    NSArray *devices=call0(mgr,"devices") ?: @[];
    NSArray *connected=call0(mgr,"connectedDevices") ?: @[];
    printf("devices=%lu connected=%lu\n",(unsigned long)devices.count,(unsigned long)connected.count);
    for(id d in devices) {
        printf("\nDEVICE name=%s id=%s model=%s status=%ld connected=%d\n",
               desc(call0(d,"name")).UTF8String,
               desc(call0(d,"identifier")).UTF8String,
               desc(call0(d,"model")).UTF8String,
               callLong0(d,"status"),[connected containsObject:d]);
        @try { printConfig(call1(mgr,"configForDevice:",d)); }
        @catch(NSException *e){printf("  config exception: %s\n",e.reason.UTF8String);}
    }
} return 0; }
