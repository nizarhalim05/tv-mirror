// The invisible extra screen and the mini screen, using macOS's built-in (undocumented)
// CGVirtualDisplay and CGDisplayStream. Same approach as vdisplay.m in the Terminal version.

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#import "TVVirtualDisplay.h"

// ---- Declarations for the undocumented CoreGraphics classes ----------------------

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

static BOOL TVDisplayIsOnline(CGDirectDisplayID displayID) {
    CGDirectDisplayID online[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, online, &count);
    for (uint32_t i = 0; i < count; i++) if (online[i] == displayID) return YES;
    return NO;
}

// ---- The extra screen ---------------------------------------------------------------

@implementation TVVirtualDisplay {
    CGVirtualDisplay *_display;
    dispatch_queue_t _queue;
    unsigned _width, _height;
    BOOL _stopped;
}

- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height {
    if ((self = [super init])) {
        _width = width;
        _height = height;
        // macOS asks the app "the screens changed, OK?" while a screen is added, and
        // waits only a quarter of a second for the answer from the main thread. So the
        // screen is created on this separate queue, keeping the main thread free.
        _queue = dispatch_queue_create("tvmirror.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (CGVirtualDisplay *)createDisplay:(NSString **)error {
    Class Descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class Display = NSClassFromString(@"CGVirtualDisplay");
    Class Settings = NSClassFromString(@"CGVirtualDisplaySettings");
    Class Mode = NSClassFromString(@"CGVirtualDisplayMode");
    if (!Descriptor || !Display || !Settings || !Mode) {
        *error = @"This version of macOS doesn't support extra screens.";
        return nil;
    }
    CGVirtualDisplayDescriptor *descriptor = [[Descriptor alloc] init];
    [descriptor setDispatchQueue:_queue];
    descriptor.name = @"TV Mirror Display";
    descriptor.maxPixelsWide = _width;
    descriptor.maxPixelsHigh = _height;
    descriptor.sizeInMillimeters = CGSizeMake(_width * 0.37, _height * 0.37);  // like a ~32" TV
    descriptor.vendorID = 0x7456;
    descriptor.productID = 0x4D52;
    descriptor.serialNum = 0x0001;
    descriptor.terminationHandler = ^(id unused, CGVirtualDisplay *display) {};

    CGVirtualDisplay *display = [[Display alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) {
        *error = @"Couldn't create the extra screen.";
        return nil;
    }
    CGVirtualDisplaySettings *settings = [[Settings alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[ [[Mode alloc] initWithWidth:_width height:_height refreshRate:60] ];
    if (![display applySettings:settings]) {
        *error = @"Couldn't set up the extra screen.";
        return nil;
    }
    return display;
}

- (void)startWithTimeout:(NSTimeInterval)timeout
              completion:(void (^)(uint32_t, NSString *))completion {
    _stopped = NO;
    dispatch_async(_queue, ^{
        NSString *error = nil;
        CGVirtualDisplay *display = [self createDisplay:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!display) {
                completion(0, error ?: @"Couldn't create the extra screen.");
                return;
            }
            self->_display = display;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
            [self waitUntilOnline:display.displayID deadline:deadline completion:completion];
        });
    });
}

// macOS may show its own window asking how to use the new screen; it stays off until
// the user answers, so keep checking until the deadline.
- (void)waitUntilOnline:(CGDirectDisplayID)displayID
               deadline:(NSDate *)deadline
             completion:(void (^)(uint32_t, NSString *))completion {
    if (_stopped) return;
    if (TVDisplayIsOnline(displayID)) {
        if (CGDisplayIsInMirrorSet(displayID)) {   // a mirror isn't a separate screen
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
                CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            }
        }
        _displayID = displayID;
        completion(displayID, nil);
        return;
    }
    if ([deadline timeIntervalSinceNow] <= 0) {
        [self stop];
        completion(0, @"macOS didn't switch the extra screen on. Try again, and choose "
                      @"Extend in the window macOS shows.");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        [self waitUntilOnline:displayID deadline:deadline completion:completion];
    });
}

- (void)stop {
    _stopped = YES;
    _displayID = 0;
    CGVirtualDisplay *display = _display;
    _display = nil;
    if (display) {
        dispatch_async(_queue, ^{ (void)display; });   // released here, off the main thread
    }
}

@end

// ---- The mini screen -------------------------------------------------------------

typedef void *TVStreamRef;
typedef void (^TVFrameHandler)(int32_t status, uint64_t displayTime, void *frameSurface, const void *updateRef);
typedef TVStreamRef (*TVStreamCreateFn)(CGDirectDisplayID display, size_t outputWidth, size_t outputHeight,
                                        int32_t pixelFormat, CFDictionaryRef properties,
                                        dispatch_queue_t queue, TVFrameHandler handler);
typedef CGError (*TVStreamStartFn)(TVStreamRef stream);
typedef CGError (*TVStreamStopFn)(TVStreamRef stream);

@interface TVPreviewView : NSView
@property (nonatomic) CGDirectDisplayID targetDisplay;
@end

@implementation TVPreviewView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event {
    NSRect bounds = self.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat rx = MAX(0.0, MIN(1.0, p.x / bounds.size.width));
    CGFloat ry = MAX(0.0, MIN(1.0, 1.0 - p.y / bounds.size.height));   // screens count from the top
    CGRect tv = CGDisplayBounds(self.targetDisplay);
    CGWarpMouseCursorPosition(CGPointMake(tv.origin.x + rx * (tv.size.width - 1),
                                          tv.origin.y + ry * (tv.size.height - 1)));
    CGAssociateMouseAndMouseCursorPosition(1);
}
@end

@implementation TVPreviewWindow {
    CGDirectDisplayID _displayID;
    unsigned _width, _height;
    NSWindow *_window;
    TVPreviewView *_view;
    TVStreamRef _stream;
    NSTimer *_timer;
}

- (instancetype)initWithDisplayID:(uint32_t)displayID width:(unsigned)width height:(unsigned)height {
    if ((self = [super init])) {
        _displayID = displayID;
        _width = width;
        _height = height;
    }
    return self;
}

- (BOOL)isVisible { return _window.visible; }

- (BOOL)start {
    // Looked up while running: newer macOS SDKs hide CGDisplayStream
    TVStreamCreateFn create = (TVStreamCreateFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    TVStreamStartFn start = (TVStreamStartFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    if (!create || !start) return NO;

    NSScreen *home = nil;   // one of your real screens
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number && number.unsignedIntValue != _displayID) { home = screen; break; }
    }
    if (!home) return NO;
    NSRect area = home.visibleFrame;
    CGFloat w = 480, h = round(w * _height / _width);
    NSRect frame = NSMakeRect(NSMaxX(area) - w - 20, NSMinY(area) + 20, w, h);

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"TV screen (live)";
    _window.releasedWhenClosed = NO;
    _window.contentAspectRatio = NSMakeSize(_width, _height);
    _window.contentMinSize = NSMakeSize(240, round(240.0 * _height / _width));
    _window.level = NSFloatingWindowLevel;
    _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
    _view = [[TVPreviewView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    _view.targetDisplay = _displayID;
    _view.wantsLayer = YES;
    _view.layer.backgroundColor = NSColor.blackColor.CGColor;
    _view.layer.contentsGravity = kCAGravityResizeAspect;
    _window.contentView = _view;

    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    CFStringRef *showCursor = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCGDisplayStreamShowCursor");
    CFStringRef *minFrameTime = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCGDisplayStreamMinimumFrameTime");
    if (showCursor && *showCursor) props[(__bridge NSString *)*showCursor] = @YES;
    if (minFrameTime && *minFrameTime) props[(__bridge NSString *)*minFrameTime] = @(1.0 / 30.0);

    TVPreviewView *view = _view;
    _stream = create(_displayID, (size_t)(w * 2), (size_t)(h * 2), 0x42475241 /* 'BGRA' */,
                     (__bridge CFDictionaryRef)props, dispatch_get_main_queue(),
                     ^(int32_t status, uint64_t displayTime, void *frameSurface, const void *updateRef) {
        if (status == 0 && frameSurface) view.layer.contents = (__bridge id)frameSurface;
    });
    if (!_stream || start(_stream) != kCGErrorSuccess) {
        _stream = NULL;
        return NO;
    }
    [_window orderFrontRegardless];

    __weak NSWindow *window = _window;
    CGDirectDisplayID displayID = _displayID;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        NSScreen *tv = nil;
        for (NSScreen *screen in [NSScreen screens]) {
            NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
            if (number && number.unsignedIntValue == displayID) tv = screen;
        }
        BOOL onTV = tv && NSPointInRect([NSEvent mouseLocation], tv.frame);
        NSString *title = onTV ? @"TV screen (live) - your mouse pointer is on the TV"
                               : @"TV screen (live) - click here to move the pointer to the TV";
        if (![window.title isEqualToString:title]) window.title = title;
    }];
    return YES;
}

- (void)show { [_window orderFrontRegardless]; }
- (void)hide { [_window orderOut:nil]; }

- (void)stop {
    [_timer invalidate];
    _timer = nil;
    if (_stream) {
        TVStreamStopFn stop = (TVStreamStopFn)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
        if (stop) stop(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    [_window orderOut:nil];
    _window = nil;
}

@end
