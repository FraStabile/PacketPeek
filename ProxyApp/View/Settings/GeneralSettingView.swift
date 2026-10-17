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
    @State private var notificationsEnabled = true
    @State private var launchAtLogin = false
    @State private var confirmCleanup = false
    @InjectProps private var settingManager: SettingsManagerProtocol
    @StateObject private var viewModel = GeneralSettingViewModel()
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
                    viewModel.settingLang(selectedLanguage)
                }
            }
            
            settingRow(title: "File temporanei") {
                Button("Elimina file temporanei…", role: .destructive) {
                    confirmCleanup = true
                }
                .confirmationDialog(
                    "Eliminare i file temporanei?",
                    isPresented: $confirmCleanup,
                    titleVisibility: .visible
                ) {
                    Button("Elimina", role: .destructive) {
                        viewModel.clearTemporaryFiles()
                    }
                    Button("Annulla", role: .cancel) {}
                } message: {
                    Text("Rimuove file temporanei e log rimasti nella cartella runtime. Mock, app monitorate, impostazioni e certificato CA non vengono toccati.")
                }
            }
            if let message = viewModel.lastCleanupMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            
            
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
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

