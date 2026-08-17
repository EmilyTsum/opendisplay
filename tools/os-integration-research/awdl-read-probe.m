#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id callObjErr(id obj, const char *name, NSError **error) {
    return ((id(*)(id,SEL,NSError **))objc_msgSend)(obj, sel_registerName(name), error);
}
static unsigned long long callU64(id obj, const char *name) {
    return ((unsigned long long(*)(id,SEL))objc_msgSend)(obj, sel_registerName(name));
}
static unsigned callU32(id obj, const char *name) {
    return ((unsigned(*)(id,SEL))objc_msgSend)(obj, sel_registerName(name));
}
static int callInt(id obj, const char *name) {
    return ((int(*)(id,SEL))objc_msgSend)(obj, sel_registerName(name));
}
int main(void) { @autoreleasepool {
    dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_LAZY|RTLD_LOCAL);
    Class ch = NSClassFromString(@"CWFChannel");
    printf("CWFChannel=%s\n", ch ? "yes" : "no");
    if (ch) {
        for (unsigned band=0; band<=4; band++) for (int width=0; width<=6; width++) {
            id x = ((id(*)(id,SEL,unsigned long long,unsigned,int))objc_msgSend)((id)ch, sel_registerName("channelWithNumber:band:width:"), 5, band, width);
            if (x) printf("CH band=%u width=%d => getters band=%u ch=%llu width=%d desc=%s\n", band,width,callU32(x,"band"),callU64(x,"channel"),callInt(x,"width"),[[x description] UTF8String]);
        }
    }
    Class a = NSClassFromString(@"CWFApple80211");
    printf("CWFApple80211=%s\n", a ? "yes" : "no");
    if (a) {
        id obj=((id(*)(id,SEL,id))objc_msgSend)((id)[a alloc],sel_registerName("initWithInterfaceName:"),@"awdl0");
        printf("apple=%s\n", [[obj description] UTF8String]);
        const char *sels[]={"channel:","txRate:","rxRate:","maxLinkSpeed:","MCSIndex:","RSSI:","activePHYMode:","AWDLSyncChannelSequence:","AWDLStatistics:","AWDLSidecarDiagnostics:"};
        for(size_t i=0;i<sizeof(sels)/sizeof(sels[0]);i++) {
            NSError *e=nil; id v=callObjErr(obj,sels[i],&e);
            printf("GET %s => value=%s class=%s error=%s\n",sels[i],v?[[v description] UTF8String]:"<nil>",v?object_getClassName(v):"<nil>",e?[[e description] UTF8String]:"<nil>");
        }
        [obj release];
    }
} return 0; }
