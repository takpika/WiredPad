import Darwin
import Foundation

/// Signs with the keys the iPad keeps in its Secure Enclave, for SSH and sudo. The Mac sets the
/// keys up once and keeps their public halves; each signature needs Touch ID or Face ID on the
/// iPad. Without the iPad, requests fail at once, so SSH and sudo go on to their other methods.
final class DeviceSigner: @unchecked Sendable {
    /// The keys set up on an iPad.
    struct Setup: Codable, Equatable {
        let iPadID: String
        let deviceName: String
        let ssh: Data
        let sudo: Data
    }

    /// Where the SSH agent and sudo sockets and the public keys go, readable only by the user.
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wiredpad")
    static var agentSocket: URL { directory.appendingPathComponent("agent.sock") }
    static var sudoSocket: URL { directory.appendingPathComponent("sudo.sock") }
    static var sshPublicKeyFile: URL { directory.appendingPathComponent("wiredpad_ssh.pub") }
    static var sudoPublicKeyFile: URL { directory.appendingPathComponent("sudo.pub") }

    private let lock = NSLock()
    private var currentSetup: Setup?
    private var sender: ((WireType, Data) -> Void)?
    private var senderID: String?
    private var pending: [UUID: (SignResponse) -> Void] = [:]
    private var setupWaiter: ((DeviceKeys) -> Void)?
    private var setupIPadID: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "WiredPad.deviceKeys") {
            currentSetup = try? JSONDecoder().decode(Setup.self, from: data)
        }
    }

    var setup: Setup? {
        lock.lock(); defer { lock.unlock() }
        return currentSetup
    }

    /// Whether the iPad with the keys is connected, so it can sign now.
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return signingSender != nil
    }

    /// Lock held.
    private var signingSender: ((WireType, Data) -> Void)? {
        senderID != nil && senderID == currentSetup?.iPadID ? sender : nil
    }

    /// The session's send and its iPad, while one is connected.
    func connect(_ send: ((WireType, Data) -> Void)?, iPadID: String?) {
        lock.lock()
        sender = send
        senderID = send == nil ? nil : iPadID
        let abandoned = send == nil ? pending : [:]
        if send == nil { pending = [:] }
        lock.unlock()
        for (id, finish) in abandoned { finish(SignResponse(id: id, signature: nil, error: "disconnected")) }
    }

    /// Asks the connected iPad to make keys for this Mac; `done` gets its answer.
    func beginSetup(_ done: @escaping (DeviceKeys) -> Void) -> Bool {
        lock.lock()
        let send = sender
        let iPadID = senderID
        if send != nil { setupWaiter = done }
        setupIPadID = iPadID
        lock.unlock()
        guard let send, iPadID != nil else { return false }
        send(.keySetup, Data())
        return true
    }

    /// The iPad's answer to `beginSetup`.
    func receive(_ keys: DeviceKeys) {
        lock.lock()
        let waiter = setupWaiter
        let iPadID = setupIPadID
        setupWaiter = nil
        lock.unlock()
        if keys.error == nil, let iPadID, let ssh = keys.keys[.ssh], let sudo = keys.keys[.sudo] {
            store(Setup(iPadID: iPadID, deviceName: keys.deviceName, ssh: ssh, sudo: sudo))
        }
        waiter?(keys)
    }

    func forget() {
        store(nil)
    }

    private func store(_ setup: Setup?) {
        lock.lock()
        currentSetup = setup
        lock.unlock()
        if let setup, let data = try? JSONEncoder().encode(setup) {
            UserDefaults.standard.set(data, forKey: "WiredPad.deviceKeys")
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let comment = "WiredPad \(setup.deviceName)".replacingOccurrences(of: "\n", with: " ")
            try? "\(SSHKey.publicKeyLine(setup.ssh)) \(comment)\n"
                .write(to: Self.sshPublicKeyFile, atomically: true, encoding: .utf8)
            try? "\(setup.sudo.base64EncodedString())\n"
                .write(to: Self.sudoPublicKeyFile, atomically: true, encoding: .utf8)
        } else {
            UserDefaults.standard.removeObject(forKey: "WiredPad.deviceKeys")
            try? FileManager.default.removeItem(at: Self.sshPublicKeyFile)
            try? FileManager.default.removeItem(at: Self.sudoPublicKeyFile)
        }
    }

    /// Asks the iPad to sign, waiting until the user answers. Returns a DER signature, or nil
    /// when the iPad is not there, the user declined, or it took too long.
    func sign(_ data: Data, for purpose: SigningPurpose, reason: String, timeout: TimeInterval = 60) -> Data? {
        let request = SignRequest(id: UUID(), purpose: purpose, reason: reason, data: data)
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let answered = DispatchSemaphore(value: 0)
        var signature: Data?
        lock.lock()
        let send = signingSender
        if send != nil {
            pending[request.id] = { response in
                signature = response.signature
                answered.signal()
            }
        }
        lock.unlock()
        guard let send else { return nil }
        send(.signRequest, payload)
        if answered.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            pending[request.id] = nil
            lock.unlock()
            return nil
        }
        return signature
    }

    func receive(_ response: SignResponse) {
        lock.lock()
        let finish = pending.removeValue(forKey: response.id)
        lock.unlock()
        if let error = response.error { linkLog.info("iPad did not sign: \(error, privacy: .public)") }
        finish?(response)
    }
}

/// The OpenSSH wire forms of an ECDSA P-256 key and signature.
enum SSHKey {
    static let algorithm = "ecdsa-sha2-nistp256"

    /// The key blob of an X9.63 public key.
    static func blob(_ publicKey: Data) -> Data {
        var data = Data()
        data.appendSSHString(Data(algorithm.utf8))
        data.appendSSHString(Data("nistp256".utf8))
        data.appendSSHString(publicKey)
        return data
    }

    static func publicKeyLine(_ publicKey: Data) -> String {
        "\(algorithm) \(blob(publicKey).base64EncodedString())"
    }

    /// An SSH signature from a DER-encoded ECDSA one.
    static func signature(fromDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func length() -> Int? {
            guard index < bytes.count else { return nil }
            var value = Int(bytes[index]); index += 1
            if value & 0x80 != 0 {
                let count = value & 0x7F
                guard count <= 2, index + count <= bytes.count else { return nil }
                value = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            return value
        }
        func integer() -> Data? {
            guard index < bytes.count, bytes[index] == 0x02 else { return nil }
            index += 1
            guard let count = length(), index + count <= bytes.count else { return nil }
            defer { index += count }
            return Data(bytes[index..<index + count])
        }
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard length() != nil, let r = integer(), let s = integer() else { return nil }
        var inner = Data()
        inner.appendSSHMPInt(r)
        inner.appendSSHMPInt(s)
        var signature = Data()
        signature.appendSSHString(Data(algorithm.utf8))
        signature.appendSSHString(inner)
        return signature
    }
}

extension Data {
    mutating func appendSSHUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendSSHString(_ value: Data) {
        appendSSHUInt32(UInt32(value.count))
        append(value)
    }

    /// A non-negative integer as an SSH mpint: no leading zeros but one before a high bit.
    mutating func appendSSHMPInt(_ value: Data) {
        var bytes = Array(value.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        appendSSHString(Data(bytes))
    }
}

/// Reads SSH wire fields in order.
struct SSHReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func uint32() -> UInt32? {
        guard data.endIndex - index >= 4 else { return nil }
        defer { index += 4 }
        return data[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func byte() -> UInt8? {
        guard index < data.endIndex else { return nil }
        defer { index += 1 }
        return data[index]
    }

    mutating func string() -> Data? {
        guard let count = uint32().map(Int.init), data.endIndex - index >= count else { return nil }
        defer { index += count }
        return Data(data[index..<index + count])
    }
}

/// A Unix socket served on threads of its own, one per connection, since a request may wait
/// a long time for Touch ID or Face ID.
final class UnixSocketServer {
    private let path: String
    private let handle: (Int32) -> Void
    private var listener: Int32 = -1

    init(path: URL, handle: @escaping (Int32) -> Void) {
        self.path = path.path
        self.handle = handle
    }

    func start() -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return false }
        listener = fd
        Thread.detachNewThread { [handle] in
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    handle(connection)
                    close(connection)
                }
            }
        }
        return true
    }
}

enum SocketIO {
    static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let result = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + received, count - received, 0) }
            if result <= 0 { return nil }
            received += result
        }
        return data
    }

    @discardableResult
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let result = data.withUnsafeBytes { send(fd, $0.baseAddress! + sent, data.count - sent, 0) }
            if result <= 0 { return false }
            sent += result
        }
        return true
    }

    /// The name of the process at the other end, to show on the iPad.
    static func peerName(_ fd: Int32) -> String? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }
}
