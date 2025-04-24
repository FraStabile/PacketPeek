//
//  GeneralSettingView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//

import SwiftUI
import SwiftDependency
struct GeneralSettingView: View {
    @State private var selectedLanguage = "en"
    @State private var darkMode = false
    @State private var notificationsEnabled = true
    @State private var launchAtLogin = false
    @InjectProps private var settingManager: SettingsManagerProtocol
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Impostazioni Generali")
                .font(.title2.bold())
                .padding(.bottom, 12)

            // Lingua
            settingRow(title: "Lingua") {
                Picker("", selection: $selectedLanguage) {
                    Text("Inglese").tag("en")
                    Text("Italiano").tag("it")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
                .onChange(of: selectedLanguage) {
                    print(selectedLanguage)
                    let newSetting = settingManager.getCurrentSettings()
                    newSetting.general.language = selectedLanguage
                    settingManager.saveSettings(newSetting)
                }
            }

            // Tema
            settingRow(title: "Tema scuro") {
                Toggle("", isOn: $darkMode)
                    .toggleStyle(.switch)
            }
            .onChange(of: darkMode) {
                let newSettings = settingManager.getCurrentSettings()
                let theme: String = darkMode ? "dark" : "light"
                newSettings.general.theme = theme
                settingManager.saveSettings(newSettings)
            }
            
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            darkMode = settingManager.getCurrentSettings().general.theme == "dark"
            selectedLanguage = settingManager.getCurrentSettings().general.language
        }
    }

    @ViewBuilder
    private func settingRow<T: View>(title: String, @ViewBuilder content: () -> T) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }
}

#Preview {
    GeneralSettingView()
}

