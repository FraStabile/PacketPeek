//
//  GeneralSettingViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 28/04/25.
//
import Combine
import SwiftDependency
import Foundation
class GeneralSettingViewModel : BaseViewModel{
    @InjectProps private var settingManager: SettingsManagerProtocol
    
    func settingLang(_ selectedLanguage: String) {
        let newSetting = settingManager.getCurrentSettings()
        newSetting.general.language = selectedLanguage
        settingManager.saveSettings(newSetting)
    }
    
    
    @Published var lastCleanupMessage: String?

    /// Files in the runtime directory that must survive a cleanup: user data
    /// (mock rules, monitored apps, settings), the root CA — deleting it would
    /// break every device that trusts it — and the daemon's live API token.
    static let protectedFiles: Set<String> = [
        "mocks.json", "monitored_apps.json", "settings.json",
        "ca.pem", "ca.key", "api.token"
    ]

    /// Whether `name` is a disposable file: a temp file left behind by an
    /// interrupted atomic write (`.mocks-*.tmp`) or a stray log. Allowlist,
    /// so anything new added to the runtime dir is kept by default.
    static func isDisposable(_ name: String) -> Bool {
        guard !protectedFiles.contains(name) else { return false }
        return (name.hasPrefix(".mocks-") && name.hasSuffix(".tmp")) || name.hasSuffix(".log")
    }

    /// Removes leftover temporary files and logs from the runtime directory.
    /// Never touches mocks, monitored apps, settings, the CA or the API token.
    func clearTemporaryFiles() {
        let fileManager = FileManager.default
        let urlDir = FileManagerUrls.workingDirectory
        do {
            // Temp files are dot-files: don't skip hidden files.
            let contents = try fileManager.contentsOfDirectory(at: urlDir, includingPropertiesForKeys: nil)
            var removed = 0
            for fileURL in contents where Self.isDisposable(fileURL.lastPathComponent) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    removed += 1
                } catch {
                    print("⚠️ Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            lastCleanupMessage = removed == 0 ? "Nessun file temporaneo da eliminare." : "Eliminati \(removed) file temporanei."
        } catch {
            lastCleanupMessage = "Impossibile accedere alla cartella runtime: \(error.localizedDescription)"
        }
    }
}
