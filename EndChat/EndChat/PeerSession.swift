import Foundation
import CryptoKit
import MultipeerConnectivity
import Security
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PeerSession: NSObject, ObservableObject {
    @Published var nickname = UIDevice.current.name
    @Published var messages: [ChatMessage] = [] {
        didSet { persistMessages() }
    }
    @Published var threads: [ChatThread] = [] {
        didSet { persistThreads() }
    }
    @Published var discoveredPeers: [MCPeerID] = []
    @Published var connectedPeers: [MCPeerID] = []
    @Published var incomingInvite: (peer: MCPeerID, handler: (Bool, MCSession?) -> Void)?
    @Published var transferStatus = "Idle"
    @Published var peerIdentifiers: [MCPeerID: String] = [:]
    @Published var discoveryStatus = "Starting LAN discovery…"
    @Published var relayStatus = "Not configured"

    private let serviceType = "endchat"
    private let deviceIdentifier: String
    private let encryptionKey: Curve25519.KeyAgreement.PrivateKey
    private var peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var retryTimer: Timer?
    private var isStarted = false
    private var isBrowsing = false
    private var discoveryStopTask: Task<Void, Never>?
    private var invitedPeers = Set<MCPeerID>()
    private var peerEncryptionKeys: [MCPeerID: SymmetricKey] = [:]
    private var trustedPublicKeys: [String: Data] = [:]
    private var knownPublicKeys: [String: Data] = [:]
    private var relayTask: Task<Void, Never>?
    private var relayBaseURL: URL?
    private var relayToken = ""
    private var lanOnly = true
    private var receivedResourcePaths: [String: String] = [:]
    @Published var verifiedPeerIdentifiers = Set<String>()

    var myContactCard: QRContactCard {
        QRContactCard(peerIdentifier: deviceIdentifier, nickname: nickname, publicKey: encryptionKey.publicKey.rawRepresentation)
    }

    override init() {
        encryptionKey = Self.loadEncryptionKey()
        if let saved = UserDefaults.standard.string(forKey: "deviceIdentifier") {
            deviceIdentifier = saved
        } else {
            let value = UUID().uuidString
            UserDefaults.standard.set(value, forKey: "deviceIdentifier")
            deviceIdentifier = value
        }
        super.init()
        loadMessages()
        loadThreads()
        if let data = UserDefaults.standard.data(forKey: "knownPublicKeys"),
           let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
            knownPublicKeys = saved
        }
        rebuild()
    }

    deinit { retryTimer?.invalidate(); relayTask?.cancel(); discoveryStopTask?.cancel() }

    func setNickname(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? UIDevice.current.name : trimmed
        guard next != nickname else { return }
        nickname = next
        stop()
        rebuild()
        start()
    }

    func start() {
        if isStarted {
            retryPendingMessages()
            return
        }
        isStarted = true
        discoveryStatus = "LAN search is idle"
        advertiser.startAdvertisingPeer()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryPendingMessages() }
        }
        retryPendingMessages()
    }

    func refreshDiscovery() {
        if isBrowsing { browser.stopBrowsingForPeers() }
        discoveredPeers.removeAll()
        peerIdentifiers.removeAll()
        invitedPeers.removeAll()
        discoveryStatus = "Refreshing local network…"
        isBrowsing = true
        browser.startBrowsingForPeers()
        discoveryStopTask?.cancel()
        discoveryStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endDiscovery()
        }
    }

    func endDiscovery() {
        guard isBrowsing else { return }
        discoveryStopTask?.cancel()
        discoveryStopTask = nil
        browser.stopBrowsingForPeers()
        isBrowsing = false
        discoveredPeers.removeAll()
        peerIdentifiers = peerIdentifiers.filter { session.connectedPeers.contains($0.key) }
        discoveryStatus = connectedPeers.isEmpty ? "LAN search is idle" : "Connected directly on the local network"
    }

    func updateVerifiedContacts(_ contacts: [Contact]) {
        trustedPublicKeys = Dictionary(uniqueKeysWithValues: contacts.compactMap { contact in
            guard let id = contact.peerIdentifier, let key = contact.verifiedPublicKey else { return nil }
            return (id, key)
        })
        for (id, key) in trustedPublicKeys { knownPublicKeys[id] = key }
        persistKnownPublicKeys()
    }

    func configureRelay(lanOnly: Bool, url: String, token: String) {
        self.lanOnly = lanOnly
        relayToken = token
        relayBaseURL = Self.normalizedRelayURL(url)
        relayTask?.cancel()
        relayTask = nil
        if lanOnly {
            relayStatus = "Disabled by LAN Only"
            return
        }
        guard relayBaseURL?.scheme == "https" else {
            relayStatus = "Enter an HTTPS server"
            return
        }
        relayStatus = "Configured"
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollRelay()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        retryPendingMessages()
    }

    func testRelay(url: String, token: String) async {
        guard !lanOnly else {
            relayStatus = "Turn off LAN Only to test"
            return
        }
        guard let base = Self.normalizedRelayURL(url), base.scheme == "https" else {
            relayStatus = "A valid HTTPS domain or IP is required"
            return
        }
        relayStatus = "Testing…"
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 10
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            relayStatus = (response as? HTTPURLResponse)?.statusCode == 200 ? "Connected" : "Server returned an error"
        } catch {
            relayStatus = "Unavailable: \(error.localizedDescription)"
        }
    }

    private static func normalizedRelayURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        return components.url
    }

    func stop() {
        isStarted = false
        advertiser.stopAdvertisingPeer()
        if isBrowsing { browser.stopBrowsingForPeers() }
        isBrowsing = false
        session.disconnect()
        retryTimer?.invalidate()
        retryTimer = nil
        discoveredPeers.removeAll()
        connectedPeers.removeAll()
        invitedPeers.removeAll()
    }

    func invite(_ peer: MCPeerID) {
        guard !invitedPeers.contains(peer), !session.connectedPeers.contains(peer) else { return }
        invitedPeers.insert(peer)
        browser.invitePeer(peer, to: session, withContext: Data(deviceIdentifier.utf8), timeout: 30)
    }

    func acceptInvite() {
        incomingInvite?.handler(true, session)
        incomingInvite = nil
    }

    func declineInvite() {
        incomingInvite?.handler(false, nil)
        incomingInvite = nil
    }

    func ensureThread(id: String, title: String) {
        if let index = threads.firstIndex(where: { $0.id == id }) {
            if threads[index].title != title { threads[index].title = title }
        } else {
            threads.append(ChatThread(id: id, title: title))
        }
    }

    func deleteThreads(at offsets: IndexSet) {
        let ids = Set(offsets.map { threads[$0].id })
        threads.remove(atOffsets: offsets)
        messages.removeAll { message in
            guard let id = message.conversationID else { return false }
            return ids.contains(id)
        }
    }

    func clearThread(_ id: String) {
        messages.removeAll { $0.conversationID == id }
        if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].updatedAt = Date() }
    }

    func messages(for conversationID: String) -> [ChatMessage] {
        messages.filter { $0.conversationID == conversationID }
    }

    func sendText(_ text: String, to conversationID: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let message = ChatMessage(sender: nickname, body: body, isMine: true, kind: .text, conversationID: conversationID)
        var pending = message
        pending.deliveryState = .queued
        messages.append(pending)
        touchThread(conversationID)
        retryPendingMessages()
    }

    func cancelMessage(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.isMine }),
              messages[index].deliveryState != .delivered else { return }
        messages[index].deliveryState = .cancelled
    }

    func sendImageData(_ data: Data, name: String = "Image.jpg", to conversationID: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentImages", isDirectory: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try sendFile(url, to: conversationID)
        } catch {
            messages.append(.system("Could not prepare image: \(error.localizedDescription)"))
        }
    }

    func sendFile(_ url: URL, to conversationID: String) throws {
        let metadataAccess = url.startAccessingSecurityScopedResource()
        defer {
            if metadataAccess { url.stopAccessingSecurityScopedResource() }
        }
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .localizedNameKey])
        let size = Int64(resourceValues.fileSize ?? 0)
        let name = resourceValues.localizedName ?? url.lastPathComponent

        guard size <= maxSharedFileBytes else {
            messages.append(.system("\(name) is larger than the 10 GB file limit."))
            return
        }

        let destinationPeers = peers(for: conversationID)
        guard !destinationPeers.isEmpty else {
            messages.append(.system("Connect to a peer before sending \(name)."))
            return
        }

        let message = ChatMessage(
            sender: nickname,
            body: name,
            isMine: true,
            kind: UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? .image : .file,
            fileName: name,
            fileSize: size,
            localFilePath: url.path,
            deliveryState: .queued,
            conversationID: conversationID
        )
        messages.append(message)
        touchThread(conversationID)
        retryPendingMessages()

        for peer in destinationPeers {
            let transferAccess = url.startAccessingSecurityScopedResource()
            session.sendResource(at: url, withName: name, toPeer: peer) { [weak self] error in
                Task { @MainActor in
                    if transferAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                    if let error {
                        self?.messages.append(ChatMessage(
                            sender: "EndChat",
                            body: "File transfer failed: \(error.localizedDescription)",
                            isMine: false,
                            kind: .system,
                            conversationID: conversationID
                        ))
                    } else {
                        self?.transferStatus = "Sent \(name)"
                    }
                }
            }
        }
    }

    private func rebuild() {
        peerID = MCPeerID(displayName: nickname)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["nickname": nickname, "id": deviceIdentifier],
            serviceType: serviceType
        )
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    @discardableResult
    private func sendWireMessage(from message: ChatMessage) -> Bool {
        let wire = WireMessage(
            id: message.id,
            sender: message.sender,
            body: message.body,
            date: message.date,
            kind: message.kind,
            fileName: message.fileName,
            fileSize: message.fileSize,
            senderIdentifier: deviceIdentifier
        )
        let envelope = WireEnvelope.message(wire)
        let destinationPeers = message.conversationID.map(peers(for:)) ?? session.connectedPeers
        var sentOnLAN = !destinationPeers.isEmpty
        for peer in destinationPeers {
            if !sendEncrypted(envelope, to: peer) {
                sendKeyExchange(to: peer)
                sentOnLAN = false
            }
        }
        if !sentOnLAN, let destination = message.conversationID, !lanOnly {
            Task { [weak self] in await self?.sendViaRelay(envelope, to: destination, packetID: message.id.uuidString) }
        }
        return sentOnLAN
    }

    private func retryPendingMessages() {
        for index in messages.indices where messages[index].isMine &&
            (messages[index].deliveryState == .queued || messages[index].deliveryState == .sending) {
            if sendWireMessage(from: messages[index]) {
                messages[index].deliveryState = .sending
            }
        }
    }

    private func sendAcknowledgement(for id: UUID, to peer: MCPeerID) {
        _ = sendEncrypted(.acknowledgement(id), to: peer)
    }

    private func sendKeyExchange(to peer: MCPeerID) {
        let packet = SecurePacket(kind: .keyExchange, publicKey: encryptionKey.publicKey.rawRepresentation, ciphertext: nil)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    @discardableResult
    private func sendEncrypted(_ envelope: WireEnvelope, to peer: MCPeerID) -> Bool {
        guard let key = peerEncryptionKeys[peer],
              let plaintext = try? JSONEncoder().encode(envelope),
              let sealed = try? ChaChaPoly.seal(plaintext, using: key) else {
            return false
        }
        guard let packetData = try? JSONEncoder().encode(
            SecurePacket(kind: .encrypted, publicKey: nil, ciphertext: sealed.combined)
        ) else { return false }
        do {
            try session.send(packetData, toPeers: [peer], with: .reliable)
            return true
        } catch {
            return false
        }
    }

    private func receiveSecurePacket(_ packet: SecurePacket, from peer: MCPeerID) {
        switch packet.kind {
        case .keyExchange:
            guard let rawKey = packet.publicKey,
                  let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey),
                  let secret = try? encryptionKey.sharedSecretFromKeyAgreement(with: publicKey) else { return }
            let wasMissing = peerEncryptionKeys[peer] == nil
            let local = encryptionKey.publicKey.rawRepresentation
            let info = local.lexicographicallyPrecedes(rawKey) ? local + rawKey : rawKey + local
            peerEncryptionKeys[peer] = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("EndChat-E2EE-v1".utf8),
                sharedInfo: info,
                outputByteCount: 32
            )
            if let id = peerIdentifiers[peer], trustedPublicKeys[id] == rawKey {
                verifiedPeerIdentifiers.insert(id)
            }
            if let id = peerIdentifiers[peer] {
                knownPublicKeys[id] = rawKey
                persistKnownPublicKeys()
            }
            if wasMissing { sendKeyExchange(to: peer) }
            retryPendingMessages()
        case .encrypted:
            guard let key = peerEncryptionKeys[peer], let ciphertext = packet.ciphertext,
                  let box = try? ChaChaPoly.SealedBox(combined: ciphertext),
                  let plaintext = try? ChaChaPoly.open(box, using: key),
                  let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: plaintext) else { return }
            handle(envelope, from: peer)
        }
    }

    private func handle(_ envelope: WireEnvelope, from peer: MCPeerID) {
        switch envelope.kind {
        case .message:
            if let wire = envelope.message { receive(wire, from: peer) }
        case .acknowledgement:
            if let id = envelope.acknowledgedID { acknowledge(id) }
        }
    }

    private func receive(_ wire: WireMessage, from peer: MCPeerID) {
        if messages.contains(where: { $0.id == wire.id }) {
            sendAcknowledgement(for: wire.id, to: peer)
            return
        }
        let conversationID = wire.senderIdentifier ?? peerIdentifiers[peer] ?? "peer:\(peer.displayName)"
        peerIdentifiers[peer] = conversationID
        ensureThread(id: conversationID, title: wire.sender)
        messages.append(
            ChatMessage(
                id: wire.id,
                sender: wire.sender,
                body: wire.body,
                date: wire.date,
                isMine: false,
                kind: wire.kind,
                fileName: wire.fileName,
                fileSize: wire.fileSize,
                localFilePath: wire.fileName.flatMap { receivedResourcePaths[$0] },
                conversationID: conversationID,
                verifiedSender: verifiedPeerIdentifiers.contains(conversationID)
            )
        )
        touchThread(conversationID)
        sendAcknowledgement(for: wire.id, to: peer)
    }

    private func acknowledge(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].deliveryState = .delivered
    }

    private func relayKey(for publicKeyData: Data) -> SymmetricKey? {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData),
              let secret = try? encryptionKey.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        let local = encryptionKey.publicKey.rawRepresentation
        let info = local.lexicographicallyPrecedes(publicKeyData) ? local + publicKeyData : publicKeyData + local
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("EndChat-E2EE-v1".utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    private func sendViaRelay(_ envelope: WireEnvelope, to recipient: String, packetID: String) async {
        guard !lanOnly, let base = relayBaseURL, let publicKey = knownPublicKeys[recipient],
              let key = relayKey(for: publicKey),
              let plaintext = try? JSONEncoder().encode(envelope),
              let box = try? ChaChaPoly.seal(plaintext, using: key) else { return }
        let packet = RelayPacket(
            id: packetID,
            from: deviceIdentifier,
            to: recipient,
            senderPublicKey: encryptionKey.publicKey.rawRepresentation,
            ciphertext: box.combined
        )
        guard let body = try? JSONEncoder().encode(packet) else { return }
        var request = URLRequest(url: base.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !relayToken.isEmpty { request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization") }
        _ = try? await URLSession.shared.data(for: request)
    }

    private func pollRelay() async {
        guard !lanOnly, let base = relayBaseURL else { return }
        var request = URLRequest(url: base.appending(path: "v1/messages/\(deviceIdentifier)"))
        if !relayToken.isEmpty { request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let packets = try? JSONDecoder().decode([RelayPacket].self, from: data) else { return }
        for packet in packets { receiveRelayPacket(packet) }
    }

    private func receiveRelayPacket(_ packet: RelayPacket) {
        if let trusted = trustedPublicKeys[packet.from], trusted != packet.senderPublicKey { return }
        knownPublicKeys[packet.from] = packet.senderPublicKey
        persistKnownPublicKeys()
        guard let key = relayKey(for: packet.senderPublicKey),
              let box = try? ChaChaPoly.SealedBox(combined: packet.ciphertext),
              let plaintext = try? ChaChaPoly.open(box, using: key),
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: plaintext) else { return }
        if trustedPublicKeys[packet.from] == packet.senderPublicKey { verifiedPeerIdentifiers.insert(packet.from) }
        switch envelope.kind {
        case .acknowledgement:
            if let id = envelope.acknowledgedID { acknowledge(id) }
        case .message:
            guard let wire = envelope.message else { return }
            if !messages.contains(where: { $0.id == wire.id }) {
                ensureThread(id: packet.from, title: wire.sender)
                messages.append(ChatMessage(
                    id: wire.id, sender: wire.sender, body: wire.body, date: wire.date,
                    isMine: false, kind: wire.kind, fileName: wire.fileName, fileSize: wire.fileSize,
                    conversationID: packet.from,
                    verifiedSender: verifiedPeerIdentifiers.contains(packet.from)
                ))
                touchThread(packet.from)
            }
            if let id = envelope.message?.id {
                Task { [weak self] in
                    await self?.sendViaRelay(.acknowledgement(id), to: packet.from, packetID: "ack-\(id.uuidString)")
                }
            }
        }
    }

    private func persistKnownPublicKeys() {
        guard let data = try? JSONEncoder().encode(knownPublicKeys) else { return }
        UserDefaults.standard.set(data, forKey: "knownPublicKeys")
    }

    private func persistMessages() {
        guard let data = try? JSONEncoder().encode(messages.suffix(1_000)) else { return }
        UserDefaults.standard.set(data, forKey: "messages")
    }

    private func persistThreads() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        UserDefaults.standard.set(data, forKey: "threads")
    }

    private func loadThreads() {
        guard let data = UserDefaults.standard.data(forKey: "threads"),
              let saved = try? JSONDecoder().decode([ChatThread].self, from: data) else { return }
        threads = saved
    }

    private func touchThread(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].updatedAt = Date()
    }

    private func peers(for conversationID: String) -> [MCPeerID] {
        session.connectedPeers.filter {
            peerIdentifiers[$0] == conversationID || "peer:\($0.displayName)" == conversationID
        }
    }

    private func loadMessages() {
        if let data = UserDefaults.standard.data(forKey: "messages"),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        } else {
            messages = [.system("Add a contact by QR, or connect to a nearby peer, then send directly.")]
        }
    }

    private static func loadEncryptionKey() -> Curve25519.KeyAgreement.PrivateKey {
        let account = "EndChat.Curve25519.PrivateKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation
        ]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}

extension PeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            connectedPeers = session.connectedPeers
            switch state {
            case .connected:
                invitedPeers.remove(peerID)
                messages.append(.system("\(peerID.displayName) connected."))
                discoveryStatus = "Connected directly on the local network"
                sendKeyExchange(to: peerID)
                retryPendingMessages()
            case .notConnected:
                invitedPeers.remove(peerID)
                messages.append(.system("\(peerID.displayName) disconnected."))
                discoveryStatus = "Searching on the local network…"
                peerEncryptionKeys.removeValue(forKey: peerID)
            case .connecting:
                transferStatus = "Connecting to \(peerID.displayName)"
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let packet = try? JSONDecoder().decode(SecurePacket.self, from: data) else { return }
            receiveSecurePacket(packet, from: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        Task { @MainActor in
            transferStatus = "Receiving \(resourceName)"
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        Task { @MainActor in
            if let error {
                messages.append(.system("Receive failed: \(error.localizedDescription)"))
                return
            }
            guard let localURL else { return }
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(resourceName)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: localURL, to: destination)
                receivedResourcePaths[resourceName] = destination.path
                if let index = messages.lastIndex(where: {
                    !$0.isMine && $0.fileName == resourceName && ($0.kind == .image || $0.kind == .file)
                }) {
                    messages[index].localFilePath = destination.path
                }
                transferStatus = "Saved \(resourceName)"
            } catch {
                messages.append(.system("Could not save \(resourceName): \(error.localizedDescription)"))
            }
        }
    }
}

extension PeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            discoveryStatus = "LAN advertising failed: \(error.localizedDescription)"
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            if let identifier = context.flatMap({ String(data: $0, encoding: .utf8) }) {
                peerIdentifiers[peerID] = identifier
            }
            incomingInvite = (peerID, invitationHandler)
        }
    }
}

extension PeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            discoveryStatus = "LAN discovery failed: \(error.localizedDescription)"
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard peerID.displayName != nickname, !discoveredPeers.contains(peerID) else { return }
            discoveredPeers.append(peerID)
            discoveryStatus = "Found \(discoveredPeers.count) nearby peer\(discoveredPeers.count == 1 ? "" : "s")"
            if let identifier = info?["id"] { peerIdentifiers[peerID] = identifier }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            discoveredPeers.removeAll { $0 == peerID }
            peerIdentifiers.removeValue(forKey: peerID)
            invitedPeers.remove(peerID)
            if discoveredPeers.isEmpty, connectedPeers.isEmpty {
                discoveryStatus = "Searching on the local network…"
            }
        }
    }
}
