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
    
    
    func clearRuntimeCache() {
        let fileManager = FileManager.default
        let urlDir = FileManagerUrls.workingDirectory

        do {
            let contents = try fileManager.contentsOfDirectory(at: urlDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            
            for fileURL in contents {
                if fileURL.pathExtension.lowercased() == "json" {
                    do {
                        try fileManager.removeItem(at: fileURL)
                        print("✅ Deleted JSON file: \(fileURL.lastPathComponent)")
                    } catch {
                        print("⚠️ Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("❌ Failed to access runtime cache directory: \(error.localizedDescription)")
        }
    }

}
