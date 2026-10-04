import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ExternalSteamDrive: NSObject, ObservableObject, UIDocumentPickerDelegate {
    static let shared = ExternalSteamDrive()

    @Published private(set) var isConfigured = false
    @Published private(set) var isMounted = false
    @Published private(set) var displayName: String?
    @Published private(set) var lastError: String?

    private static let bookmarkKey = "SteamIOS.externalSteamLibrary.bookmark.v1"
    private var scopedRoot: URL?
    private var scopedAccessActive = false

    override private init() {
        super.init()
        restoreBookmark()
    }

    deinit {
        releaseSecurityScope()
    }

    func restoreAndMountIfAvailable() {
        restoreBookmark()
        mountCurrentPrefixIfPresent()
    }

    func chooseDirectory() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self

        guard let presenter = Self.topPresenter() else {
            lastError = "Could not present the folder picker."
            return
        }
        presenter.present(picker, animated: true)
    }

    func clearSelection() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        releaseSecurityScope()
        isConfigured = false
        isMounted = false
        displayName = nil
        lastError = nil

        let prefix = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine", isDirectory: true)
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent("dosdevices/e:"))
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent("drive_c/SteamLibraryExternal"))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        selectDirectory(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            isConfigured = false
            isMounted = false
            displayName = nil
            return
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            guard beginSecurityScope(url) else {
                isConfigured = true
                isMounted = false
                displayName = url.lastPathComponent
                lastError = "External drive is not currently available."
                return
            }

            isConfigured = true
            displayName = url.lastPathComponent
            isMounted = prepareExternalLibrary() != nil
            lastError = nil

            if stale {
                try persistBookmark(for: url)
            }
        } catch {
            isConfigured = false
            isMounted = false
            lastError = "Saved external-drive access could not be restored."
        }
    }

    private func selectDirectory(_ url: URL) {
        guard beginSecurityScope(url) else {
            isConfigured = true
            isMounted = false
            displayName = url.lastPathComponent
            lastError = "SteamIOS could not obtain write access to that folder."
            return
        }

        do {
            try persistBookmark(for: url)
            isConfigured = true
            displayName = url.lastPathComponent

            guard prepareExternalLibrary() != nil else {
                isMounted = false
                return
            }

            isMounted = true
            lastError = nil
            mountCurrentPrefixIfPresent()
        } catch {
            isMounted = false
            lastError = "SteamIOS could not save external-drive access."
        }
    }

    private func persistBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func beginSecurityScope(_ url: URL) -> Bool {
        if scopedAccessActive, scopedRoot == url {
            return true
        }

        releaseSecurityScope()

        guard url.startAccessingSecurityScopedResource() else {
            scopedRoot = nil
            scopedAccessActive = false
            return false
        }

        scopedRoot = url
        scopedAccessActive = true
        return true
    }

    private func releaseSecurityScope() {
        if scopedAccessActive {
            scopedRoot?.stopAccessingSecurityScopedResource()
        }
        scopedRoot = nil
        scopedAccessActive = false
    }

    private func externalLibraryURL(for root: URL) -> URL {
        if root.lastPathComponent.caseInsensitiveCompare("SteamLibrary") == .orderedSame {
            return root
        }
        return root.appendingPathComponent("SteamLibrary", isDirectory: true)
    }

    @discardableResult
    private func prepareExternalLibrary() -> URL? {
        guard let root = scopedRoot, scopedAccessActive else {
            isMounted = false
            return nil
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var prepared: URL?

        coordinator.coordinate(writingItemAt: root, options: [], error: &coordinationError) { coordinatedRoot in
            do {
                let fm = FileManager.default
                let library = externalLibraryURL(for: coordinatedRoot)
                let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)

                try fm.createDirectory(
                    at: steamapps.appendingPathComponent("common", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try fm.createDirectory(
                    at: steamapps.appendingPathComponent("downloading", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try fm.createDirectory(
                    at: steamapps.appendingPathComponent("workshop", isDirectory: true),
                    withIntermediateDirectories: true
                )

                let marker = library.appendingPathComponent(".steamios-external-library")
                if !fm.fileExists(atPath: marker.path) {
                    try Data("SteamIOS external Steam library\n".utf8).write(to: marker, options: .atomic)
                }

                prepared = library
            } catch {
                operationError = error
            }
        }

        if let error = operationError {
            isMounted = false
            lastError = "External drive is not writable: \(error.localizedDescription)"
            return nil
        }
        if let error = coordinationError {
            isMounted = false
            lastError = "External drive access failed: \(error.localizedDescription)"
            return nil
        }

        return prepared
    }

    @discardableResult
    func mountIfConfigured(prefixURL: URL, steamDirectory: URL, steamWindowsPath: String) -> Bool {
        guard isConfigured else { return false }

        if !scopedAccessActive {
            restoreBookmark()
        }

        guard let library = prepareExternalLibrary() else {
            return false
        }

        do {
            let fm = FileManager.default
            let dosDevices = prefixURL.appendingPathComponent("dosdevices", isDirectory: true)
            try fm.createDirectory(at: dosDevices, withIntermediateDirectories: true)

            let driveLink = dosDevices.appendingPathComponent("e:")
            try? fm.removeItem(at: driveLink)
            try fm.createSymbolicLink(at: driveLink, withDestinationURL: library)

            let fallbackLink = prefixURL
                .appendingPathComponent("drive_c", isDirectory: true)
                .appendingPathComponent("SteamLibraryExternal")
            try? fm.removeItem(at: fallbackLink)
            try fm.createSymbolicLink(at: fallbackLink, withDestinationURL: library)

            try updateLibraryFolders(steamDirectory: steamDirectory, internalWindowsPath: steamWindowsPath)

            isMounted = true
            lastError = nil
            LogStore.shared.log("[storage] External Steam library mounted as E:\\", level: .success)
            return true
        } catch {
            isMounted = false
            lastError = "External Steam library could not be mounted: \(error.localizedDescription)"
            LogStore.shared.log("[storage] External library mount failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    private func updateLibraryFolders(steamDirectory: URL, internalWindowsPath: String) throws {
        let fm = FileManager.default
        let steamapps = steamDirectory.appendingPathComponent("steamapps", isDirectory: true)
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)

        let vdf = steamapps.appendingPathComponent("libraryfolders.vdf")
        let externalVDFPath = Self.escapeVDF("E:\\")

        var text: String
        if let existing = try? String(contentsOf: vdf, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = existing
        } else {
            let internalVDFPath = Self.escapeVDF(internalWindowsPath)
            text = """
            "libraryfolders"
            {
                "0"
                {
                    "path"        "\(internalVDFPath)"
                    "label"       ""
                    "contentid"   "0"
                    "totalsize"   "0"
                    "update_clean_bytes_tally" "0"
                    "time_last_update_verified" "0"
                    "apps"
                    {
                    }
                }
            }
            """
        }

        if text.localizedCaseInsensitiveContains(externalVDFPath) {
            return
        }

        var slot = 9000
        while text.contains("\"\(slot)\"") && slot < 9999 {
            slot += 1
        }

        let entry = """
                "\(slot)"
                {
                    "path"        "\(externalVDFPath)"
                    "label"       "USB / External"
                    "contentid"   "0"
                    "totalsize"   "0"
                    "update_clean_bytes_tally" "0"
                    "time_last_update_verified" "0"
                    "apps"
                    {
                    }
                }
        """

        guard let closing = text.lastIndex(of: "}") else {
            throw NSError(
                domain: "SteamIOS.ExternalStorage",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Steam libraryfolders.vdf is malformed"]
            )
        }

        text.insert(contentsOf: "\n\(entry)\n", at: closing)
        try text.write(to: vdf, atomically: true, encoding: .utf8)
    }

    private static func escapeVDF(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func mountCurrentPrefixIfPresent() {
        let fm = FileManager.default
        let prefix = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine", isDirectory: true)

        let candidates: [(String, URL)] = [
            ("C:\\Program Files (x86)\\Steam",
             prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)),
            ("C:\\Program Files\\Steam",
             prefix.appendingPathComponent("drive_c/Program Files/Steam", isDirectory: true)),
            ("C:\\Steam",
             prefix.appendingPathComponent("drive_c/Steam", isDirectory: true)),
        ]

        guard let (windowsPath, steamDirectory) = candidates.first(where: {
            fm.fileExists(atPath: $0.1.appendingPathComponent("steam.exe").path)
        }) else { return }

        _ = mountIfConfigured(prefixURL: prefix, steamDirectory: steamDirectory, steamWindowsPath: windowsPath)
    }

    private static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first(where: { !$0.isHidden })?.rootViewController

        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
