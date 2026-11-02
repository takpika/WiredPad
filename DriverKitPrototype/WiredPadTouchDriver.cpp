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
    bool penInRange;
    bool penTip;
    IOFixed penX;
    IOFixed penY;
    uint32_t penClick;
    uint64_t registryID;
};

static void putNumber(OSDictionary *properties, const char *key, uint64_t value) {
    OSNumber *number = OSNumber::withNumber(value, 32);
    if (number) {
        properties->setObject(key, number);
        number->release();
    }
}

// HIDDriverKit exports IOHIDEvent but its public headers only declare the name. This is the
// exported call this driver uses, as the library spells it.
class IOHIDEvent : public OSObject {
public:
    static IOHIDEvent *vendorDefinedEvent(uint64_t timestamp, uint32_t usagePage, uint32_t usage,
                                          uint32_t version, uint8_t *data, uint32_t length,
                                          uint32_t options);
};

namespace {
// WindowServer's event records, as its HID event translator and Sidecar both hand them over:
// a vendor event, page 0xFF00 usage 0x18, carrying one 124-byte record. WindowServer takes the
// first 0x58 bytes as they are, the location a point on the global display space.
constexpr uint32_t recordUsagePage = 0xFF00, recordUsage = 0x18;
enum : uint32_t {
    mouseDown = 1, mouseUp = 2, mouseMoved = 5, mouseDragged = 6, systemDefined = 14,
    tabletPointer = 23, tabletProximity = 24
};
constexpr uint8_t subtypeTabletPoint = 1, subtypeTabletProximity = 2;
constexpr int16_t subtypeAuxMouseButtons = 7;
constexpr uint8_t pointerPen = 1;
// Device ID, absolute X and Y, buttons, tilt X and Y, pressure.
constexpr uint32_t tabletCapabilities = 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400;
constexpr uint16_t penVendorID = 0x5750, penTabletID = 3, penDeviceID = 0x5750;
constexpr uint64_t penUniqueID = 0x5750'0003'0000'0001ULL;

struct __attribute__((packed)) TabletPoint {
    int32_t x, y, z;
    uint16_t buttons, pressure;
    int16_t tiltX, tiltY;
    uint16_t rotation;
    int16_t tangentialPressure;
    uint16_t deviceID;
    int16_t vendor[3];
};

struct __attribute__((packed)) TabletProximity {
    uint16_t vendorID, tabletID, pointerID, deviceID, systemTabletID, vendorPointerType;
    uint32_t pointerSerialNumber;
    uint64_t uniqueID;
    uint32_t capabilityMask;
    uint8_t pointerType, enterProximity;
    int16_t reserved;
};

union Tablet {
    TabletPoint point;
    TabletProximity proximity;
};

struct __attribute__((packed)) MouseButton {
    uint8_t subX, subY;
    int16_t eventNumber;
    int32_t clickCount;
    uint8_t pressure, buttonNumber, subtype, reserved;
    int32_t reserved2;
    Tablet tablet;
};

struct __attribute__((packed)) MouseMove {
    int32_t deltaX, deltaY;
    uint8_t subX, subY, subtype, reserved;
    int32_t reserved2;
    Tablet tablet;
};

// A system-defined event; subtype 7 tells WindowServer which mouse buttons changed (data1) and
// which are now down (data2), which is how it keeps the system's button state.
struct __attribute__((packed)) SystemDefined {
    int16_t reserved, subtype;
    int32_t data1, data2;
    int32_t misc[9];
};

struct __attribute__((packed)) EventRecord {
    uint32_t type;
    int32_t x, y;
    uint64_t timestamp;
    uint32_t flags, window;
    uint64_t senderID;
    uint32_t reserved;
    union {
        MouseButton button;
        MouseMove move;
        SystemDefined system;
        TabletPoint point;
        TabletProximity proximity;
        uint8_t bytes[48];
    } data;
    uint32_t locationFlags;
    uint8_t auditToken[32];
};
static_assert(sizeof(TabletPoint) == 32 && sizeof(TabletProximity) == 32, "tablet data layout");
static_assert(sizeof(MouseButton) == 48 && sizeof(MouseMove) == 48 && sizeof(SystemDefined) == 48,
              "event data layout");
static_assert(sizeof(EventRecord) == 0x7C, "event record layout");
}

/// Report 2 holds one Apple Pencil: flags, x and y as 16.16 fixed point points on the global
/// display space, pressure 0...32767, tilt x and y in degrees, twist in degrees.
///
/// macOS's translator for HID digitizer events keeps a stylus's pressure and tilt to separate
/// tablet events and leaves the mouse events it makes without them, so apps that read
/// pressure from their mouse events see none. Sidecar gives WindowServer finished event
/// records instead, with the tablet values in each mouse event, and so does this, in the
/// order Sidecar sends them:
///   pen arrives   proximity, a move carrying the proximity, button 1 down, mouse down
///   pen moves     drag, or a tablet point when only pressure or tilt changed
///   pen lifts     button 1 up, mouse up, proximity
void WiredPadTouchDriver::handlePen(uint64_t timestamp, uint8_t *report, uint32_t reportLength) {
    auto *state = static_cast<WiredPadTouchDriver_IVars *>(ivars);
    const uint32_t base = reportLength == 16 && report[0] == 2 ? 1 : 0;
    if (reportLength < base + 15) return;
    const uint8_t *pen = report + base;
    auto read32 = [&](uint32_t offset) {
        return int32_t(uint32_t(pen[offset]) | (uint32_t(pen[offset + 1]) << 8) |
                       (uint32_t(pen[offset + 2]) << 16) | (uint32_t(pen[offset + 3]) << 24));
    };
    const bool tip = (pen[0] & 1) != 0;
    const bool inRange = tip || (pen[0] & (1 << 4)) != 0;
    const IOFixed x = read32(1);
    const IOFixed y = read32(5);
    const uint16_t pressure = uint16_t(pen[9]) | (uint16_t(pen[10]) << 8);
    const int8_t tiltX = int8_t(pen[11]), tiltY = int8_t(pen[12]);

    TabletPoint point = {};
    point.x = x / 256;  // 1/256 point
    point.y = y / 256;
    point.pressure = tip ? uint16_t((uint32_t(pressure) * 65535U) / 32767U) : 0;
    point.tiltX = int16_t(int32_t(tiltX) * 32767 / 90);
    point.tiltY = int16_t(int32_t(tiltY) * 32767 / 90);
    point.deviceID = penDeviceID;

    auto send = [&](const EventRecord &record) {
        EventRecord copy = record;
        copy.x = x >> 16;
        copy.y = y >> 16;
        copy.timestamp = timestamp;
        copy.senderID = state->registryID;
        IOHIDEvent *event = IOHIDEvent::vendorDefinedEvent(timestamp, recordUsagePage, recordUsage, 0,
                                                           reinterpret_cast<uint8_t *>(&copy),
                                                           sizeof(copy), 0);
        if (!event) return;
        dispatchEvent(event);
        event->release();
    };
    TabletProximity proximityData = {};
    proximityData.vendorID = penVendorID;
    proximityData.tabletID = penTabletID;
    proximityData.deviceID = penDeviceID;
    proximityData.uniqueID = penUniqueID;
    proximityData.capabilityMask = tabletCapabilities;
    proximityData.pointerType = pointerPen;
    auto proximity = [&](bool enter) {
        EventRecord record = {};
        record.type = tabletProximity;
        record.data.proximity = proximityData;
        record.data.proximity.enterProximity = enter;
        send(record);
        if (!enter) return;
        EventRecord move = {};
        move.type = mouseMoved;
        move.data.move.subtype = subtypeTabletProximity;
        move.data.move.tablet.proximity = proximityData;
        move.data.move.tablet.proximity.enterProximity = 1;
        send(move);
    };
    auto button = [&](bool down) {
        EventRecord system = {};
        system.type = systemDefined;
        system.data.system.subtype = subtypeAuxMouseButtons;
        system.data.system.data1 = 1;
        system.data.system.data2 = down;
        send(system);
        if (down) ++state->penClick;
        EventRecord record = {};
        record.type = down ? mouseDown : mouseUp;
        record.data.button.eventNumber = int16_t(state->penClick);
        record.data.button.clickCount = 1;
        record.data.button.pressure = down ? 255 : 0;
        record.data.button.subtype = subtypeTabletPoint;
        record.data.button.tablet.point = point;
        send(record);
    };

    const bool moved = x != state->penX || y != state->penY;
    if (inRange && !state->penInRange) {
        state->penX = x;
        state->penY = y;
        proximity(true);
    } else if (inRange && moved) {
        EventRecord record = {};
        record.type = state->penTip ? mouseDragged : mouseMoved;
        record.data.move.subtype = subtypeTabletPoint;
        record.data.move.tablet.point = point;
        send(record);
        state->penX = x;
        state->penY = y;
    } else if (tip && state->penTip) {
        // Held still: only pressure or tilt changed.
        EventRecord record = {};
        record.type = tabletPointer;
        record.data.point = point;
        send(record);
    }
    if (tip != state->penTip) {
        button(tip);
        state->penTip = tip;
    }
    if (!inRange && state->penInRange) proximity(false);
    state->penInRange = inRange;
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

    OSDictionary *properties = OSDictionary::withCapacity(4);
    if (properties) {
        OSContainer *property = nullptr;
        if (provider->SearchProperty("CGDirectDisplayID", "IOService",
                                     kIOServiceSearchPropertyParents, &property) == kIOReturnSuccess && property) {
            // The touch screen, which belongs to the WiredPad display.
            if (OSNumber *number = OSDynamicCast(OSNumber, property)) {
                properties->setObject("CGDirectDisplayID", number);
                properties->setObject("DisplayIntegrated", kOSBooleanTrue);
                OSContainer *serialNumber = nullptr;
                if (provider->SearchProperty("SerialNumber", "IOService",
                                             kIOServiceSearchPropertyParents, &serialNumber) == kIOReturnSuccess && serialNumber) {
                    OSString *identifier = OSDynamicCast(OSString, serialNumber);
                    if (identifier) properties->setObject("displayUUID", identifier);
                    serialNumber->release();
                }
            }
            property->release();
        }
        SetProperties(properties);
        properties->release();
    }
    // Event records name the service they came from.
    GetRegistryEntryID(&static_cast<WiredPadTouchDriver_IVars *>(ivars)->registryID);
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
    if (type == kIOHIDReportTypeInput && reportID == 2 && report) {
        handlePen(timestamp, report, reportLength);
        return;
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
