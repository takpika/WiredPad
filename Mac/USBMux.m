#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import "WiredPadMac-Bridging-Header.h"

static NSString *usbError;
const char *WiredPadUSBError(void) { return usbError.UTF8String ?: "USB connection failed"; }

static BOOL writeAll(int fd, const void *bytes, size_t count) {
    const uint8_t *p = bytes;
    while (count) {
        ssize_t n = write(fd, p, count);
        if (n <= 0) return NO;
        p += n; count -= (size_t)n;
    }
    return YES;
}

static BOOL readAll(int fd, void *bytes, size_t count) {
    uint8_t *p = bytes;
    while (count) {
        ssize_t n = read(fd, p, count);
        if (n <= 0) return NO;
        p += n; count -= (size_t)n;
    }
    return YES;
}

static NSDictionary *request(int fd, NSDictionary *body, uint32_t tag) {
    NSError *error = nil;
    NSData *payload = [NSPropertyListSerialization dataWithPropertyList:body format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!payload) return nil;
    uint32_t header[4] = {(uint32_t)payload.length + 16, 1, 8, tag};
    if (!writeAll(fd, header, sizeof(header)) || !writeAll(fd, payload.bytes, payload.length)) return nil;
    if (!readAll(fd, header, sizeof(header)) || header[0] < 16 || header[0] > 1024 * 1024) return nil;
    NSMutableData *response = [NSMutableData dataWithLength:header[0] - 16];
    if (!readAll(fd, response.mutableBytes, response.length)) return nil;
    id object = [NSPropertyListSerialization propertyListWithData:response options:NSPropertyListImmutable format:NULL error:&error];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

int WiredPadConnectUSB(uint16_t port) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { usbError = @"usb.error.socket"; return -1; }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/var/run/usbmuxd", sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        usbError = @"usb.error.daemon";
        close(fd); return -1;
    }
    NSDictionary *list = request(fd, @{@"MessageType": @"ListDevices", @"ClientVersionString": @"WiredPad 0.1", @"ProgName": @"WiredPadMac", @"kLibUSBMuxVersion": @3}, 1);
    NSArray *devices = list[@"DeviceList"];
    close(fd);
    BOOL foundUSB = NO;
    for (NSDictionary *device in devices) {
        if (![device[@"Properties"][@"ConnectionType"] isEqualToString:@"USB"]) continue;
        foundUSB = YES;
        NSNumber *deviceID = device[@"DeviceID"] ?: device[@"Properties"][@"DeviceID"];
        if (!deviceID) continue;
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) continue;
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(fd);
            continue;
        }
        NSDictionary *result = request(fd, @{@"MessageType": @"Connect", @"DeviceID": deviceID,
                                             @"PortNumber": @(htons(port)), @"ClientVersionString": @"WiredPad 0.1",
                                             @"ProgName": @"WiredPadMac"}, 2);
        if ([result[@"Number"] isEqual:@0]) {
            int noSigPipe = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            return fd;
        }
        close(fd);
    }
    if (!foundUSB) {
        usbError = @"usb.error.nodevice";
    } else {
        usbError = @"usb.error.tunnel";
    }
    return -1;
}
