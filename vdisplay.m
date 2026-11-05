// vdisplay - creates an invisible extra screen ("virtual display") on macOS,
// plus a small live preview window of it on your normal screen.
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
// Live preview: a window on your real screen that shows the TV screen in real time
// (the TV itself shows it a few seconds later), so you can see your mouse pointer
// there and move/resize windows. Clicking in it makes the pointer jump to that spot
// on the TV screen. Sending SIGUSR1 shows/hides it. It uses CGDisplayStream, looked
// up while running because newer macOS SDKs hide it; if it's missing, everything
// else still works, just without the preview.
//
// Build:  clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreGraphics \
//                -framework QuartzCore vdisplay.m -o vdisplay
// Run:    ./vdisplay 1920 1080 1     (prints the screen's ID once it's on; last number:
//                                     1 = show the live preview, 0 = don't)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static BOOL gWantPreview = YES;

static void createDisplay(void);
static void createDisplaySoon(void);

// macOS asks this program "the screens changed, OK?" while a screen is being added,
// and only waits a quarter of a second for the answer, which comes from the main
// thread. So the screen is created on this separate queue, keeping the main thread
// free to answer (otherwise macOS can leave the new screen switched off).
static dispatch_queue_t gWorkQueue;
static void startPreview(CGDirectDisplayID displayID);

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
        if (gWantPreview) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                startPreview(newID);
            });
        }
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
    dispatch_async(gWorkQueue, ^{ gDisplay = nil; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        gReplacing = NO;
        createDisplaySoon();
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
    [descriptor setDispatchQueue:gWorkQueue];
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
    CGDirectDisplayID newID = display.displayID;
    dispatch_async(dispatch_get_main_queue(), ^{ waitUntilOnline(newID, 0); });
}

static void createDisplaySoon(void) {
    dispatch_async(gWorkQueue, ^{ createDisplay(); });
}

// ---- Live preview -------------------------------------------------------------

typedef void *VDStreamRef;
typedef void (^VDFrameHandler)(int32_t status, uint64_t displayTime, void *frameSurface, const void *updateRef);
typedef VDStreamRef (*VDStreamCreateFn)(CGDirectDisplayID display, size_t outputWidth, size_t outputHeight,
                                        int32_t pixelFormat, CFDictionaryRef properties,
                                        dispatch_queue_t queue, VDFrameHandler handler);
typedef CGError (*VDStreamStartFn)(VDStreamRef stream);

static CGDirectDisplayID gPreviewDisplay;
static NSWindow *gPreview;
static NSView *gPreviewView;
static VDStreamRef gStream;
static NSTimer *gPointerTimer;
static dispatch_source_t gToggleSource;

static NSScreen *screenForDisplay(CGDirectDisplayID displayID) {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number && number.unsignedIntValue == displayID) return screen;
    }
    return nil;
}

@interface VDPreviewView : NSView
@end

@implementation VDPreviewView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// Clicking the preview makes the mouse pointer jump to the same spot on the TV screen.
- (void)mouseDown:(NSEvent *)event {
    NSRect bounds = self.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat rx = MAX(0.0, MIN(1.0, p.x / bounds.size.width));
    CGFloat ry = MAX(0.0, MIN(1.0, 1.0 - p.y / bounds.size.height));   // screens count from the top
    CGRect tv = CGDisplayBounds(gPreviewDisplay);
    CGPoint target = CGPointMake(tv.origin.x + rx * (tv.size.width - 1),
                                 tv.origin.y + ry * (tv.size.height - 1));
    CGWarpMouseCursorPosition(target);
    CGAssociateMouseAndMouseCursorPosition(1);
}
@end

static void togglePreview(void) {
    if (!gPreview) return;
    if (gPreview.visible) [gPreview orderOut:nil];
    else [gPreview orderFrontRegardless];
}

static void startPreview(CGDirectDisplayID displayID) {
    gPreviewDisplay = displayID;
    VDStreamCreateFn create = (VDStreamCreateFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    VDStreamStartFn start = (VDStreamStartFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    if (!create || !start) {
        fprintf(stderr, "[vdisplay] the live preview isn't available on this version of macOS\n");
        return;
    }

    // Put it in the bottom-right corner of one of your real screens
    NSScreen *home = nil;
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number && number.unsignedIntValue != displayID) { home = screen; break; }
    }
    if (!home) {
        fprintf(stderr, "[vdisplay] no real screen found for the live preview\n");
        return;
    }
    NSRect area = home.visibleFrame;
    CGFloat w = 480, h = round(w * gHeight / gWidth);
    NSRect frame = NSMakeRect(NSMaxX(area) - w - 20, NSMinY(area) + 20, w, h);

    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"TV screen (live)";
    window.releasedWhenClosed = NO;
    window.contentAspectRatio = NSMakeSize(gWidth, gHeight);
    window.contentMinSize = NSMakeSize(240, round(240.0 * gHeight / gWidth));
    window.level = NSFloatingWindowLevel;                                  // stays on top
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |   // on every desktop
                                NSWindowCollectionBehaviorFullScreenAuxiliary;

    VDPreviewView *view = [[VDPreviewView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = NSColor.blackColor.CGColor;
    view.layer.contentsGravity = kCAGravityResizeAspect;
    window.contentView = view;
    gPreviewView = view;

    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    CFStringRef *showCursor = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCGDisplayStreamShowCursor");
    CFStringRef *minFrameTime = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCGDisplayStreamMinimumFrameTime");
    if (showCursor && *showCursor) props[(__bridge NSString *)*showCursor] = @YES;
    if (minFrameTime && *minFrameTime) props[(__bridge NSString *)*minFrameTime] = @(1.0 / 30.0);

    VDStreamRef stream = create(displayID, (size_t)(w * 2), (size_t)(h * 2), 0x42475241 /* 'BGRA' */,
                                (__bridge CFDictionaryRef)props, dispatch_get_main_queue(),
                                ^(int32_t status, uint64_t displayTime, void *frameSurface, const void *updateRef) {
        if (status == 0 /* a complete frame */ && frameSurface) {
            gPreviewView.layer.contents = (__bridge id)frameSurface;
        }
    });
    if (!stream || start(stream) != kCGErrorSuccess) {
        fprintf(stderr, "[vdisplay] couldn't start the live preview\n");
        return;
    }
    gStream = stream;
    gPreview = window;
    [window orderFrontRegardless];
    fprintf(stderr, "[vdisplay] live preview started\n");

    // The title says when your mouse pointer is on the TV screen
    gPointerTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        NSScreen *tv = screenForDisplay(gPreviewDisplay);
        BOOL onTV = tv && NSPointInRect([NSEvent mouseLocation], tv.frame);
        NSString *title = onTV ? @"TV screen (live) - your mouse pointer is on the TV"
                               : @"TV screen (live) - click here to move the pointer to the TV";
        if (![gPreview.title isEqualToString:title]) gPreview.title = title;
    }];
}

// Creates the screen once macOS has finished starting us up as an app.
@interface VDAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation VDAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        createDisplaySoon();
    });
}
@end

static VDAppDelegate *gDelegate;     // NSApp only keeps a weak reference

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) gWidth = (unsigned int)atoi(argv[1]);
        if (argc > 2) gHeight = (unsigned int)atoi(argv[2]);
        if (gWidth < 640 || gHeight < 480) { gWidth = 1920; gHeight = 1080; }
        if (argc > 3 && strcmp(argv[3], "0") == 0) gWantPreview = NO;

        gWorkQueue = dispatch_queue_create("tvmirror.vdisplay", DISPATCH_QUEUE_SERIAL);
        signal(SIGTERM, quit);
        signal(SIGINT, quit);
        signal(SIGHUP, quit);

        // SIGUSR1 (TV Mirror's P key) shows/hides the live preview
        signal(SIGUSR1, SIG_IGN);
        gToggleSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gToggleSource, ^{ togglePreview(); });
        dispatch_resume(gToggleSource);

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
