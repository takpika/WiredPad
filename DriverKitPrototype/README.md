# WiredPad touch driver

This HIDDriverKit event service matches the WiredPad virtual ten-contact touchscreen (vendor ID 22352, product ID 1). It converts 62-byte reports to native digitizer touch events and associates the service with the virtual display's ID and UUID.

The source compiled with the macOS 27.2 DriverKit SDK and worked in one signed development setup. You must request your own DriverKit, HID EventService, and Transport HID entitlements from Apple. The host app also needs HID Virtual Device and System Extension entitlements. The checked-in entitlement files describe the capabilities but do not grant them. See [Apple's DriverKit entitlement process](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development).

`build-bundled-app.sh` builds the driver and Mac host using the signing values described in the top-level [README](../README.md), embeds the driver in the app, and verifies the final signature. The default Xcode projects support unsigned compile checks only.
