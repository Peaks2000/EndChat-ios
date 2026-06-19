import SwiftUI
import UIKit

@main
struct EndChatApp: App {
    @StateObject private var peerSession = PeerSession()
    @StateObject private var contactStore = ContactStore()
    @AppStorage("nickname") private var nickname = UIDevice.current.name
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(peerSession)
                .environmentObject(contactStore)
                .onAppear {
                    peerSession.setNickname(nickname)
                    peerSession.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { peerSession.start() }
                }
        }
    }
}
