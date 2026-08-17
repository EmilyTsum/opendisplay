#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSSet<NSString *> *classNames(void) {
    int count = objc_getClassList(NULL, 0);
    Class *classes = calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSMutableSet *s = [NSMutableSet setWithCapacity:count];
    for (int i=0;i<count;i++) [s addObject:[NSString stringWithUTF8String:class_getName(classes[i])]];
    free(classes); return s;
}
static BOOL interesting(const char *s) {
    if (!s) return NO;
    NSString *v = [[NSString stringWithUTF8String:s] lowercaseString];
    for (NSString *k in @[@"channel",@"band",@"frequency",@"rate",@"rssi",@"mcs",@"phy",@"awdl",@"peer",@"link",@"interface",@"width",@"statistic"])
        if ([v containsString:k]) return YES;
    return NO;
}
static void dumpClass(Class cls) {
    printf("CLASS %s IMAGE %s\n", class_getName(cls), class_getImageName(cls) ?: "<nil>");
    unsigned n=0; Method *ms=class_copyMethodList(cls,&n);
    for(unsigned j=0;j<n;j++) { const char *name=sel_getName(method_getName(ms[j])); if(interesting(name)) printf("  - %s :: %s\n",name,method_getTypeEncoding(ms[j])); } free(ms);
    Class meta=object_getClass(cls); n=0; ms=class_copyMethodList(meta,&n);
    for(unsigned j=0;j<n;j++) { const char *name=sel_getName(method_getName(ms[j])); if(interesting(name)) printf("  + %s :: %s\n",name,method_getTypeEncoding(ms[j])); } free(ms);
    unsigned pn=0; objc_property_t *ps=class_copyPropertyList(cls,&pn);
    for(unsigned j=0;j<pn;j++) { const char *name=property_getName(ps[j]); if(interesting(name)) printf("  @property %s :: %s\n",name,property_getAttributes(ps[j])); } free(ps);
}
int main(void) { @autoreleasepool {
    NSSet *before = classNames();
    const char *paths[] = {
      "/System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/WiFiPeerToPeer",
      "/System/Library/PrivateFrameworks/Apple80211.framework/Apple80211"
    };
    for(int p=0;p<2;p++) { void *h=dlopen(paths[p],RTLD_LAZY|RTLD_LOCAL); printf("DLOPEN %s => %p %s\n",paths[p],h,h?"":dlerror()); }
    NSSet *after = classNames();
    NSMutableSet *added=[after mutableCopy]; [added minusSet:before];
    printf("ADDED_CLASSES %lu\n",(unsigned long)added.count);
    for(NSString *name in [[added allObjects] sortedArrayUsingSelector:@selector(compare:)]) { Class c=NSClassFromString(name); if(c) dumpClass(c); }
    // Also dump any already-present class whose image is one of these frameworks.
    int count=objc_getClassList(NULL,0); Class *classes=calloc((size_t)count,sizeof(Class)); count=objc_getClassList(classes,count);
    for(int i=0;i<count;i++) { const char *img=class_getImageName(classes[i]); if(img&&(strstr(img,"WiFiPeerToPeer")||strstr(img,"Apple80211"))) dumpClass(classes[i]); }
    free(classes);
} return 0; }
