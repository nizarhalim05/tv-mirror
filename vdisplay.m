// vdisplay - creates an invisible extra screen ("virtual display") on macOS.
//
// macOS only draws the desktop you're looking at, so a desktop you've swiped away
// from can't be recorded. A virtual display is a screen macOS *always* draws,
// even though no real monitor is attached. TV Mirror records it and sends it to the TV.
//
// It uses CGVirtualDisplay, a built-in but undocumented part of macOS's CoreGraphics
// (the same thing apps like DeskPad use). The screen exists for as long as this
// program runs; when it quits, the screen disappears and its windows move back.
//
// Build:  clang -fobjc-arc -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
// Run:    ./vdisplay 1920 1080        (prints the new screen's display ID)

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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int width  = argc > 1 ? (unsigned int)atoi(argv[1]) : 1920;
        unsigned int height = argc > 2 ? (unsigned int)atoi(argv[2]) : 1080;
        if (width < 640 || height < 480) { width = 1920; height = 1080; }

        Class Descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class Display    = NSClassFromString(@"CGVirtualDisplay");
        Class Settings   = NSClassFromString(@"CGVirtualDisplaySettings");
        Class Mode       = NSClassFromString(@"CGVirtualDisplayMode");
        if (!Descriptor || !Display || !Settings || !Mode) {
            fprintf(stderr, "This version of macOS doesn't support virtual displays.\n");
            return 2;
        }

        CGVirtualDisplayDescriptor *descriptor = [[Descriptor alloc] init];
        [descriptor setDispatchQueue:dispatch_get_main_queue()];
        descriptor.name = @"TV Mirror Display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 0.37, height * 0.37);  // like a ~32" TV
        descriptor.vendorID = 0x7456;   // made-up IDs so macOS remembers this "monitor"
        descriptor.productID = 0x4D52;
        descriptor.serialNum = 0x0001;
        descriptor.terminationHandler = ^(id unused, CGVirtualDisplay *display) {
            fprintf(stderr, "The virtual screen was removed by macOS.\n");
            exit(1);
        };

        CGVirtualDisplay *display = [[Display alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == 0) {
            fprintf(stderr, "Couldn't create the virtual screen.\n");
            return 3;
        }

        CGVirtualDisplaySettings *settings = [[Settings alloc] init];
        settings.hiDPI = 0;   // 1 screen pixel = 1 TV pixel
        settings.modes = @[ [[Mode alloc] initWithWidth:width height:height refreshRate:60] ];
        if (![display applySettings:settings]) {
            fprintf(stderr, "Couldn't set the virtual screen to %ux%u.\n", width, height);
            return 4;
        }

        CGDirectDisplayID newID = display.displayID;

        // macOS sometimes adds a new screen as a *mirror* of the main one.
        // A mirror isn't a separate screen, so switch that off.
        if (CGDisplayIsInMirrorSet(newID)) {
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
                CGConfigureDisplayMirrorOfDisplay(config, newID, kCGNullDirectDisplay);
                CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            }
        }

        printf("%u\n", newID);
        fflush(stdout);

        // Two seconds later, report how macOS sees the new screen (for troubleshooting).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CGDirectDisplayID online[16], active[16];
            uint32_t nOnline = 0, nActive = 0;
            CGGetOnlineDisplayList(16, online, &nOnline);
            CGGetActiveDisplayList(16, active, &nActive);
            int isOnline = 0, isActive = 0;
            for (uint32_t i = 0; i < nOnline; i++) if (online[i] == newID) isOnline = 1;
            for (uint32_t i = 0; i < nActive; i++) if (active[i] == newID) isActive = 1;
            CGRect b = CGDisplayBounds(newID);
            fprintf(stderr,
                    "[vdisplay] id=%u online=%d active=%d mirrored=%d asleep=%d size=%.0fx%.0f at %.0f,%.0f "
                    "| online screens=%u active screens=%u\n",
                    newID, isOnline, isActive, (int)CGDisplayIsInMirrorSet(newID),
                    (int)CGDisplayIsAsleep(newID), b.size.width, b.size.height, b.origin.x, b.origin.y,
                    nOnline, nActive);
            fflush(stderr);
        });

        signal(SIGTERM, quit);
        signal(SIGINT, quit);
        // Keep running (and keep the screen alive) until TV Mirror stops us.
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
