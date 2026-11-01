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
@end

static id heldDisplay;
static NSString *displayError;
static NSString *lastDisplayUUID;

static id displaySettings(Class settingsClass, Class modeClass, uint32_t width, uint32_t height,
                          uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate) {
    CGVirtualDisplayMode *mode = [(CGVirtualDisplayMode *)[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplayMode *logicalMode = [(CGVirtualDisplayMode *)[modeClass alloc]
                                         initWithWidth:logicalWidth height:logicalHeight refreshRate:refreshRate];
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

const char *WiredPadDisplayError(void) {
    return displayError.UTF8String ?: "Unknown virtual display error";
}

uint32_t WiredPadCreateDisplay(uint32_t width, uint32_t height, uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate, uint32_t pixelsPerInch) {
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
        [descriptor setValue:@(0x5750) forKey:@"vendorID"];
        [descriptor setValue:@((width ^ (height << 1)) & 0xffff) forKey:@"productID"];
        // Serial 1 was turned with a private WindowServer call in a test build, and macOS
        // remembers that per display; a new serial starts unturned.
        [descriptor setValue:@(0x0002) forKey:@"serialNum"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize((double)width * 25.4 / pixelsPerInch,
                                                              (double)height * 25.4 / pixelsPerInch)]
                         forKey:@"sizeInMillimeters"];
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
