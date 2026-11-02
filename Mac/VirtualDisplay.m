#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import "WiredPadMac-Bridging-Header.h"

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setTerminationHandler:(void (^)(id, id))handler;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(id)settings;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate
             transferFunction:(uint32_t)transferFunction;
@end

static id heldDisplay;
static NSString *displayError;
static NSString *lastDisplayUUID;
static BOOL heldDisplayHDR;
static BOOL heldDisplayWideColor;
/// The mode transfer function that makes macOS treat a virtual display as able to show EDR.
static const uint32_t hdrTransferFunction = 1;

static CGError setDisplayEnabled(uint32_t displayID, bool enabled) {
    typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
    ConfigureEnabled configureEnabled = (ConfigureEnabled)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    if (!configureEnabled) return kCGErrorNotImplemented;
    CGDisplayConfigRef config = NULL;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result != kCGErrorSuccess) return result;
    result = configureEnabled(config, displayID, enabled);
    if (result != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return result;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
}

/// corebrightnessd enrolls displays only as they are hot-plugged, and a new virtual display
/// is not; turning it off and on again goes through WindowServer's hotplug path, so the
/// display gets its brightness control (see CoreBrightnessDevice) without a restart.
int WiredPadReplugDisplay(uint32_t displayID) {
    CGError result = setDisplayEnabled(displayID, false);
    return result == kCGErrorSuccess ? setDisplayEnabled(displayID, true) : result;
}

static id displaySettings(Class settingsClass, Class modeClass, uint32_t width, uint32_t height,
                          uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate) {
    uint32_t transfer = heldDisplayHDR ? hdrTransferFunction : 0;
    CGVirtualDisplayMode *mode = [(CGVirtualDisplayMode *)[modeClass alloc]
                                  initWithWidth:width height:height refreshRate:refreshRate transferFunction:transfer];
    CGVirtualDisplayMode *logicalMode = [(CGVirtualDisplayMode *)[modeClass alloc]
                                         initWithWidth:logicalWidth height:logicalHeight refreshRate:refreshRate
                                         transferFunction:transfer];
    id settings = [settingsClass new];
    [settings setValue:@[mode, logicalMode] forKey:@"modes"];
    [settings setValue:@1 forKey:@"hiDPI"];
    return settings;
}

/// Replaces the held display's modes. The size must fit the maximum it was created with.
BOOL WiredPadResizeDisplay(uint32_t width, uint32_t height, uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate) {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!heldDisplay || !modeClass || !settingsClass) return NO;
    @try {
        return [heldDisplay applySettings:displaySettings(settingsClass, modeClass, width, height,
                                                          logicalWidth, logicalHeight, refreshRate)];
    } @catch (NSException *exception) {
        return NO;
    }
}

void WiredPadDestroyDisplay(void) {
    // Destroying a virtual display is no unplug to corebrightnessd, which would keep its
    // brightness control around; turning it off first removes that.
    if (heldDisplay) setDisplayEnabled((uint32_t)[[heldDisplay valueForKey:@"displayID"] unsignedIntValue], false);
    heldDisplay = nil;
    lastDisplayUUID = nil;
}

const char *WiredPadCopyDisplayUUID(uint32_t displayID) {
    typedef CGError (*CopyDisplayUUID)(uint32_t, CFUUIDRef *);
    void *coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    CopyDisplayUUID copyUUID = coreGraphics ? (CopyDisplayUUID)dlsym(coreGraphics, "CGSCopyDisplayUUID") : NULL;
    if (!copyUUID) {
        NSLog(@"WiredPad CGSCopyDisplayUUID symbol unavailable: %s", dlerror() ?: "unknown");
        return NULL;
    }
    CFUUIDRef uuid = NULL;
    CGError result = kCGErrorFailure;
    for (int attempt = 0; attempt < 30; ++attempt) {
        result = copyUUID(displayID, &uuid);
        if (result == kCGErrorSuccess && uuid) break;
        usleep(100000);
    }
    if (result != kCGErrorSuccess || !uuid) {
        NSLog(@"WiredPad CGSCopyDisplayUUID display=%u error=%d", displayID, result);
        return NULL;
    }
    lastDisplayUUID = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    return lastDisplayUUID.UTF8String;
}

int WiredPadNativeBrightnessCapability(uint32_t displayID) {
    void *library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (!library) return -1;
    bool (*canChange)(uint32_t) = (bool (*)(uint32_t))dlsym(library, "DisplayServicesCanChangeBrightness");
    return canChange ? (canChange(displayID) ? 1 : 0) : -1;
}

const char *WiredPadDisplayError(void) {
    return displayError.UTF8String ?: "Unknown virtual display error";
}

uint32_t WiredPadCreateDisplay(uint32_t width, uint32_t height, uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate, uint32_t pixelsPerInch, BOOL hdr, BOOL wideColor) {
    // A display kept from an earlier session is reused unless its dynamic range or gamut differs.
    if (heldDisplay && (heldDisplayHDR != hdr || heldDisplayWideColor != wideColor)) WiredPadDestroyDisplay();
    heldDisplayHDR = hdr;
    heldDisplayWideColor = wideColor;
    if (heldDisplay) {
        return (uint32_t)[[heldDisplay valueForKey:@"displayID"] unsignedIntValue];
    }
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descriptorClass || !displayClass || !modeClass || !settingsClass) {
        displayError = @"display.error.unavailable";
        return 0;
    }
    @try {
        CGVirtualDisplayDescriptor *descriptor = [descriptorClass new];
        [descriptor setValue:@"WiredPad" forKey:@"name"];
        // Room for the screen either way up, so a portrait iPad gets a portrait mode.
        uint32_t longSide = MAX(width, height);
        [descriptor setValue:@(longSide) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(longSide) forKey:@"maxPixelsHigh"];
        // corebrightnessd gives Apple's legacy display IDs a HID brightness control, which
        // CoreBrightnessDevice provides; other IDs get a display with no brightness at all.
        // Of those IDs, macOS's override file for the Thunderbolt Display sets only a name,
        // while the LED Cinema Display ones also replace the primaries and gamma.
        [descriptor setValue:@(0x0610) forKey:@"vendorID"];
        [descriptor setValue:@(0x9227) forKey:@"productID"];
        // Serial 1 was turned with a private WindowServer call in a test build, and macOS
        // remembers that per display; a new serial starts unturned.
        [descriptor setValue:@(0x0002) forKey:@"serialNum"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize((double)width * 25.4 / pixelsPerInch,
                                                              (double)height * 25.4 / pixelsPerInch)]
                         forKey:@"sizeInMillimeters"];
        // The iPad's own gamut, Display P3 or sRGB, with a D65 white. macOS also plays HDR
        // video only on a wide-gamut external display, whatever its EDR headroom.
        BOOL p3 = wideColor;
        [descriptor setValue:[NSValue valueWithPoint:p3 ? NSMakePoint(0.680, 0.320) : NSMakePoint(0.640, 0.330)]
                      forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:p3 ? NSMakePoint(0.265, 0.690) : NSMakePoint(0.300, 0.600)]
                      forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.150, 0.060)] forKey:@"bluePrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)] forKey:@"whitePoint"];
        dispatch_queue_t queue = dispatch_get_main_queue();
        [descriptor setQueue:queue];
        void (^termination)(id, id) = ^(id _unused, id _display) {};
        [descriptor setTerminationHandler:termination];

        CGVirtualDisplay *display = [(CGVirtualDisplay *)[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            displayError = @"display.error.create";
            return 0;
        }
        BOOL ok = [display applySettings:displaySettings(settingsClass, modeClass, width, height,
                                                         logicalWidth, logicalHeight, refreshRate)];
        if (!ok) {
            displayError = @"display.error.mode";
            return 0;
        }
        heldDisplay = display;
        return (uint32_t)[[display valueForKey:@"displayID"] unsignedIntValue];
    } @catch (NSException *exception) {
        displayError = exception.reason ?: @"Virtual display API failed.";
        return 0;
    }
}
