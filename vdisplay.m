// vdisplay - creates an invisible extra screen ("virtual display") on macOS.
//
// macOS only draws the desktop you're looking at, so a desktop you've swiped away
// from can't be recorded. A virtual display is a screen macOS *always* draws,
// even though no real monitor is attached. TV Mirror records it and sends it to the TV.
//
// It uses CGVirtualDisplay, a built-in but undocumented part of macOS's CoreGraphics
// (the same thing apps like DeskPad use). macOS only switches a virtual screen on for
// a real app connected to the window server, so this runs as a hidden background app
// (no Dock icon, no windows). The screen exists for as long as this
// program runs; when it quits, the screen disappears and its windows move back.
//
// macOS doesn't always switch a new virtual screen on (for example right after the
// previous one was removed), so this waits until it's really on, and otherwise
// removes it and tries again as a "new" monitor, up to 4 times.
//
// Build:  clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
// Run:    ./vdisplay 1920 1080        (prints the new screen's display ID once it's on)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

// ---- Declarations for the undocumented CoreGraphics classes ----------------

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

// ---------------------------------------------------------------------------

static void quit(int sig) { (void)sig; exit(0); }

static CGVirtualDisplay *gDisplay;   // kept for as long as the program runs
static unsigned int gWidth = 1920, gHeight = 1080;
static int gAttempt = 0;
static BOOL gReplacing = NO;         // YES while we remove a screen on purpose
static const int kMaxAttempts = 4;

static void createDisplay(void);

static BOOL isOnline(CGDirectDisplayID displayID) {
    CGDirectDisplayID online[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, online, &count);
    for (uint32_t i = 0; i < count; i++) if (online[i] == displayID) return YES;
    return NO;
}

static void report(CGDirectDisplayID newID) {
    CGDirectDisplayID online[16], active[16];
    uint32_t nOnline = 0, nActive = 0;
    CGGetOnlineDisplayList(16, online, &nOnline);
    CGGetActiveDisplayList(16, active, &nActive);
    int isActive = 0;
    for (uint32_t i = 0; i < nActive; i++) if (active[i] == newID) isActive = 1;
    CGRect b = CGDisplayBounds(newID);
    fprintf(stderr,
            "[vdisplay] try %d: id=%u online=%d active=%d mirrored=%d asleep=%d size=%.0fx%.0f at %.0f,%.0f "
            "| online screens=%u active screens=%u\n",
            gAttempt, newID, (int)isOnline(newID), isActive, (int)CGDisplayIsInMirrorSet(newID),
            (int)CGDisplayIsAsleep(newID), b.size.width, b.size.height, b.origin.x, b.origin.y,
            nOnline, nActive);
    fflush(stderr);
}

// Check every 0.25 s whether macOS has switched the screen on.
static void waitUntilOnline(CGDirectDisplayID newID, int checks) {
    if (isOnline(newID)) {
        // macOS sometimes adds a new screen as a *mirror* of the main one.
        // A mirror isn't a separate screen, so switch that off.
        if (CGDisplayIsInMirrorSet(newID)) {
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
                CGConfigureDisplayMirrorOfDisplay(config, newID, kCGNullDirectDisplay);
                CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            }
        }
        report(newID);
        printf("%u\n", newID);       // tell TV Mirror the screen is ready
        fflush(stdout);
        return;
    }
    if (checks < 12) {               // keep waiting, up to 3 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            waitUntilOnline(newID, checks + 1);
        });
        return;
    }
    report(newID);
    if (gAttempt >= kMaxAttempts) {
        fprintf(stderr, "macOS didn't switch the virtual screen on after %d tries.\n", gAttempt);
        exit(5);
    }
    // Remove it and try again as a "new" monitor
    gReplacing = YES;
    gDisplay = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        gReplacing = NO;
        createDisplay();
    });
}

static void createDisplay(void) {
    gAttempt++;
    Class Descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class Display    = NSClassFromString(@"CGVirtualDisplay");
    Class Settings   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class Mode       = NSClassFromString(@"CGVirtualDisplayMode");
    if (!Descriptor || !Display || !Settings || !Mode) {
        fprintf(stderr, "This version of macOS doesn't support virtual displays.\n");
        exit(2);
    }

    CGVirtualDisplayDescriptor *descriptor = [[Descriptor alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = @"TV Mirror Display";
    descriptor.maxPixelsWide = gWidth;
    descriptor.maxPixelsHigh = gHeight;
    descriptor.sizeInMillimeters = CGSizeMake(gWidth * 0.37, gHeight * 0.37);  // like a ~32" TV
    descriptor.vendorID = 0x7456;    // made-up IDs so macOS remembers this "monitor"
    descriptor.productID = 0x4D52;
    descriptor.serialNum = (unsigned int)gAttempt;   // each retry looks like a new monitor
    descriptor.terminationHandler = ^(id unused, CGVirtualDisplay *display) {
        if (gReplacing) return;      // we removed it ourselves to try again
        fprintf(stderr, "The virtual screen was removed by macOS.\n");
        exit(1);
    };

    CGVirtualDisplay *display = [[Display alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) {
        fprintf(stderr, "Couldn't create the virtual screen.\n");
        exit(3);
    }

    CGVirtualDisplaySettings *settings = [[Settings alloc] init];
    settings.hiDPI = 0;   // 1 screen pixel = 1 TV pixel
    settings.modes = @[ [[Mode alloc] initWithWidth:gWidth height:gHeight refreshRate:60] ];
    if (![display applySettings:settings]) {
        fprintf(stderr, "Couldn't set the virtual screen to %ux%u.\n", gWidth, gHeight);
        exit(4);
    }
    gDisplay = display;
    waitUntilOnline(display.displayID, 0);
}

// Creates the screen once macOS has finished starting us up as an app.
@interface VDAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation VDAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        createDisplay();
    });
}
@end

static VDAppDelegate *gDelegate;     // NSApp only keeps a weak reference

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) gWidth = (unsigned int)atoi(argv[1]);
        if (argc > 2) gHeight = (unsigned int)atoi(argv[2]);
        if (gWidth < 640 || gHeight < 480) { gWidth = 1920; gHeight = 1080; }

        signal(SIGTERM, quit);
        signal(SIGINT, quit);
        signal(SIGHUP, quit);

        // Become a hidden background app so macOS connects us to the window server.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        gDelegate = [[VDAppDelegate alloc] init];
        [NSApp setDelegate:gDelegate];

        // Keep running (and keep the screen alive) until TV Mirror stops us.
        [NSApp run];
    }
    return 0;
}
