//
//  SettingsManager.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//


import Foundation
class SettingsManager: SettingsManagerProtocol {
    var settingModel: SettingsModel?
    private var settingsFileURL: URL {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PacketPeekRuntime")
                .appendingPathComponent("settings.json")
        }
    
    
        init() {
            self.settingModel = loadSettings()
        }
      func saveSettings(_ settings: SettingsModel) {
          do {
              let encoder = JSONEncoder()
              encoder.outputFormatting = .prettyPrinted
              let data = try encoder.encode(settings)
              
              try FileManager.default.createDirectory(at: settingsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
              try data.write(to: settingsFileURL)
              
              settingModel = settings
          } catch {
              print("Errore nel salvataggio delle impostazioni: \(error)")
          }
      }
      
    
    func getCurrentSettings() -> SettingsModel {
        return settingModel ?? getDefaultSettings()
    }
    
      func loadSettings() -> SettingsModel? {
          do {
              let data = try Data(contentsOf: settingsFileURL)
              let decoded = try JSONDecoder().decode(SettingsModel.self, from: data)
              settingModel = decoded
              return decoded
          } catch {
              // Se il file non esiste o c'è stato un errore, crea impostazioni di default
              let defaultSettings = getDefaultSettings()
              saveSettings(defaultSettings)
              return defaultSettings
          }
      }
      
      func getDefaultSettings() -> SettingsModel {
          // Imposta qui i valori predefiniti per le tue impostazioni
          return SettingsModel(general: GeneralSettingsModel(theme: "light", language: "it"))
      }
}
