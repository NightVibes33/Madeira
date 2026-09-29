import SwiftUI

@main
struct SteamIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear { GamepadInput.shared.start() }
        }
    }
}
