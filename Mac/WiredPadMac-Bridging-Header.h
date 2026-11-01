#import <Foundation/Foundation.h>
#include <stdint.h>

uint32_t WiredPadCreateDisplay(uint32_t width, uint32_t height, uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate, uint32_t pixelsPerInch);
BOOL WiredPadResizeDisplay(uint32_t width, uint32_t height, uint32_t logicalWidth, uint32_t logicalHeight, uint32_t refreshRate);
void WiredPadDestroyDisplay(void);
const char *WiredPadDisplayError(void);
const char *WiredPadCopyDisplayUUID(uint32_t displayID);
int WiredPadConnectUSB(uint16_t port);
const char *WiredPadUSBError(void);
NSData *WiredPadTouchReportDescriptor(void);
