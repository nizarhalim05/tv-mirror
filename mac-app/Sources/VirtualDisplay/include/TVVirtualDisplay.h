#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

/// An invisible extra screen ("virtual display") that macOS always draws, even when
/// you're on another desktop. TellyBeam records it and sends it to the TV.
@interface TVVirtualDisplay : NSObject

- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height;

/// Creates the screen. Calls back on the main queue with its display ID once macOS has
/// switched it on (macOS may first ask the user how to use it), or with 0 and a message
/// if that didn't happen within `timeout` seconds.
- (void)startWithTimeout:(NSTimeInterval)timeout
              completion:(void (^)(uint32_t displayID, NSString *_Nullable message))completion;

/// Removes the screen (its windows move back to your other screens).
- (void)stop;

@property (nonatomic, readonly) uint32_t displayID;

@end

/// A small floating window on a real screen that shows another screen live.
/// Clicking it makes the mouse pointer jump to the same spot on that screen.
/// It shows the pictures TellyBeam is already recording for the TV (call showSurface:),
/// so it doesn't need a second recording or another macOS permission prompt.
@interface TVPreviewWindow : NSObject

- (instancetype)initWithDisplayID:(uint32_t)displayID width:(unsigned)width height:(unsigned)height;
- (BOOL)start;
/// Shows one recorded picture. Call on the main thread.
- (void)showSurface:(IOSurfaceRef)surface;
- (void)show;
- (void)hide;
- (void)stop;

@property (nonatomic, readonly, getter=isVisible) BOOL visible;

@end

NS_ASSUME_NONNULL_END
