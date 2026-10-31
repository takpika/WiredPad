#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 6) return 2;
    CGDirectDisplayID display = (CGDirectDisplayID)strtoul(argv[1], NULL, 10);
    size_t width = (size_t)strtoul(argv[2], NULL, 10);
    size_t height = (size_t)strtoul(argv[3], NULL, 10);
    size_t logicalWidth = (size_t)strtoul(argv[4], NULL, 10);
    size_t logicalHeight = (size_t)strtoul(argv[5], NULL, 10);
    CFStringRef key = kCGDisplayShowDuplicateLowResolutionModes;
    CFBooleanRef value = kCFBooleanTrue;
    CFDictionaryRef options = CFDictionaryCreate(NULL, (const void **)&key, (const void **)&value,
                                                 1, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    for (int attempt = 0; attempt < 30; ++attempt) {
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, options);
        if (modes) {
            for (int pass = 0; pass < 2; ++pass) {
                for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i) {
                    CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                    if (CGDisplayModeGetPixelWidth(mode) != width ||
                        CGDisplayModeGetPixelHeight(mode) != height) continue;
                    bool hidpi = CGDisplayModeGetWidth(mode) == logicalWidth &&
                                 CGDisplayModeGetHeight(mode) == logicalHeight;
                    bool native = CGDisplayModeGetWidth(mode) == width &&
                                  CGDisplayModeGetHeight(mode) == height;
                    if ((pass == 0 && !hidpi) || (pass == 1 && !native)) continue;
                    CGDisplayConfigRef config = NULL;
                    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) continue;
                    CGError configured = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
                    CGError completed = configured == kCGErrorSuccess
                        ? CGCompleteDisplayConfiguration(config, kCGConfigureForSession)
                        : CGCancelDisplayConfiguration(config);
                    if (configured == kCGErrorSuccess && completed == kCGErrorSuccess) {
                        printf("%s\n", hidpi ? "hidpi" : "native");
                        CFRelease(modes);
                        CFRelease(options);
                        return 0;
                    }
                }
            }
            CFRelease(modes);
        }
        usleep(100000);
    }
    CFRelease(options);
    fprintf(stderr, "No native-pixel display mode found\n");
    return 1;
}
