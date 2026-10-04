// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import UniformTypeIdentifiers


/// Optional external Steam library. The user grants one folder through the
/// Files picker; SteamIOS keeps a security-scoped bookmark for that folder,
/// exposes it to Wine as E:, and also presents the same storage through the
/// fixed C:\\SteamIOSExternal symlink so upstream SteamIOS Dock can keep its
/// existing C:-relative launch paths unchanged.
@MainActor
final class ExternalSteamDrive: NSObject, ObservableObject, UIDocumentPickerDelegate {
    static let shared = ExternalSteamDrive()

    @Published private(set) var configured = false
    @Published private(set) var displayName = "Not connected"

    private let bookmarkKey = "SteamIOS.ExternalDriveBookmark.v1"
    private let contentIDKey = "SteamIOS.ExternalDriveContentID.v1"
    private var scopedURL: URL?

    override private init() { super.init() }

    func presentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        guard let presenter = Self.topViewController() else {
            LogStore.shared.log("[external-drive] no active presenter", level: .error)
            return
        }
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        activate(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    func restoreAndMountIfAvailable() {
        if let scopedURL {
            do {
                try configureMount(at: scopedURL)
                configured = true
                displayName = scopedURL.lastPathComponent
            } catch {
                configured = false
                LogStore.shared.log("[external-drive] remount failed: \(error.localizedDescription)", level: .error)
            }
            return
        }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(domain: "SteamIOS.ExternalDrive", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The external drive permission is no longer available. Choose the drive again."])
            }
            scopedURL = url
            if stale { try saveBookmark(for: url) }
            try configureMount(at: url)
            configured = true
            displayName = url.lastPathComponent
            LogStore.shared.log("[external-drive] restored \(url.lastPathComponent)", level: .success)
        } catch {
            configured = false
            LogStore.shared.log("[external-drive] restore failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func activate(_ url: URL) {
        if let old = scopedURL, old != url { old.stopAccessingSecurityScopedResource() }
        guard url.startAccessingSecurityScopedResource() else {
            LogStore.shared.log("[external-drive] access denied", level: .error)
            return
        }
        do {
            try saveBookmark(for: url)
            scopedURL = url
            try configureMount(at: url)
            configured = true
            displayName = url.lastPathComponent
            LogStore.shared.log("[external-drive] ready: \(url.path)", level: .success)
            MadeiraDockModel.shared.refresh()
        } catch {
            if scopedURL == url { scopedURL = nil; url.stopAccessingSecurityScopedResource() }
            configured = false
            LogStore.shared.log("[external-drive] setup failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func configureMount(at selectedRoot: URL) throws {
        let fm = FileManager.default
        let externalRoot = selectedRoot.appendingPathComponent("SteamIOS", isDirectory: true)
        let library = externalRoot.appendingPathComponent("SteamLibrary", isDirectory: true)

        var coordinationError: NSError?
        var setupError: Error?
        NSFileCoordinator().coordinate(writingItemAt: selectedRoot, options: .forMerging,
                                       error: &coordinationError) { coordinatedRoot in
            do {
                let root = coordinatedRoot.appendingPathComponent("SteamIOS", isDirectory: true)
                let lib = root.appendingPathComponent("SteamLibrary", isDirectory: true)
                for sub in ["steamapps/common", "steamapps/downloading", "steamapps/workshop", "steamapps/shadercache"] {
                    try fm.createDirectory(at: lib.appendingPathComponent(sub, isDirectory: true),
                                           withIntermediateDirectories: true)
                }
                let probe = root.appendingPathComponent(".steamios-write-test")
                try Data("SteamIOS".utf8).write(to: probe, options: .atomic)
                try fm.removeItem(at: probe)
            } catch { setupError = error }
        }
        if let coordinationError { throw coordinationError }
        if let setupError { throw setupError }

        let prefix = MadeiraDock.prefix
        let dosDevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        let driveC = MadeiraDock.drive
        try fm.createDirectory(at: dosDevices, withIntermediateDirectories: true)
        try fm.createDirectory(at: driveC, withIntermediateDirectories: true)

        try replaceSymlink(at: dosDevices.appendingPathComponent("e:"), destination: externalRoot.path)
        try replaceSymlink(at: driveC.appendingPathComponent("SteamIOSExternal"), destination: externalRoot.path)
        try registerLibraryWithSteam()
    }

    private func replaceSymlink(at link: URL, destination: String) throws {
        let fm = FileManager.default
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == destination { return }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    private func registerLibraryWithSteam() throws {
        guard MadeiraDock.clientInstalled else { return }
        let fm = FileManager.default
        let steamApps = MadeiraDock.clientRoot.appendingPathComponent("steamapps", isDirectory: true)
        try fm.createDirectory(at: steamApps, withIntermediateDirectories: true)
        let vdf = steamApps.appendingPathComponent("libraryfolders.vdf")
        let externalPath = #"C:\\SteamIOSExternal\\SteamLibrary"#

        var text: String
        if let existing = try? String(contentsOf: vdf, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = existing
        } else {
            let internalPath = SteamRuntimeFiles.windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
            text = """
            "libraryfolders"
            {
                "0"
                {
                    "path" "\(internalPath)"
                    "label" ""
                    "contentid" "1"
                    "totalsize" "0"
                    "update_clean_bytes_tally" "0"
                    "time_last_update_corruption" "0"
                    "apps"
                    {
                    }
                }
            }
            """
        }
        if text.contains(#""path" "C:\\SteamIOSExternal\\SteamLibrary""#) { return }

        let defaults = UserDefaults.standard
        let contentID: String
        if let saved = defaults.string(forKey: contentIDKey) {
            contentID = saved
        } else {
            contentID = String(UInt64.random(in: 1_000_000_000_000_000_000...8_999_999_999_999_999_999))
            defaults.set(contentID, forKey: contentIDKey)
        }

        let block = """

                "9000"
                {
                    "path" "\(externalPath)"
                    "label" "SteamIOS External"
                    "contentid" "\(contentID)"
                    "totalsize" "0"
                    "update_clean_bytes_tally" "0"
                    "time_last_update_corruption" "0"
                    "apps"
                    {
                    }
                }
        """
        guard let closing = text.lastIndex(of: "}") else {
            throw NSError(domain: "SteamIOS.ExternalDrive", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Steam libraryfolders.vdf is malformed."])
        }
        text.insert(contentsOf: block, at: closing)
        try text.write(to: vdf, atomically: true, encoding: .utf8)
        LogStore.shared.log("[external-drive] Steam library registered at C:\\SteamIOSExternal\\SteamLibrary", level: .success)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        if let nav = controller as? UINavigationController { return nav.visibleViewController ?? nav }
        if let tab = controller as? UITabBarController { return tab.selectedViewController ?? tab }
        return controller
    }
}

/// State of the SteamIOS Dock sheet: sign-in, Valve's client components, the
/// installed games and the last Dock result.
@MainActor
final class MadeiraDockModel: ObservableObject {
    static let shared = MadeiraDockModel()

    @Published private(set) var games: [DockGame] = []
    @Published private(set) var clientInstalled = false
    @Published private(set) var preparing = false
    @Published private(set) var progress = ""
    @Published var error: String?
    /// The last Dock launch's outcome, from the host report.
    @Published var status: String?
    /// Opt-in per launch: a 512 MB JIT pool instead of the standard one.
    @Published var compactPool = SteamSignIn.flag("MADEIRA_DOCK_COMPACT_POOL", default: false)
    /// App ID -> number of one-time install programs in the game's Steam install scripts.
    @Published private(set) var installPrograms: [Int: Int] = [:]
    /// App ID -> the game's One-time installs choice (true: Run at next start).
    @Published private(set) var installRunNext: [Int: Bool] = [:]

    private var watch: Task<Void, Never>?

    func refresh() {
        clientInstalled = MadeiraDock.clientInstalled
        let drive = MadeiraDock.drive, prefix = MadeiraDock.prefix
        Task.detached(priority: .userInitiated) {
            let found = MadeiraDock.games(drive: drive)
            var programs: [Int: Int] = [:], runNext: [Int: Bool] = [:]
            if DockInstallers.choiceEnabled {
                let ledger = DockInstallLedger.load(prefix: prefix)
                for game in found where game.installed {
                    let count = DockInstallers.programCount(game, drive: drive)
                    if count > 0 { programs[game.id] = count; runNext[game.id] = ledger.runsNext(game.id) }
                }
            }
            let counts = programs, choices = runNext
            await MainActor.run { self.games = found; self.installPrograms = counts; self.installRunNext = choices }
        }
    }

    /// The game's One-time installs choice, saved next to the prefix's registry files.
    func setRunsInstallers(_ appID: Int, _ run: Bool) {
        DockInstallers.setRunsNext(appID, run, prefix: MadeiraDock.prefix)
        installRunNext[appID] = run
    }

    /// Downloads and unpacks Valve's client components (no Wine session).
    func prepareClient() {
        guard !preparing else { return }
        preparing = true; error = nil; progress = "Starting…"
        Task { @MainActor in
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { text in
                    await MainActor.run { self.progress = text }
                }
                SteamLog.event("[dock-setup] client components ready")
                // If a USB/Files library was chosen before Steam's client existed,
                // registration was intentionally deferred. Finish it now against the
                // freshly-created Valve libraryfolders.vdf.
                ExternalSteamDrive.shared.restoreAndMountIfAvailable()
            } catch {
                self.error = error.localizedDescription
                SteamLog.event("[dock-setup] client components failed")
            }
            preparing = false
            refresh()
        }
    }

    /// Follows the host's report until it records a result, or the session ends
    /// without one, then removes any unconsumed sign-in transfer.
    func watchReport() {
        watch?.cancel()
        let starting = "SteamIOS Dock is starting. Valve's client signs in and checks the license."
        let plan = DockInstallers.note
        status = plan.map { $0 + "\n" + starting } ?? starting
        if let plan { LogStore.shared.log("[dock-installers] " + plan) }
        watch = Task { @MainActor in
            var idle = 0, started = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let report = MadeiraDock.pollReport()
                // The game's one-time installs run before the host writes its first field.
                if DockInstallers.script != nil {
                    let progress = DockInstallers.poll(drive: MadeiraDock.drive)
                    if report.fields["probe-start-bits"] == nil, report.result == nil, let progress { status = progress }
                }
                if report.result != nil {
                    if let failure = report.failure {
                        status = failure
                        LogStore.shared.log("[madeira-dock] " + failure, level: .error)
                    } else {
                        status = "SteamIOS Dock finished normally."
                        LogStore.shared.log("[madeira-dock] host finished (result 0)")
                    }
                    break
                }
                // Steam still counts another session of this account as playing
                // (launch refusal 35); the host asks again for up to three minutes.
                if report.fields["launch-session-wait"] != nil, report.fields["launch-client-error"] == "35" {
                    status = "Steam says this account is still playing in another session. Waiting for Steam to end it (up to 3 minutes)…"
                }
                // The session starts after the JIT pool is set up; count only once it ran.
                let running = wine_process_is_running() != 0 || wineserver_is_running() != 0
                if running { started = true; idle = 0 } else { idle += 1 }
                if !started && idle >= 150 {
                    status = "The Dock session did not start. See the log."
                    break
                }
                if started && idle >= 5 {
                    status = "SteamIOS Dock stopped before reporting a result. Export the log."
                    LogStore.shared.log("[madeira-dock] session ended without a host result", level: .error)
                    break
                }
            }
            MadeiraDock.cleanup()
            // The host is done with the sign-in: the app's own Steam connection may come
            // back once no session runs (SteamOwnedLibrary).
            SteamOwnedLibrary.shared.dockEnded()
        }
    }
}

/// SteamIOS Dock sheet, opened from the developer interface.
struct MadeiraDockView: View {
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var externalDrive = ExternalSteamDrive.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    let start: (DockGame, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("SteamIOS Dock starts an installed Steam game through Valve's own Steam client, without the Steam desktop window. Valve's client signs in with your account and decides whether the game may run.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Steam account") {
                    if let name = signIn.accountName {
                        LabeledContent("Signed in", value: name)
                    } else {
                        Button("Sign in to Steam") { showSignIn = true }
                    }
                }
                Section {
                    if dock.clientInstalled {
                        Label("Valve's client components are installed", systemImage: "checkmark.circle")
                    } else if dock.preparing {
                        HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                    } else {
                        Button("Download Valve's client components (about 73 MB)") { dock.prepareClient() }
                    }
                } header: { Text("Steam client") } footer: {
                    Text("Downloaded from Valve's update servers and checked against pinned SHA-256 sums. Existing Steam files are kept.")
                }
                Section {
                    Button(externalDrive.configured ? "Change external drive" : "Choose external drive") {
                        externalDrive.presentPicker()
                    }
                    if externalDrive.configured {
                        Label("External library ready on \(externalDrive.displayName)", systemImage: "externaldrive.fill")
                    }
                } header: { Text("External drive") } footer: {
                    Text("Optional. SteamIOS maps the chosen folder into Wine and registers C:\\SteamIOSExternal\\SteamLibrary with Steam. Internal storage remains unchanged.")
                }
                Section {
                    if dock.games.isEmpty {
                        Text("No installed Steam games were found in the internal or connected external Steam libraries.").foregroundStyle(.secondary)
                    }
                    ForEach(dock.games) { game in
                        Button { start(game, dock.compactPool); dismiss() } label: {
                            HStack {
                                Text(game.name)
                                Spacer()
                                if !game.installed { Text("Not fully installed").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(!game.installed || !dock.clientInstalled || !signIn.signedIn)
                    }
                    Toggle("Smaller JIT pool (512 MB) for this launch", isOn: $dock.compactPool)
                } header: { Text("Installed games") } footer: {
                    Text("Games Steam's client has installed in this prefix. Only Steam's default launch option is used.")
                }
                if !dock.installPrograms.isEmpty {
                    Section {
                        ForEach(dock.games.filter { dock.installPrograms[$0.id] != nil }) { game in
                            Picker(game.name, selection: Binding(get: { dock.installRunNext[game.id] ?? true },
                                                                 set: { dock.setRunsInstallers(game.id, $0) })) {
                                Text("Run at next start").tag(true)
                                Text("Skip").tag(false)
                            }
                            .pickerStyle(.menu)
                        }
                    } header: { Text("One-time installs") } footer: {
                        Text("Programs from a game's Steam install script, such as runtime setups, that Steam's desktop client runs before a first start. A Dock start runs the ones not yet recorded as done before Valve's client starts; the choice then changes to Skip.")
                    }
                }
                if let status = dock.status {
                    Section("Dock status") { Text(status) }
                }
                if let error = dock.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("SteamIOS Dock").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { externalDrive.restoreAndMountIfAvailable(); dock.refresh(); signIn.refresh() }
            .sheet(isPresented: $showSignIn) { SteamSignInView() }
        }
    }
}
