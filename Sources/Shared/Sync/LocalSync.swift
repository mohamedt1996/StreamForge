import Foundation
import Network
import CryptoKit
import Observation

/// Wire message between two StreamForge devices.
struct SyncMessage: Codable {
    enum Kind: String, Codable { case challenge, bundle, done, error }
    var kind: Kind
    var name: String?
    var salt: Data?
    var box: Data?
    var message: String?
}

/// The bundle is sealed with AES-GCM using a key derived from the 4-digit code shown on the
/// receiving device and a random salt, so a wrong code can't be applied and the secrets in the
/// bundle aren't readable on the wire.
enum SyncCrypto {
    static func key(code: String, salt: Data) -> SymmetricKey {
        var material = Data("streamforge-sync-v1:".utf8)
        material.append(Data(code.utf8))
        material.append(salt)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    static func seal(_ data: Data, code: String, salt: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key(code: code, salt: salt)).combined else {
            throw HTTPError.transport("Encryption failed")
        }
        return combined
    }

    static func open(_ data: Data, code: String, salt: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key(code: code, salt: salt))
    }

    static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}

/// Length-prefixed JSON messages over an NWConnection. Callbacks run on the main queue.
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()
    var onMessage: ((SyncMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String?) -> Void)?
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.close(error.localizedDescription)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.close(error.localizedDescription)
                return
            }
            if isComplete {
                self.close(nil)
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length >= 0, length < 64 * 1024 * 1024 else {
                close("Invalid message")
                return
            }
            guard buffer.count >= 4 + length else { return }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            if let message = try? JSONDecoder().decode(SyncMessage.self, from: body) {
                onMessage?(message)
            }
        }
    }

    func send(_ message: SyncMessage) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        let n = UInt32(body.count)
        var frame = Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }
}

/// "Send to Apple TV / Receive from iPhone": Bonjour `_streamforge._tcp`, a 4-digit pairing
/// code shown on the receiver, then an encrypted SyncBundle.
@MainActor
@Observable
final class LocalSyncService {
    static let shared = LocalSyncService()
    static let serviceType = "_streamforge._tcp"

    struct Peer: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
        static func == (a: Peer, b: Peer) -> Bool { a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    enum ReceiverState: Equatable {
        case idle
        case waiting
        case paired(code: String, peer: String?)
        case received(String)
        case failed(String)
    }

    enum SenderState: Equatable {
        case idle
        case browsing
        case connecting(String)
        case needsCode(String)
        case sending
        case sent(String)
        case failed(String)
    }

    private(set) var receiverState: ReceiverState = .idle
    private(set) var senderState: SenderState = .idle
    private(set) var peers: [Peer] = []
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var incoming: FramedConnection?
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var salt = Data()
    @ObservationIgnored private var attempts = 0

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var outgoing: FramedConnection?
    @ObservationIgnored private var peerSalt: Data?
    @ObservationIgnored private var peerName = ""

    private init() {}

    // MARK: Receiving

    func startReceiving() {
        stopReceiving()
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: SyncService.deviceName, type: Self.serviceType)
            listener.stateUpdateHandler = { state in
                Task { @MainActor in LocalSyncService.shared.listenerChanged(state) }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in LocalSyncService.shared.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            receiverState = .waiting
        } catch {
            receiverState = .failed(error.localizedDescription)
        }
    }

    func stopReceiving() {
        listener?.cancel()
        listener = nil
        incoming?.close(nil)
        incoming = nil
        if case .received = receiverState {} else { receiverState = .idle }
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case .failed(let error) = state {
            receiverState = .failed("Couldn't advertise on the local network: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        if incoming != nil {
            connection.cancel()
            return
        }
        let framed = FramedConnection(connection)
        incoming = framed
        attempts = 0
        newChallenge()
        framed.onReady = {
            Task { @MainActor in LocalSyncService.shared.sendChallengeToIncoming() }
        }
        framed.onMessage = { message in
            Task { @MainActor in LocalSyncService.shared.receiverGot(message) }
        }
        framed.onClose = { _ in
            Task { @MainActor in LocalSyncService.shared.incomingClosed() }
        }
        framed.start()
    }

    private func newChallenge() {
        code = String(format: "%04d", Int.random(in: 0...9999))
        salt = SyncCrypto.randomSalt()
        receiverState = .paired(code: code, peer: nil)
    }

    private func sendChallengeToIncoming() {
        if let incoming { sendChallenge(on: incoming) }
    }

    private func sendChallenge(on framed: FramedConnection) {
        framed.send(SyncMessage(kind: .challenge, name: SyncService.deviceName, salt: salt))
    }

    private func receiverGot(_ message: SyncMessage) {
        guard let incoming else { return }
        switch message.kind {
        case .bundle:
            guard let box = message.box else { return }
            do {
                let data = try SyncCrypto.open(box, code: code, salt: salt)
                let bundle = try SyncService.decode(data)
                incoming.send(SyncMessage(kind: .done, name: SyncService.deviceName))
                Task {
                    await SyncService.apply(bundle)
                    LocalSyncService.shared.receiverState = .received("Received \(bundle.summary) from \(bundle.deviceName).")
                    LocalSyncService.shared.listener?.cancel()
                    LocalSyncService.shared.listener = nil
                }
            } catch {
                attempts += 1
                if attempts >= 5 {
                    newChallenge()
                    attempts = 0
                    incoming.send(SyncMessage(kind: .error, message: "Too many wrong codes. A new code is shown on the TV."))
                    sendChallenge(on: incoming)
                } else {
                    incoming.send(SyncMessage(kind: .error, message: "Wrong code. Check the code on \(SyncService.deviceName)."))
                }
            }
        default:
            break
        }
    }

    private func incomingClosed() {
        incoming = nil
        if case .paired = receiverState { receiverState = listener == nil ? .idle : .waiting }
    }

    // MARK: Sending

    func startBrowsing() {
        stopBrowsing()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { results, _ in
            let found: [Peer] = results.compactMap { result in
                if case let .service(name, _, _, _) = result.endpoint { return Peer(name: name, endpoint: result.endpoint) }
                return nil
            }
            Task { @MainActor in LocalSyncService.shared.peers = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                let message = error.localizedDescription
                Task { @MainActor in LocalSyncService.shared.senderState = .failed("Local network search failed: \(message)") }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        senderState = .browsing
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        outgoing?.close(nil)
        outgoing = nil
        peers = []
        if case .sent = senderState {} else { senderState = .idle }
    }

    func connect(to peer: Peer) {
        outgoing?.close(nil)
        peerSalt = nil
        peerName = peer.name
        senderState = .connecting(peer.name)
        let framed = FramedConnection(NWConnection(to: peer.endpoint, using: .tcp))
        outgoing = framed
        framed.onMessage = { message in
            Task { @MainActor in LocalSyncService.shared.senderGot(message) }
        }
        framed.onClose = { reason in
            Task { @MainActor in LocalSyncService.shared.outgoingClosed(reason) }
        }
        framed.start()
    }

    private func senderGot(_ message: SyncMessage) {
        switch message.kind {
        case .challenge:
            peerSalt = message.salt
            if let name = message.name { peerName = name }
            senderState = .needsCode(peerName)
        case .done:
            senderState = .sent("Sent to \(peerName).")
            outgoing?.close(nil)
            outgoing = nil
        case .error:
            lastError = message.message
            senderState = .needsCode(peerName)
        case .bundle:
            break
        }
    }

    private func outgoingClosed(_ reason: String?) {
        outgoing = nil
        switch senderState {
        case .sent, .idle, .browsing: break
        default: senderState = .failed(reason ?? "The other device closed the connection.")
        }
    }

    /// Seals and sends this device's bundle with the code typed by the user.
    func send(code: String) {
        guard let outgoing, let salt = peerSalt else { return }
        lastError = nil
        do {
            let data = try SyncService.encode(SyncService.makeBundle())
            let box = try SyncCrypto.seal(data, code: code, salt: salt)
            senderState = .sending
            outgoing.send(SyncMessage(kind: .bundle, name: SyncService.deviceName, box: box))
        } catch {
            senderState = .failed(error.localizedDescription)
        }
    }
}
