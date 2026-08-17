#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static BOOL interesting(const char *s) {
    if (!s) return NO;
    NSString *v = [[NSString stringWithUTF8String:s] lowercaseString];
    for (NSString *k in @[@"channel", @"band", @"frequency", @"rate", @"rssi", @"mcs", @"phy", @"awdl", @"peer", @"link", @"interface", @"width"]) {
        if ([v containsString:k]) return YES;
    }
    return NO;
}

int main(void) { @autoreleasepool {
    const char *path = "/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer";
    void *h = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int count = objc_getClassList(NULL, 0);
    Class *classes = calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    for (int i=0;i<count;i++) {
        Class cls = classes[i];
        const char *img = class_getImageName(cls);
        if (!img || !strstr(img, "WiFiPeerToPeer.framework")) continue;
        printf("CLASS %s\n", class_getName(cls));
        unsigned n=0; Method *ms=class_copyMethodList(cls,&n);
        for(unsigned j=0;j<n;j++) {
            const char *name=sel_getName(method_getName(ms[j]));
            if (interesting(name)) printf("  - %s :: %s\n", name, method_getTypeEncoding(ms[j]));
        }
        free(ms);
        Class meta=object_getClass(cls); n=0; ms=class_copyMethodList(meta,&n);
        for(unsigned j=0;j<n;j++) {
            const char *name=sel_getName(method_getName(ms[j]));
            if (interesting(name)) printf("  + %s :: %s\n", name, method_getTypeEncoding(ms[j]));
        }
        free(ms);
        unsigned pn=0; objc_property_t *ps=class_copyPropertyList(cls,&pn);
        for(unsigned j=0;j<pn;j++) {
            const char *name=property_getName(ps[j]);
            if (interesting(name)) printf("  @property %s :: %s\n", name, property_getAttributes(ps[j]));
        }
        free(ps);
    }
    free(classes);
} return 0; }
