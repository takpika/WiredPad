import Darwin
import Foundation

/// The Mac end of a usbmuxd tunnel, wrapped as a session link.
final class USBLink: WireLink {
    let kind = LinkKind.usb
    let inbox = PacketInbox()
    var onClose: (() -> Void)?
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "WiredPad.usb.write", qos: .userInteractive)
    private let lock = NSLock()
    private var closed = false
    private var pending = 0

    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    init(fd: Int32) { self.fd = fd }

    func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func send(_ packet: Data) {
        lock.lock(); pending += packet.count; lock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pending -= packet.count; self.lock.unlock() }
            guard !self.isClosed else { return }
            let ok = packet.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(self.fd, base.advanced(by: offset), bytes.count - offset)
                    if written <= 0 { return false }
                    offset += written
                }
                return true
            }
            if !ok { self.close() }
        }
    }

    func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        shutdown(fd, SHUT_RDWR)
        writeQueue.async { [fd] in Darwin.close(fd) }
        onClose?()
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func readLoop() {
        while !isClosed {
            guard let headerData = readExactly(5), let header = WireFraming.header(headerData),
                  let payload = readExactly(header.length) else { break }
            inbox.deliver(header.type, payload)
        }
        close()
    }

    private func readExactly(_ count: Int) -> Data? {
        var result = Data(count: count)
        let ok = result.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? result : nil
    }
}
