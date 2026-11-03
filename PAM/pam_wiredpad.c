// pam_wiredpad: sudo approved with Touch ID or Face ID on an iPad running WiredPad.
//
// The module sends a fresh random challenge, the user, and the command to the WiredPad app of
// the user sudo authenticates, over ~/.wiredpad/sudo.sock. The app has the iPad sign them with
// a key kept in its Secure Enclave, and the module checks the signature against the public key
// in /Library/WiredPad/keys/<user>.pub, which only root can change. Anything else, such as no
// iPad, no answer within a minute, or a bad signature, returns PAM_IGNORE, so the next method
// in the stack, Touch ID or the password, goes on as if this module were not there.

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <crt_externs.h>
#include <errno.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define KEY_DIRECTORY "/Library/WiredPad/keys"
#define TIMEOUT_SECONDS 60

static void tell(pam_handle_t *pamh, const char *text) {
    const struct pam_conv *conversation = NULL;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conversation) != PAM_SUCCESS || !conversation ||
        !conversation->conv) return;
    struct pam_message message = {PAM_TEXT_INFO, (char *)text};
    const struct pam_message *messages[] = {&message};
    struct pam_response *response = NULL;
    conversation->conv(1, messages, &response, conversation->appdata_ptr);
    if (response) {
        free(response->resp);
        free(response);
    }
}

static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *base64(const UInt8 *bytes, size_t length) {
    char *text = calloc((length + 2) / 3 * 4 + 1, 1);
    if (!text) return NULL;
    char *out = text;
    for (size_t index = 0; index < length; index += 3) {
        UInt32 group = (UInt32)bytes[index] << 16;
        if (index + 1 < length) group |= (UInt32)bytes[index + 1] << 8;
        if (index + 2 < length) group |= bytes[index + 2];
        *out++ = alphabet[group >> 18 & 63];
        *out++ = alphabet[group >> 12 & 63];
        *out++ = index + 1 < length ? alphabet[group >> 6 & 63] : '=';
        *out++ = index + 2 < length ? alphabet[group & 63] : '=';
    }
    return text;
}

static CFDataRef copy_base64_decoded(const char *text) {
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    UInt32 group = 0;
    int bits = 0;
    for (const char *c = text; *c && *c != '='; c++) {
        const char *found = strchr(alphabet, *c);
        if (!found || !*c) {
            CFRelease(data);
            return NULL;
        }
        group = group << 6 | (UInt32)(found - alphabet);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            UInt8 byte = (UInt8)(group >> bits);
            CFDataAppendBytes(data, &byte, 1);
        }
    }
    return data;
}

/// Whether `path` is root's and no one else can change it.
static int root_only(const char *path, int directory) {
    struct stat info;
    return lstat(path, &info) == 0 && info.st_uid == 0 && !(info.st_mode & (S_IWGRP | S_IWOTH)) &&
           (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode));
}

/// The user's public key. It and every folder above it must be root's alone: anyone who could
/// rename one of them could put their own key in its place.
static SecKeyRef copy_public_key(const char *user) {
    char path[512];
    if (snprintf(path, sizeof(path), KEY_DIRECTORY "/%s.pub", user) >= (int)sizeof(path)) return NULL;
    if (!root_only("/", 1) || !root_only("/Library", 1) || !root_only("/Library/WiredPad", 1) ||
        !root_only(KEY_DIRECTORY, 1) || !root_only(path, 0)) return NULL;
    FILE *file = fopen(path, "r");
    if (!file) return NULL;
    char text[256] = {0};
    size_t length = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    while (length > 0 && (text[length - 1] == '\n' || text[length - 1] == '\r' || text[length - 1] == ' ')) {
        text[--length] = 0;
    }
    CFDataRef raw = copy_base64_decoded(text);
    if (!raw) return NULL;
    const void *keys[] = {kSecAttrKeyType, kSecAttrKeyClass};
    const void *values[] = {kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClassPublic};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    SecKeyRef key = SecKeyCreateWithData(raw, attributes, NULL);
    CFRelease(attributes);
    CFRelease(raw);
    return key;
}

/// What sudo was asked to run, from its own arguments, on one line.
static void describe_command(char *buffer, size_t size) {
    buffer[0] = 0;
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int index = 0; index < count && arguments[index]; index++) {
        if (index > 0) strlcat(buffer, " ", size);
        strlcat(buffer, arguments[index], size);
    }
    for (char *c = buffer; *c; c++) if (*c == '\n' || *c == '\r') *c = ' ';
}

static int write_all(int fd, const char *text) {
    size_t length = strlen(text), sent = 0;
    while (sent < length) {
        ssize_t result = write(fd, text + sent, length - sent);
        if (result <= 0) return -1;
        sent += (size_t)result;
    }
    return 0;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags; (void)argc; (void)argv;
    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user || strchr(user, '/') || strchr(user, '\n')) {
        return PAM_IGNORE;
    }
    struct passwd *account = getpwnam(user);
    if (!account || !account->pw_dir) return PAM_IGNORE;
    SecKeyRef key = copy_public_key(user);
    if (!key) return PAM_IGNORE;

    int result = PAM_IGNORE;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (fd < 0 || snprintf(address.sun_path, sizeof(address.sun_path), "%s/.wiredpad/sudo.sock",
                           account->pw_dir) >= (int)sizeof(address.sun_path) ||
        connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        goto done;
    }
    struct timeval timeout = {TIMEOUT_SECONDS, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));

    UInt8 challenge[32];
    arc4random_buf(challenge, sizeof(challenge));
    char command[1024];
    describe_command(command, sizeof(command));
    char *encoded = base64(challenge, sizeof(challenge));
    if (!encoded) goto done;
    char request[2048];
    int written = snprintf(request, sizeof(request), "WPSUDO2\n%s\n%s\n%s\n", encoded, user, command);
    free(encoded);
    if (written >= (int)sizeof(request) || write_all(fd, request) != 0) goto done;

    // A "WAIT" line comes first, with what to show while the iPad asks, then the answer.
    char answer[512];
    for (;;) {
        size_t length = 0;
        while (length < sizeof(answer) - 1) {
            ssize_t received = read(fd, answer + length, 1);
            if (received <= 0 || answer[length] == '\n') break;
            length++;
        }
        answer[length] = 0;
        if (strncmp(answer, "WAIT ", 5) != 0) break;
        tell(pamh, answer + 5);
    }
    if (strncmp(answer, "OK ", 3) != 0) goto done;
    CFDataRef signature = copy_base64_decoded(answer + 3);
    if (!signature) goto done;

    // The same bytes the app had signed: a label, the user, the command, then the challenge.
    char header[1200];
    int headerLength = snprintf(header, sizeof(header), "WiredPad sudo v1\n%s\n%s\n", user, command);
    CFMutableDataRef message = CFDataCreateMutable(NULL, 0);
    if (headerLength > 0 && headerLength < (int)sizeof(header)) {
        CFDataAppendBytes(message, (const UInt8 *)header, headerLength);
        CFDataAppendBytes(message, challenge, sizeof(challenge));
        if (SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, message, signature, NULL)) {
            result = PAM_SUCCESS;
        }
    }
    CFRelease(message);
    CFRelease(signature);

done:
    if (fd >= 0) close(fd);
    CFRelease(key);
    return result;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
