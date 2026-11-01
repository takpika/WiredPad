import Foundation
import Network
import os

let linkLog = Logger(subsystem: "WiredPad", category: "link")

/// Holds packets until a handler is set, so nothing is lost while a link moves from its
/// handshake to the session that owns it.
final class PacketInbox {
    private let lock = NSRecursiveLock()
    private var handler: ((UInt8, Data) -> Void)?
    private var held: [(UInt8, Data)] = []

    func deliver(_ type: UInt8, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let handler { handler(type, data) } else { held.append((type, data)) }
    }

    /// Sets the handler and replays held packets in order. Pass nil to start holding again.
    func setHandler(_ newHandler: ((UInt8, Data) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
        guard newHandler != nil else { return }
        while !held.isEmpty, let handler {
            let next = held.removeFirst()
            handler(next.0, next.1)
        }
    }
}

/// One transport connection (USB tunnel or Wi-Fi) carrying framed packets.
protocol WireLink: AnyObject {
    var kind: LinkKind { get }
    /// Receives every complete packet, on an arbitrary queue.
    var inbox: PacketInbox { get }
    /// Called once when the link fails or is closed.
    var onClose: (() -> Void)? { get set }
    /// Bytes handed to `send` that the transport has not taken yet. Safe from any thread.
    var pendingBytes: Int { get }
    func start()
    func send(_ packet: Data)
    func close()
}

enum WireFraming {
    static func header(_ data: Data) -> (type: UInt8, length: Int)? {
        guard data.count == 5 else { return nil }
        let length = data.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(Wire.maxPayload) else { return nil }
        return (data[data.startIndex], Int(length))
    }

    static func uint64(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func readUInt64(_ data: Data, at offset: Int = 0) -> UInt64? {
        guard data.count >= offset + 8 else { return nil }
        let start = data.startIndex + offset
        return data[start..<start + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// A link backed by Network.framework, used for Wi-Fi on both sides and for the
/// iPad's end of the USB tunnel.
final class NetworkLink: WireLink {
    let kind: LinkKind
    let connection: NWConnection
    let inbox = PacketInbox()
    var onClose: (() -> Void)?
    var onReady: (() -> Void)?
    /// Gives up as soon as there is no route instead of waiting for one, so a stale
    /// Bonjour result is retried right away.
    var closesWhenWaiting = false
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var pending = 0

    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    /// The local interface the connection runs over, once it is ready.
    var interface: NWInterface? { connection.currentPath?.availableInterfaces.first }

    var interfaceClass: InterfaceClass {
        guard let interface else { return .other }
        if interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw") { return .peerToPeer }
        if interface.name.hasPrefix("nan") { return .wifiAware }
        switch interface.type {
        case .wiredEthernet: return .wired
        case .wifi: return .wifi
        default: return .other
        }
    }

    init(kind: LinkKind, connection: NWConnection, queue: DispatchQueue) {
        self.kind = kind
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receiveHeader()
            case .failed(let error):
                linkLog.error("\(self?.kind.rawValue ?? "", privacy: .public) link failed: \(error.localizedDescription, privacy: .public)")
                self?.finish()
            case .waiting(let error):
                linkLog.info("\(self?.kind.rawValue ?? "", privacy: .public) link waiting: \(error.localizedDescription, privacy: .public)")
                if self?.closesWhenWaiting == true { self?.close() }
            case .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ packet: Data) {
        let count = packet.count
        lock.lock(); pending += count; lock.unlock()
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self.pending -= count; self.lock.unlock()
            if error != nil { self.close() }
        })
    }

    func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { onClose?() }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil, !complete, let data, let header = WireFraming.header(data) else {
                self.close()
                return
            }
            self.receivePayload(type: header.type, length: header.length)
        }
    }

    private func receivePayload(type: UInt8, length: Int) {
        guard length > 0 else {
            inbox.deliver(type, Data())
            receiveHeader()
            return
        }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else {
                self.close()
                return
            }
            self.inbox.deliver(type, data)
            if complete { self.close() } else { self.receiveHeader() }
        }
    }
}

/// A display session that survives link changes. It can hold any number of links at once.
/// Every message is numbered and sent on the primary link and, as far as they keep up, on the
/// standby links too, so a standby path is already carrying the stream when the primary goes
/// away. Unacknowledged messages are kept and sent on whichever link takes over, and the
/// receiver drops duplicates and restores order, so moving between paths loses nothing.
///
/// Each link has a rank (lower is preferred) and is checked every 100 ms with a ping. The
/// primary is the best-ranked link that is currently responsive; a better-ranked link takes
/// over only after it has stayed responsive for a while, so the choice does not flap.
final class WireSession {
    struct LinkStatus: Equatable {
        var usb = false
        var wifi = false
        var primary: LinkKind?
        /// Ranks of every attached link, best first.
        var ranks: [Int] = []
        var primaryRank: Int?
    }

    let id: UUID
    let queue: DispatchQueue
    /// Called on `queue` for each in-order message.
    var onMessage: ((UInt8, Data) -> Void)?
    /// Called on `queue` whenever links come and go.
    var onLinksChanged: ((LinkStatus) -> Void)?

    private final class Attached {
        let link: WireLink
        let rank: Int
        var lastReceive: TimeInterval
        /// Every sequence up to this one has been sent on this link or acknowledged.
        var sentThrough: UInt64 = 0
        /// Recent ping round trips, in seconds.
        var roundTrips: [(time: TimeInterval, seconds: TimeInterval)] = []
        var lastPong: TimeInterval
        /// Since when the link has been responsive, if it is.
        var goodSince: TimeInterval?
        init(_ link: WireLink, rank: Int, now: TimeInterval) {
            self.link = link
            self.rank = rank
            lastReceive = now
            lastPong = now
        }

        /// The slowest response over the last two seconds, counting a ping still unanswered.
        func worstDelay(now: TimeInterval) -> TimeInterval {
            let slowest = roundTrips.map(\.seconds).max() ?? 0
            return max(slowest, now - lastPong - WireSession.pingInterval)
        }
    }

    private var links: [Attached] = []
    private var primary: WireLink?
    /// The one standby link that also carries the stream, so it is warm when it takes over.
    /// Only while the primary is wired: wireless links share a radio, and copies on a second
    /// one would take airtime from the primary.
    private var mirror: WireLink?
    private var nextSeq: UInt64 = 1
    private var unacked: [(seq: UInt64, packet: Data, sent: TimeInterval)] = []
    private var unackedHead = 0
    private let statsLock = NSLock()
    private var _unackedBytes = 0
    private var delivered: UInt64 = 0
    private var reorder: [UInt64: (UInt8, Data)] = [:]
    private var roundTrips: [Double] = []
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var lastStatus: LinkStatus?
    private var invalidated = false
    private(set) var handovers = 0
    private(set) var resentPackets = 0
    private(set) var duplicatePackets = 0

    static let linkTimeout: TimeInterval = 1.2
    static let pingInterval: TimeInterval = 0.1
    /// A link that answers slower than this is not used while a responsive one is there.
    static let responsiveDelay: TimeInterval = 0.08
    /// How long a wireless primary may go without answering before another link takes over.
    static let stallDelay: TimeInterval = 0.4
    /// The standby link stops getting copies while this much is waiting to go out on it, so
    /// it never builds up a queue of its own.
    static let standbyBacklog = 64 * 1024

    init(id: UUID, queue: DispatchQueue) {
        self.id = id
        self.queue = queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// Bytes sent but not yet acknowledged by the peer. Safe from any thread.
    var unackedBytes: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return _unackedBytes
    }

    /// Round-trip times in milliseconds, from sending a message to its acknowledgement, since
    /// the last call. Safe from any thread.
    func takeRoundTrips() -> [Double] {
        statsLock.lock(); defer { statsLock.unlock() }
        let taken = roundTrips
        roundTrips.removeAll(keepingCapacity: true)
        return taken
    }

    /// Highest in-order sequence received. Read on `queue`.
    var receivedSequence: UInt64 { delivered }

    var status: LinkStatus {
        LinkStatus(usb: links.contains { $0.link.kind == .usb },
                   wifi: links.contains { $0.link.kind == .wifi },
                   primary: primary?.kind,
                   ranks: links.map(\.rank).sorted(),
                   primaryRank: links.first { $0.link === primary }?.rank)
    }

    var hasLinks: Bool { !links.isEmpty }

    func has(_ kind: LinkKind) -> Bool { links.contains { $0.link.kind == kind } }

    /// The slowest ping response over the last two seconds for each link, in milliseconds,
    /// by rank. Call on `queue`.
    func worstDelays() -> [Int: Double] {
        let now = Self.now
        return Dictionary(links.map { ($0.rank, $0.worstDelay(now: now) * 1000) }, uniquingKeysWith: max)
    }

    /// Closes the links of one rank. Call on `queue`.
    func drop(rank: Int) {
        for entry in links where entry.rank == rank { entry.link.close() }
    }

    /// Closes the link of one kind, as if its cable or network went away. Call on `queue`.
    func drop(_ kind: LinkKind) {
        for entry in links where entry.link.kind == kind { entry.link.close() }
    }

    /// Adds a link whose hello/welcome exchange is done. `peerReceived` is the highest
    /// sequence the peer already has from us; `rank` orders links, lower first. Call on `queue`.
    func attach(_ link: WireLink, peerReceived: UInt64, rank: Int) {
        guard !invalidated else { link.close(); return }
        let entry = Attached(link, rank: rank, now: Self.now)
        entry.sentThrough = peerReceived
        link.inbox.setHandler { [weak self, weak link] type, data in
            self?.queue.async {
                guard let self, let link else { return }
                self.receive(type, data, on: link)
            }
        }
        link.onClose = { [weak self, weak link] in
            self?.queue.async {
                guard let self, let link else { return }
                self.detach(link)
            }
        }
        links.append(entry)
        linkLog.info("attached \(link.kind.rawValue, privacy: .public) link of rank \(rank), peer has \(peerReceived)")
        acknowledge(upTo: peerReceived)
        choosePrimary()
        link.send(heartbeatPacket())
    }

    /// Queues a message for in-order delivery. Safe from any thread.
    func send(_ type: WireType, _ payload: Data) {
        let inner = Wire.packet(type, payload)
        queue.async { [weak self] in
            guard let self, !self.invalidated else { return }
            let seq = self.nextSeq
            self.nextSeq += 1
            var body = WireFraming.uint64(seq)
            body.append(inner)
            let packet = Wire.packet(.data, body)
            self.unacked.append((seq, packet, Self.now))
            self.statsLock.lock(); self._unackedBytes += packet.count; self.statsLock.unlock()
            for entry in self.links { self.feed(entry) }
        }
    }

    /// Closes every link and stops the session. Call on `queue`.
    func invalidate() {
        invalidated = true
        timer?.cancel()
        timer = nil
        for entry in links { entry.link.onClose = nil; entry.link.close() }
        links.removeAll()
        primary = nil
        unacked.removeAll()
        statsLock.lock(); _unackedBytes = 0; statsLock.unlock()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func receive(_ type: UInt8, _ data: Data, on link: WireLink) {
        guard let entry = links.first(where: { $0.link === link }) else { return }
        entry.lastReceive = Self.now
        switch type {
        case WireType.data.rawValue:
            guard let seq = WireFraming.readUInt64(data),
                  data.count >= 13,
                  let header = WireFraming.header(data.subdata(in: data.startIndex + 8..<data.startIndex + 13)),
                  data.count == 13 + header.length else { link.close(); return }
            if seq <= delivered || reorder[seq] != nil {
                duplicatePackets += 1
                return
            }
            reorder[seq] = (header.type, data.subdata(in: data.startIndex + 13..<data.endIndex))
            while let next = reorder.removeValue(forKey: delivered + 1) {
                delivered += 1
                onMessage?(next.0, next.1)
                if invalidated { return }
            }
            // Acknowledge right away on the link it came in on, so the sender's round-trip
            // times show how long data waits on that path.
            link.send(Wire.packet(.ack, WireFraming.uint64(delivered)))
        case WireType.linkPing.rawValue:
            link.send(Wire.packet(.linkPong, data))
        case WireType.linkPong.rawValue:
            guard let sent = WireFraming.readUInt64(data) else { return }
            let now = Self.now
            entry.lastPong = now
            entry.roundTrips.append((now, now - TimeInterval(bitPattern: sent)))
            entry.roundTrips.removeAll { now - $0.time > 2 }
        case WireType.ack.rawValue, WireType.heartbeat.rawValue:
            if let seq = WireFraming.readUInt64(data) { acknowledge(upTo: seq) }
        default:
            break
        }
    }

    private func acknowledge(upTo seq: UInt64) {
        var freed = 0
        var newestSent: TimeInterval?
        while unackedHead < unacked.count, unacked[unackedHead].seq <= seq {
            freed += unacked[unackedHead].packet.count
            newestSent = unacked[unackedHead].sent
            unackedHead += 1
        }
        if let newestSent {
            statsLock.lock()
            if roundTrips.count < 1024 { roundTrips.append((Self.now - newestSent) * 1000) }
            statsLock.unlock()
        }
        if unackedHead > 256, unackedHead * 2 > unacked.count {
            unacked.removeFirst(unackedHead)
            unackedHead = 0
        }
        if freed > 0 { statsLock.lock(); _unackedBytes -= freed; statsLock.unlock() }
    }

    private func detach(_ link: WireLink) {
        guard links.contains(where: { $0.link === link }) else { return }
        links.removeAll { $0.link === link }
        if mirror === link { mirror = nil }
        linkLog.info("lost \(link.kind.rawValue, privacy: .public) link")
        choosePrimary()
    }

    private func choosePrimary() {
        let now = Self.now
        for entry in links {
            if entry.worstDelay(now: now) < Self.responsiveDelay {
                if entry.goodSince == nil { entry.goodSince = now }
            } else {
                entry.goodSince = nil
            }
        }
        let responsive = links.filter { $0.goodSince != nil }.sorted { $0.rank < $1.rank }
        let current = links.first { $0.link === primary }
        let wired = NetworkPath.wiredLAN.rank
        // Two wireless links share the radio, and short stalls on one come with stalls on the
        // other, so a wireless primary is left only once it stops answering altogether.
        // Switching on every stall moves back and forth and resends data each time.
        let holds = current.map { $0.goodSince != nil || ($0.rank > wired && now - $0.lastPong < Self.stallDelay) }
        let best: Attached?
        if let current, holds == true {
            // Move to a better-ranked link once it has stayed responsive for a moment; USB
            // takes over almost at once. Between wireless paths no rank is better: which one
            // to keep is decided by measuring them.
            best = responsive.first { candidate in
                guard candidate.rank < current.rank, candidate.rank <= wired || current.rank <= wired,
                      let since = candidate.goodSince else { return false }
                return now - since >= (candidate.link.kind == .usb ? 0.2 : 2)
            } ?? current
        } else {
            // The primary is gone or stalled: take the best responsive link, or else the one
            // answering soonest.
            best = responsive.first ?? links.min { $0.worstDelay(now: now) < $1.worstDelay(now: now) }
        }
        let previous = primary
        primary = best?.link
        if let best, best.rank <= NetworkPath.wiredLAN.rank {
            let others = links.filter { $0 !== best }
            mirror = (others.filter { $0.goodSince != nil }.min { $0.rank < $1.rank }
                ?? others.min { $0.worstDelay(now: now) < $1.worstDelay(now: now) })?.link
        } else {
            mirror = nil
        }
        if let best, best.link !== previous {
            if previous != nil { handovers += 1 }
            // Anything this link has not carried may be lost with the old one; send it here.
            // The receiver discards copies it already has.
            let sent = feed(best)
            resentPackets += sent
            linkLog.info("primary is now \(best.link.kind.rawValue, privacy: .public) of rank \(best.rank); resending \(sent) packets")
        }
        let latest = status
        if latest != lastStatus {
            lastStatus = latest
            onLinksChanged?(latest)
        }
    }

    /// Sends this link every unacknowledged message it has not carried yet. The primary always
    /// gets them; the mirror only while its backlog is small; other links none. Returns how
    /// many it sent.
    @discardableResult
    private func feed(_ entry: Attached) -> Int {
        guard unackedHead < unacked.count else { return 0 }
        let isPrimary = entry.link === primary
        guard isPrimary || entry.link === mirror else { return 0 }
        let firstSeq = unacked[unackedHead].seq
        var index = unackedHead + Int(max(entry.sentThrough + 1, firstSeq) - firstSeq)
        var sent = 0
        while index < unacked.count {
            if !isPrimary, entry.link.pendingBytes > Self.standbyBacklog { break }
            entry.link.send(unacked[index].packet)
            entry.sentThrough = unacked[index].seq
            index += 1
            sent += 1
        }
        return sent
    }

    private func heartbeatPacket() -> Data {
        Wire.packet(.heartbeat, WireFraming.uint64(delivered))
    }

    private func tick() {
        let now = Self.now
        for entry in links where now - entry.lastReceive > Self.linkTimeout {
            entry.link.close()
        }
        // Let a standby link that fell behind catch up once its backlog drains.
        for entry in links where entry.link !== primary { feed(entry) }
        if now - lastPing >= Self.pingInterval {
            lastPing = now
            let ping = Wire.packet(.linkPing, WireFraming.uint64(now.bitPattern))
            for entry in links {
                entry.roundTrips.removeAll { now - $0.time > 2 }
                entry.link.send(ping)
            }
            choosePrimary()
        }
        if now - lastHeartbeat >= 0.25 {
            lastHeartbeat = now
            let packet = heartbeatPacket()
            for entry in links { entry.link.send(packet) }
        }
    }
}

/// Runs the hello/welcome exchange on a fresh link. Packets after the handshake stay held
/// in the link's inbox until the session attaches it.
enum LinkHandshake {
    /// Mac side: sends `hello` and waits for the iPad's welcome.
    static func client(_ link: WireLink, hello: LinkHello, timeout: TimeInterval = 4,
                       completion: @escaping (LinkWelcome?) -> Void) {
        let once = Once(completion)
        link.inbox.setHandler { [weak link] type, data in
            link?.inbox.setHandler(nil)
            guard type == WireType.linkWelcome.rawValue,
                  let welcome = try? JSONDecoder().decode(LinkWelcome.self, from: data) else {
                link?.close()
                once.call(nil)
                return
            }
            once.call(welcome)
        }
        link.onClose = { once.call(nil) }
        link.start()
        if let data = try? JSONEncoder().encode(hello) { link.send(Wire.packet(.linkHello, data)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak link] in
            if once.call(nil) { link?.close() }
        }
    }

    /// iPad side: waits for the Mac's hello. The caller replies with `welcome(_:on:)`.
    static func server(_ link: WireLink, timeout: TimeInterval = 4, completion: @escaping (LinkHello?) -> Void) {
        let once = Once(completion)
        link.inbox.setHandler { [weak link] type, data in
            link?.inbox.setHandler(nil)
            guard type == WireType.linkHello.rawValue,
                  let hello = try? JSONDecoder().decode(LinkHello.self, from: data) else {
                link?.close()
                once.call(nil)
                return
            }
            once.call(hello)
        }
        link.onClose = { once.call(nil) }
        link.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak link] in
            if once.call(nil) { link?.close() }
        }
    }

    static func welcome(_ welcome: LinkWelcome, on link: WireLink) {
        if let data = try? JSONEncoder().encode(welcome) { link.send(Wire.packet(.linkWelcome, data)) }
    }

    private final class Once<T> {
        private let lock = NSLock()
        private var callback: ((T?) -> Void)?
        init(_ callback: @escaping (T?) -> Void) { self.callback = callback }
        @discardableResult func call(_ value: T?) -> Bool {
            lock.lock()
            let pending = callback
            callback = nil
            lock.unlock()
            pending?(value)
            return pending != nil
        }
    }
}
