#include "WiredPadTouchDriver.h"
#include <DriverKit/IOLib.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSBoolean.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSString.h>
#include <HIDDriverKit/IOHIDEventServiceKeys.h>
#include <HIDDriverKit/IOHIDDigitizerStructs.h>
#include <string.h>

struct WiredPadTouchDriver_IVars {
    uint32_t reportCount;
    uint32_t dispatchCount;
    uint32_t maxTouchCount;
    bool previousDown[10];
    uint16_t previousX[10];
    uint16_t previousY[10];
};

static void putNumber(OSDictionary *properties, const char *key, uint64_t value) {
    OSNumber *number = OSNumber::withNumber(value, 32);
    if (number) {
        properties->setObject(key, number);
        number->release();
    }
}

bool WiredPadTouchDriver::init() {
    if (!super::init()) return false;
    ivars = IONewZero(WiredPadTouchDriver_IVars, 1);
    return ivars != nullptr;
}

void WiredPadTouchDriver::free() {
    if (ivars) IODelete(static_cast<WiredPadTouchDriver_IVars *>(ivars), WiredPadTouchDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(WiredPadTouchDriver, Start) {
    kern_return_t result = Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;

    OSContainer *property = nullptr;
    if (provider->SearchProperty("CGDirectDisplayID", "IOService",
                                 kIOServiceSearchPropertyParents, &property) == kIOReturnSuccess && property) {
        OSNumber *number = OSDynamicCast(OSNumber, property);
        if (number) {
            OSDictionary *properties = OSDictionary::withCapacity(3);
            if (properties) {
                properties->setObject("CGDirectDisplayID", number);
                properties->setObject("DisplayIntegrated", kOSBooleanTrue);
                OSContainer *serialNumber = nullptr;
                if (provider->SearchProperty("SerialNumber", "IOService",
                                             kIOServiceSearchPropertyParents, &serialNumber) == kIOReturnSuccess && serialNumber) {
                    OSString *identifier = OSDynamicCast(OSString, serialNumber);
                    if (identifier) properties->setObject("displayUUID", identifier);
                    serialNumber->release();
                }
                SetProperties(properties);
                properties->release();
            }
        }
        property->release();
    }
    RegisterService();
    return kIOReturnSuccess;
}

bool WiredPadTouchDriver::handleStart(IOService *provider) {
    OSDictionary *properties = OSDictionary::withCapacity(1);
    if (!properties) return false;
    properties->setObject(kIOHIDEventDriverHandlesReport, kOSBooleanTrue);
    const kern_return_t result = SetProperties(properties);
    properties->release();
    IOLog("WiredPadTouchDriver handleStart SetProperties=0x%x\n", result);
    return result == kIOReturnSuccess && super::handleStart(provider);
}

void WiredPadTouchDriver::handleReport(uint64_t timestamp, uint8_t *report,
                                      uint32_t reportLength, IOHIDReportType type,
                                      uint32_t reportID) {
    auto *state = static_cast<WiredPadTouchDriver_IVars *>(ivars);
    ++state->reportCount;
    if (state->reportCount <= 16) {
        OSDictionary *properties = OSDictionary::withCapacity(5);
        if (properties) {
            putNumber(properties, "WiredPadReportCount", state->reportCount);
            putNumber(properties, "WiredPadReportLength", reportLength);
            putNumber(properties, "WiredPadReportType", type);
            putNumber(properties, "WiredPadReportID", reportID);
            putNumber(properties, "WiredPadFirstByte", report && reportLength ? report[0] : 0);
            SetProperties(properties);
            properties->release();
        }
        IOLog("WiredPadTouchDriver report=%u length=%u type=%u id=%u first=%u\n",
              state->reportCount, reportLength, type, reportID,
              report && reportLength ? report[0] : 0);
    }
    if (type != kIOHIDReportTypeInput || reportID != 1 || !report) return;
    const uint32_t base = reportLength == 62 && report[0] == 1 ? 1 : 0;
    if (reportLength < base + 61) return;

    IOHIDDigitizerTouchData touches[10] = {};
    uint32_t touchCount = 0;
    for (uint32_t i = 0; i < 10; ++i) {
        const uint32_t offset = base + i * 6;
        const bool down = (report[offset] & 1) != 0;
        if (!down && !state->previousDown[i]) continue;
        const uint16_t x = down
            ? uint16_t(report[offset + 2]) | (uint16_t(report[offset + 3]) << 8)
            : state->previousX[i];
        const uint16_t y = down
            ? uint16_t(report[offset + 4]) | (uint16_t(report[offset + 5]) << 8)
            : state->previousY[i];
        auto &touch = touches[touchCount++];
        touch.identifier = i;
        touch.x = static_cast<IOFixed>((uint32_t(x) * 65536U) / 32767U);
        touch.y = static_cast<IOFixed>((uint32_t(y) * 65536U) / 32767U);
        touch.inRange = down;
        touch.touch = down;
        touch.touchValid = true;
        touch.touchChanged = down != state->previousDown[i];
        touch.positionChanged = x != state->previousX[i] || y != state->previousY[i];
        touch.rangeChanged = touch.touchChanged;
        state->previousDown[i] = down;
        state->previousX[i] = x;
        state->previousY[i] = y;
    }
    if (touchCount) {
        if (touchCount > state->maxTouchCount) state->maxTouchCount = touchCount;
        const kern_return_t result = dispatchDigitizerTouchEvent(timestamp, touches, touchCount);
        ++state->dispatchCount;
        if (state->dispatchCount <= 16) {
            OSDictionary *properties = OSDictionary::withCapacity(4);
            if (properties) {
                putNumber(properties, "WiredPadDispatchCount", state->dispatchCount);
                putNumber(properties, "WiredPadTouchCount", touchCount);
                putNumber(properties, "WiredPadMaxTouchCount", state->maxTouchCount);
                putNumber(properties, "WiredPadDispatchResult", result);
                SetProperties(properties);
                properties->release();
            }
        }
        if (state->dispatchCount <= 16 || result != kIOReturnSuccess) {
            IOLog("WiredPadTouchDriver dispatch=%u contacts=%u result=0x%x\n",
                  state->dispatchCount, touchCount, result);
        }
    }
}
