import SwiftUI
import Foundation

private func steamIOSUncaughtExceptionHandler(_ exception: NSException) {
    let details = """
    name: \(exception.name.rawValue)
    reason: \(exception.reason ?? "(no reason)")
    call stack:
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
    _ = LogStore.shared.writeDiagnosticReport(
        reason: "Uncaught NSException",
        details: details
    )
}

@main
struct SteamIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NSSetUncaughtExceptionHandler(steamIOSUncaughtExceptionHandler)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    LogStore.shared.beginCrashSession()
                    GamepadInput.shared.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LogStore.shared.beginCrashSession()
                    case .background:
                        LogStore.shared.markCrashSessionClean()
                    default:
                        break
                    }
                }
        }
    }
}
