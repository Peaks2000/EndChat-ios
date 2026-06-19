import AVFoundation
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ContactStore: ObservableObject {
    @Published var contacts: [Contact] = [] { didSet { save() } }

    init() {
        guard let data = UserDefaults.standard.data(forKey: "contacts"),
              let saved = try? JSONDecoder().decode([Contact].self, from: data) else { return }
        contacts = saved
    }

    func add(_ contact: Contact) {
        if let peerIdentifier = contact.peerIdentifier,
           let index = contacts.firstIndex(where: { $0.peerIdentifier == peerIdentifier }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    func remove(at offsets: IndexSet) { contacts.remove(atOffsets: offsets) }

    private func save() {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: "contacts")
    }
}

struct ContentView: View {
    @EnvironmentObject private var peerSession: PeerSession
    @EnvironmentObject private var contactStore: ContactStore
    @State private var showingContacts = false
    @State private var showingSettings = false
    @State private var showingNearbyPeers = false
    @AppStorage("lanOnly") private var lanOnly = true
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("relayToken") private var relayToken = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Chats") {
                    ForEach(sortedThreads) { thread in
                        NavigationLink {
                            ChatView(thread: thread)
                        } label: {
                            ChatListRow(thread: thread)
                        }
                    }
                    .onDelete(perform: deleteThreads)
                }
            }
            .overlay {
                if peerSession.threads.isEmpty {
                    ContentUnavailableView("No Chats", systemImage: "message", description: Text("Tap + to find someone on your local network."))
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingNearbyPeers = true } label: { Image(systemName: "plus") }
                    Button { showingContacts = true } label: { Image(systemName: "person.2") }
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showingContacts) { ContactsView(store: contactStore) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingNearbyPeers) { NearbyPeersView() }
            .onAppear {
                peerSession.updateVerifiedContacts(contactStore.contacts)
                peerSession.configureRelay(lanOnly: lanOnly, url: relayURL, token: relayToken)
            }
            .onChange(of: contactStore.contacts) { _, contacts in
                peerSession.updateVerifiedContacts(contacts)
            }
            .onChange(of: lanOnly) { _, value in
                peerSession.configureRelay(lanOnly: value, url: relayURL, token: relayToken)
            }
            .alert("Incoming connection", isPresented: Binding(
                get: { peerSession.incomingInvite != nil },
                set: { if !$0 { peerSession.declineInvite() } }
            )) {
                Button("Decline", role: .cancel) { peerSession.declineInvite() }
                Button("Accept") { peerSession.acceptInvite() }
            } message: {
                Text("Accept a direct encrypted connection from \(peerSession.incomingInvite?.peer.displayName ?? "this peer")?")
            }
        }
    }

    private var sortedThreads: [ChatThread] {
        peerSession.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func deleteThreads(at offsets: IndexSet) {
        let ids = offsets.map { sortedThreads[$0].id }
        let original = IndexSet(ids.compactMap { id in peerSession.threads.firstIndex(where: { $0.id == id }) })
        peerSession.deleteThreads(at: original)
    }
}

struct NearbyPeersView: View {
    @EnvironmentObject private var peerSession: PeerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(peerSession.discoveryStatus, systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }

                Section("Nearby on LAN") {
                    ForEach(peerSession.discoveredPeers, id: \.self) { peer in
                        Button {
                            let id = peerSession.peerIdentifiers[peer] ?? "peer:\(peer.displayName)"
                            peerSession.ensureThread(id: id, title: peer.displayName)
                            peerSession.invite(peer)
                            dismiss()
                        } label: {
                            HStack {
                                Label(peer.displayName, systemImage: "person.crop.circle")
                                Spacer()
                                Text("Add").font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    if peerSession.discoveredPeers.isEmpty {
                        ContentUnavailableView("Searching…", systemImage: "wifi", description: Text("Keep EndChat open on both devices and allow Local Network access."))
                    }
                }
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { peerSession.refreshDiscovery() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onAppear { peerSession.refreshDiscovery() }
        }
    }
}

struct ChatListRow: View {
    @EnvironmentObject private var peerSession: PeerSession
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    HStack(spacing: 4) {
                        Text(thread.title).font(.headline)
                        if peerSession.verifiedPeerIdentifiers.contains(thread.id) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                    Text(thread.updatedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text(peerSession.messages(for: thread.id).last?.body ?? "No messages yet")
                    .lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ChatView: View {
    @EnvironmentObject private var peerSession: PeerSession
    @EnvironmentObject private var contactStore: ContactStore
    let thread: ChatThread
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var showingFilePicker = false
    @State private var showingContacts = false
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        lifecycleView
    }

    private var navigationView: some View {
        VStack(spacing: 10) {
            messageList
            composer
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .navigationTitle(thread.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Clear Chat", systemImage: "trash", role: .destructive) {
                        peerSession.clearThread(thread.id)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var presentedView: some View {
        navigationView
            .sheet(isPresented: $showingSettings) {
                SettingsView().environmentObject(peerSession)
            }
            .sheet(isPresented: $showingContacts) {
                ContactsView(store: contactStore).environmentObject(peerSession)
            }
    }

    private var importedView: some View {
        presentedView
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    try peerSession.sendFile(url, to: thread.id)
                } catch {
                    peerSession.messages.append(.system("File import failed: \(error.localizedDescription)"))
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    guard let item else { return }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        peerSession.sendImageData(data, to: thread.id)
                        selectedPhoto = nil
                    } catch {
                        selectedPhoto = nil
                    }
                }
            }
    }

    private var lifecycleView: some View {
        importedView
            .alert("Incoming connection", isPresented: Binding(
                get: { peerSession.incomingInvite != nil },
                set: { if !$0 { peerSession.declineInvite() } }
            )) {
                Button("Decline", role: .cancel) { peerSession.declineInvite() }
                Button("Accept") { peerSession.acceptInvite() }
            } message: {
                Text("Accept a direct encrypted connection from \(peerSession.incomingInvite?.peer.displayName ?? "this peer")?")
            }
    }

    private var peerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label(
                    peerSession.connectedPeers.isEmpty ? peerSession.discoveryStatus : "Direct • \(peerSession.connectedPeers.count) connected",
                    systemImage: peerSession.connectedPeers.isEmpty ? "antenna.radiowaves.left.and.right" : "lock.shield.fill"
                )
                .font(.subheadline.weight(.semibold))
                .padding(10)
                .adaptiveGlass(radius: 16)

                ForEach(peerSession.discoveredPeers, id: \.self) { peer in
                    Button { peerSession.invite(peer) } label: {
                        Label(peer.displayName, systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }

                Button { peerSession.refreshDiscovery() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(peerSession.messages(for: thread.id)) { message in
                        MessageBubble(
                            message: message,
                            onRetry: { peerSession.retryMessage(message.id) },
                            onGiveUp: { peerSession.giveUpMessage(message.id) }
                        )
                            .id(message.id)
                            .contextMenu {
                                if message.isMine,
                                   message.deliveryState == .queued || message.deliveryState == .sending {
                                    Button("Cancel Send", role: .destructive) { peerSession.cancelMessage(message.id) }
                                }
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: peerSession.messages) { _, _ in
                guard let id = peerSession.messages(for: thread.id).last?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
            }
            Button { showingFilePicker = true } label: { Image(systemName: "paperclip") }
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
            Button {
                peerSession.sendText(draft, to: thread.id)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .adaptiveGlass(radius: 24)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: () -> Void = {}
    var onGiveUp: () -> Void = {}
    @State private var showingFailureActions = false

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 45) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                if message.kind != .system {
                    Text(message.sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: 5) {
                    if message.kind == .image,
                       let path = message.localFilePath,
                       let image = UIImage(contentsOfFile: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 260, minHeight: 120, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text(message.body)
                            .foregroundStyle(message.isMine ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(message.isMine ? Color.blue : Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if message.kind == .image, message.localFilePath == nil {
                        Label("Receiving image…", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(message.date, style: .time)
                    if let state = message.deliveryState {
                        if state == .failed {
                            Button {
                                showingFailureActions = true
                            } label: {
                                Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(deliveryText(state))
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.isMine { Spacer(minLength: 45) }
        }
        .confirmationDialog("Message Not Delivered", isPresented: $showingFailureActions) {
            Button("Try Again") { onRetry() }
            Button("Give Up", role: .destructive) { onGiveUp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Try sending this message again, or remove it from this device.")
        }
    }

    private func deliveryText(_ state: DeliveryState) -> String {
        switch state {
        case .queued: "Waiting"
        case .sending: "Sending"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

struct ContactsView: View {
    @ObservedObject var store: ContactStore
    @EnvironmentObject private var peerSession: PeerSession
    @State private var showingScanner = false
    @State private var showingMyQR = false
    @State private var scannedCard: QRContactCard?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.contacts) { contact in ContactRow(contact: contact) }
                    .onDelete(perform: store.remove)
            }
            .overlay {
                if store.contacts.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.crop.circle.badge.plus", description: Text("Scan another user's EndChat QR to add and verify them."))
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingScanner = true } label: { Label("Scan EndChat QR", systemImage: "qrcode.viewfinder") }
                        Button { showingMyQR = true } label: { Label("My QR", systemImage: "qrcode") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { value in
                    showingScanner = false
                    if let card = QRContactCard.decode(value) { scannedCard = card }
                }
            }
            .sheet(item: $scannedCard) { card in
                ContactEditor(store: store, peerIdentifier: card.peerIdentifier, publicKey: card.publicKey, suggestedName: card.nickname)
            }
            .sheet(isPresented: $showingMyQR) { MyQRView(nickname: peerSession.nickname) }
        }
    }
}

extension QRContactCard: Identifiable { var id: String { peerIdentifier } }

struct ContactRow: View {
    let contact: Contact
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = contact.profileImageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 46, height: 46).clipShape(Circle())
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(contact.name).font(.headline)
                    if contact.verifiedPublicKey != nil {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                    }
                }
                if let nickname = contact.nickname, !nickname.isEmpty { Text(nickname).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ContactEditor: View {
    @ObservedObject var store: ContactStore
    @Environment(\.dismiss) private var dismiss
    let peerIdentifier: String?
    let publicKey: Data?
    @State private var name: String
    @State private var nickname: String
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?

    init(store: ContactStore, peerIdentifier: String?, publicKey: Data?, suggestedName: String) {
        self.store = store
        self.peerIdentifier = peerIdentifier
        self.publicKey = publicKey
        _name = State(initialValue: suggestedName)
        _nickname = State(initialValue: suggestedName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Group {
                                if let photoData, let image = UIImage(data: photoData) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "person.crop.circle.badge.camera").resizable().foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 100, height: 100).clipShape(Circle())
                        }
                        Spacer()
                    }
                    TextField("Name", text: $name)
                    TextField("Nickname", text: $nickname)
                } footer: { Text(publicKey == nil ? "This older QR has no verification key." : "The QR cryptographically verifies this contact's encryption key.") }
            }
            .navigationTitle("New Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.add(Contact(peerIdentifier: peerIdentifier, name: name.trimmingCharacters(in: .whitespacesAndNewlines), nickname: nickname, profileImageData: photoData, verifiedPublicKey: publicKey))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                Task { photoData = try? await item?.loadTransferable(type: Data.self) }
            }
        }
    }
}

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    var onScan: (String) -> Void
    var body: some View {
        NavigationStack {
            ScannerCameraView(onScan: onScan)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan EndChat QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ScannerCameraView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }
    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.configure() }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned, let code = objects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }
        hasScanned = true
        session.stopRunning()
        onScan?(value)
    }
}

struct MyQRView: View {
    @EnvironmentObject private var peerSession: PeerSession
    let nickname: String
    var body: some View {
        VStack(spacing: 18) {
            Text(nickname).font(.title.bold())
            if let value = peerSession.myContactCard.encodedString(), let image = qrImage(value) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 270, height: 270)
            }
            Text("Scan this on the other iPhone. Your private peer identity stays on the two devices.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
        .presentationDetents([.medium])
    }

    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var peerSession: PeerSession
    @AppStorage("nickname") private var nickname = UIDevice.current.name
    @AppStorage("lanOnly") private var lanOnly = true
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("relayToken") private var relayToken = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $lanOnly) {
                        Label("LAN Only", systemImage: "network")
                    }
                    .toggleStyle(.switch)
                    .tint(.green)
                } header: {
                    Text("Network Mode")
                } footer: {
                    Text(lanOnly ? "Server-free mode is on. EndChat will make zero WAN relay requests." : "LAN remains preferred, with your self-hosted relay available as a fallback.")
                }

                Section("Identity") { TextField("Nickname", text: $nickname) }
                Section("Connection") {
                    LabeledContent("Route", value: "Nearby peer-to-peer")
                    LabeledContent("LAN discovery", value: peerSession.discoveryStatus)
                    LabeledContent("Encryption", value: "Required")
                    LabeledContent("Transfer", value: peerSession.transferStatus)
                    Button("Refresh LAN Discovery") { peerSession.refreshDiscovery() }
                }
                if !lanOnly {
                    Section {
                        TextField("Domain or IP address", text: $relayURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Relay token", text: $relayToken)
                        LabeledContent("Status", value: peerSession.relayStatus)
                        Button("Test Custom Server") {
                            peerSession.configureRelay(lanOnly: false, url: relayURL, token: relayToken)
                            Task { await peerSession.testRelay(url: relayURL, token: relayToken) }
                        }
                        .disabled(relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("Custom Server")
                    } footer: {
                        Text("Enter an HTTPS hostname or IP, optionally with a port—for example chat.example.com or 203.0.113.10:8443. The server only receives opaque end-to-end-encrypted packets.")
                    }
                }
                Section {
                    Text("iOS suspends ordinary apps in the background. EndChat retries while running and whenever it returns to the foreground; guaranteed background delivery without a push server is not available on iOS.")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: lanOnly) { _, value in
                peerSession.configureRelay(lanOnly: value, url: relayURL, token: relayToken)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        peerSession.setNickname(nickname)
                        peerSession.configureRelay(lanOnly: lanOnly, url: relayURL, token: relayToken)
                        dismiss()
                    }
                }
            }
        }
    }
}
