#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <unistd.h>

// Test-only runtime declarations. The setup follows Chromium's display tests:
// https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
@interface NSObject (FluxProbeDisplay)
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setSerialNumber:(unsigned int)value;
- (void)setName:(NSString *)value;
- (void)setQueue:(id)value;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setWhitePoint:(CGPoint)value;
- (void)setRedPrimary:(CGPoint)value;
- (void)setGreenPrimary:(CGPoint)value;
- (void)setBluePrimary:(CGPoint)value;
- (void)setHiDPI:(unsigned int)value;
- (void)setModes:(NSArray *)value;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static id display;

unsigned int FluxProbeCreateDisplay(void) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) return 0;
    id descriptor = [[descriptorClass alloc] init];
    unsigned int serial = (unsigned int)getpid();
    [descriptor setVendorID:505];
    [descriptor setProductID:0];
    [descriptor setSerialNum:serial];
    [descriptor setSerialNumber:serial];
    [descriptor setName:@"Flux probe display"];
    [descriptor setQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    [descriptor setMaxPixelsWide:1920];
    [descriptor setMaxPixelsHigh:1080];
    [descriptor setSizeInMillimeters:CGSizeMake(390.144, 219.456)];
    [descriptor setWhitePoint:CGPointMake(.3125, .3291)];
    [descriptor setRedPrimary:CGPointMake(.6797, .3203)];
    [descriptor setGreenPrimary:CGPointMake(.2559, .6983)];
    [descriptor setBluePrimary:CGPointMake(.1494, .0557)];
    display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) return 0;
    id mode = [[modeClass alloc] initWithWidth:1920 height:1080 refreshRate:60];
    id settings = [[settingsClass alloc] init];
    [settings setHiDPI:0];
    [settings setModes:@[mode]];
    if (![display applySettings:settings]) return 0;
    CGDirectDisplayID identifier = [display displayID];
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return 0;
    if (CGConfigureDisplayOrigin(config, identifier,
                                (int32_t)CGRectGetMaxX(CGDisplayBounds(CGMainDisplayID())),
                                0) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return 0;
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) != kCGErrorSuccess) return 0;
    return identifier;
}
