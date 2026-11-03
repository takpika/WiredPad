import Darwin
import Foundation

/// An SSH agent offering the iPad's key while the iPad is connected, in front of the agent
/// that was there before, which keeps the user's other keys working: every request about them,
/// and every request while the iPad is away, goes on to it. Point SSH at it with
/// `IdentityAgent ~/.wiredpad/agent.sock`.
final class SSHAgent {
    private enum Message: UInt8 {
        case failure = 5
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
    }

    private let signer: DeviceSigner
    /// The agent before this one, asked again for each connection since setting SSH up changes it.
    private let upstreamPath: () -> String?
    private var upstream: String? {
        upstreamPath().flatMap { $0.isEmpty || $0 == DeviceSigner.agentSocket.path ? nil : $0 }
    }
    private var server: UnixSocketServer?

    init(signer: DeviceSigner, upstream: @escaping () -> String?) {
        self.signer = signer
        upstreamPath = upstream
    }

    func start() {
        let server = UnixSocketServer(path: DeviceSigner.agentSocket) { [weak self] fd in self?.serve(fd) }
        if server.start() {
            self.server = server
            linkLog.info("SSH agent listening; other keys from \(self.upstream ?? "none", privacy: .public)")
        } else {
            linkLog.error("SSH agent could not listen at \(DeviceSigner.agentSocket.path, privacy: .public)")
        }
    }

    private func serve(_ fd: Int32) {
        let peer = SocketIO.peerName(fd) ?? "ssh"
        let upstream = self.upstream
        var upstreamFD: Int32 = -1
        defer { if upstreamFD >= 0 { close(upstreamFD) } }
        func forward(_ message: Data) -> Data? {
            if upstreamFD < 0, let upstream { upstreamFD = Self.connect(upstream) }
            guard upstreamFD >= 0, SocketIO.write(upstreamFD, message),
                  let header = SocketIO.read(upstreamFD, count: 4) else { return nil }
            let length = Int(header.reduce(0) { $0 << 8 | UInt32($1) })
            guard length <= 256 * 1024, let body = SocketIO.read(upstreamFD, count: length) else { return nil }
            return header + body
        }
        while let header = SocketIO.read(fd, count: 4) {
            let length = Int(header.reduce(0) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= 256 * 1024, let body = SocketIO.read(fd, count: length) else { return }
            let reply: Data
            switch Message(rawValue: body[body.startIndex]) {
            case .requestIdentities:
                reply = identities(upstream: forward(header + body))
            case .signRequest:
                var reader = SSHReader(body.dropFirst())
                if let blob = reader.string(), let data = reader.string(),
                   let key = signer.setup?.ssh, blob == SSHKey.blob(key) {
                    reply = sign(data, peer: peer)
                } else {
                    reply = forward(header + body) ?? Self.frame([Message.failure.rawValue])
                }
            default:
                // Extensions such as session-bind belong to the other agent's keys.
                reply = forward(header + body) ?? Self.frame([Message.failure.rawValue])
            }
            guard SocketIO.write(fd, reply) else { return }
        }
    }

    /// The iPad's key first, then the other agent's, while the iPad can sign.
    private func identities(upstream: Data?) -> Data {
        var keys: [(blob: Data, comment: Data)] = []
        if signer.available, let setup = signer.setup {
            keys.append((SSHKey.blob(setup.ssh), Data("WiredPad \(setup.deviceName)".utf8)))
        }
        if let upstream {
            var reader = SSHReader(upstream.dropFirst(4))
            if reader.byte() == Message.identitiesAnswer.rawValue, let count = reader.uint32() {
                for _ in 0..<count {
                    guard let blob = reader.string(), let comment = reader.string() else { break }
                    keys.append((blob, comment))
                }
            }
        }
        var body = Data([Message.identitiesAnswer.rawValue])
        body.appendSSHUInt32(UInt32(keys.count))
        for key in keys {
            body.appendSSHString(key.blob)
            body.appendSSHString(key.comment)
        }
        return Self.frame(body)
    }

    private func sign(_ data: Data, peer: String) -> Data {
        guard let der = signer.sign(data, for: .ssh, reason: Self.describe(data, peer: peer)),
              let signature = SSHKey.signature(fromDER: der) else {
            return Self.frame([Message.failure.rawValue])
        }
        var body = Data([Message.signResponse.rawValue])
        body.appendSSHString(signature)
        return Self.frame(body)
    }

    /// What is being signed, for the Touch ID or Face ID prompt.
    private static func describe(_ data: Data, peer: String) -> String {
        if data.starts(with: Data("SSHSIG".utf8)) {
            var reader = SSHReader(data.dropFirst(6))
            _ = reader.uint32()
            let namespace = reader.string().flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            return L10n.tr("mac.signing.sshsig", peer, namespace)
        }
        var reader = SSHReader(data)
        if reader.string() != nil, reader.byte() == 50, let user = reader.string(),
           let name = String(data: user, encoding: .utf8) {
            return L10n.tr("mac.signing.ssh", peer, name)
        }
        return L10n.tr("mac.signing.sshother", peer)
    }

    private static func frame(_ body: Data) -> Data {
        var data = Data()
        data.appendSSHUInt32(UInt32(body.count))
        return data + body
    }

    private static func frame(_ body: [UInt8]) -> Data { frame(Data(body)) }

    private static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return -1 }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

/// Answers the sudo PAM module (PAM/pam_wiredpad.c), which runs as root inside sudo. It sends a
/// fresh challenge; the iPad signs it, with the user and the command, using its sudo key, and the
/// module checks the signature against a copy of the public key only root can change. So a
/// process posing as this one cannot get sudo through: it has no key the module accepts.
final class SudoBridge {
    private let signer: DeviceSigner
    /// What sudo shows while it waits, naming the device and how it confirms.
    private let waiting: () -> String
    private var server: UnixSocketServer?

    init(signer: DeviceSigner, waiting: @escaping () -> String) {
        self.signer = signer
        self.waiting = waiting
    }

    func start() {
        let server = UnixSocketServer(path: DeviceSigner.sudoSocket) { [weak self] fd in self?.serve(fd) }
        if server.start() { self.server = server }
        else { linkLog.error("sudo bridge could not listen at \(DeviceSigner.sudoSocket.path, privacy: .public)") }
    }

    /// The request is four lines: "WPSUDO2", the challenge in base64, the user, and what sudo
    /// runs. The answer is "OK" and the signature in base64, or "NO", after a "WAIT" line with
    /// what sudo shows meanwhile. The first module sent "WPSUDO1" and knows no "WAIT".
    private func serve(_ fd: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { return }
        var request = Data()
        while request.filter({ $0 == 0x0A }).count < 4, request.count < 8192,
              let byte = SocketIO.read(fd, count: 1) {
            request.append(byte)
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\n")
        guard lines.count >= 4, ["WPSUDO1", "WPSUDO2"].contains(lines[0]), let challenge = Data(base64Encoded: lines[1]),
              challenge.count == 32, signer.available else {
            SocketIO.write(fd, Data("NO\n".utf8))
            return
        }
        let user = lines[2], command = lines[3]
        let message = Data("WiredPad sudo v1\n\(user)\n\(command)\n".utf8) + challenge
        let reason = L10n.tr("mac.signing.sudo", user, command)
        if lines[0] == "WPSUDO2" {
            let notice = waiting().replacingOccurrences(of: "\n", with: " ")
            SocketIO.write(fd, Data("WAIT \(notice)\n".utf8))
        }
        guard let signature = signer.sign(message, for: .sudo, reason: reason) else {
            SocketIO.write(fd, Data("NO\n".utf8))
            return
        }
        SocketIO.write(fd, Data("OK \(signature.base64EncodedString())\n".utf8))
    }
}
