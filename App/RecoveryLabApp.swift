import SwiftUI

@main
struct RecoveryLabApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        // Created at launch, including background relaunches by iOS, so Bluetooth is restored right away.
        _ = BandManager.shared
        _ = Uploader.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background {
                MinuteStore.shared.flush()
                Uploader.shared.uploadIfDue(force: true)
            }
        }
    }
}
