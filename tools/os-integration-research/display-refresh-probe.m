#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <mach/mach_time.h>

static atomic_ullong gCount;
static uint64_t gFirst=0, gLast=0;
static mach_timebase_info_data_t gTimebase;

static CVReturn cb(CVDisplayLinkRef dl, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags inFlags, CVOptionFlags *outFlags, void *ctx) {
    (void)dl; (void)out; (void)inFlags; (void)outFlags; (void)ctx;
    uint64_t t = now->hostTime ? now->hostTime : mach_absolute_time();
    unsigned long long n = atomic_fetch_add(&gCount,1) + 1;
    if (n == 1) gFirst = t;
    gLast = t;
    return kCVReturnSuccess;
}

static double secFromTicks(uint64_t dt) {
    return ((double)dt * (double)gTimebase.numer / (double)gTimebase.denom) / 1e9;
}

static void listDisplays(void) {
    uint32_t count=0;
    CGGetActiveDisplayList(0,NULL,&count);
    CGDirectDisplayID *ids=calloc(count,sizeof(*ids));
    CGGetActiveDisplayList(count,ids,&count);
    printf("activeDisplays=%u\n",count);
    for (uint32_t i=0;i<count;i++) {
        CGDirectDisplayID d=ids[i];
        CGDisplayModeRef m=CGDisplayCopyDisplayMode(d);
        CGRect b=CGDisplayBounds(d);
        double hz=m?CGDisplayModeGetRefreshRate(m):0;
        size_t w=m?CGDisplayModeGetWidth(m):0, h=m?CGDisplayModeGetHeight(m):0;
        size_t pw=m?CGDisplayModeGetPixelWidth(m):0, ph=m?CGDisplayModeGetPixelHeight(m):0;
        printf("[%u] id=%u main=%d builtin=%d online=%d active=%d bounds=%.0fx%.0f mode=%zux%zu pixels=%zux%zu reportedHz=%.3f\n",
               i,d,CGDisplayIsMain(d),CGDisplayIsBuiltin(d),CGDisplayIsOnline(d),CGDisplayIsActive(d),
               b.size.width,b.size.height,w,h,pw,ph,hz);
        if(m) CGDisplayModeRelease(m);
    }
    free(ids);
}

int main(int argc,const char **argv){ @autoreleasepool {
    mach_timebase_info(&gTimebase);
    if(argc==1 || (argc==2 && strcmp(argv[1],"list")==0)) { listDisplays(); return 0; }
    if(argc!=4 || strcmp(argv[1],"measure")!=0) {
        fprintf(stderr,"usage: display-refresh-probe [list]\n       display-refresh-probe measure DISPLAY_ID SECONDS\n"); return 2;
    }
    CGDirectDisplayID d=(CGDirectDisplayID)strtoul(argv[2],NULL,0);
    double seconds=strtod(argv[3],NULL);
    if(!d || seconds<=0 || seconds>60) { fprintf(stderr,"invalid display id or duration\n"); return 2; }
    CGDisplayModeRef m=CGDisplayCopyDisplayMode(d);
    if(!m) { fprintf(stderr,"display %u has no current mode\n",d); return 3; }
    printf("display=%u reportedHz=%.3f mode=%zux%zu pixels=%zux%zu\n",d,CGDisplayModeGetRefreshRate(m),CGDisplayModeGetWidth(m),CGDisplayModeGetHeight(m),CGDisplayModeGetPixelWidth(m),CGDisplayModeGetPixelHeight(m));
    CGDisplayModeRelease(m);

    atomic_store(&gCount,0); gFirst=gLast=0;
    CVDisplayLinkRef link=NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn r=CVDisplayLinkCreateWithCGDisplay(d,&link);
#pragma clang diagnostic pop
    if(r!=kCVReturnSuccess || !link){ fprintf(stderr,"CVDisplayLinkCreateWithCGDisplay failed: %d\n",r); return 4; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVDisplayLinkSetOutputCallback(link,cb,NULL);
    r=CVDisplayLinkStart(link);
#pragma clang diagnostic pop
    if(r!=kCVReturnSuccess){ fprintf(stderr,"CVDisplayLinkStart failed: %d\n",r); CVDisplayLinkRelease(link); return 5; }
    [NSThread sleepForTimeInterval:seconds];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVDisplayLinkStop(link);
#pragma clang diagnostic pop
    unsigned long long n=atomic_load(&gCount);
    double elapsed=(n>1 && gLast>gFirst)?secFromTicks(gLast-gFirst):0;
    double measured=(elapsed>0)?((double)(n-1)/elapsed):0;
    printf("callbacks=%llu elapsed=%.6f measuredHz=%.3f\n",n,elapsed,measured);
    CVDisplayLinkRelease(link);
    return 0;
} }
