import SwiftUI

@main
struct SteamOSiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear { GamepadInput.shared.start() }
        }
    }
}
