//
//  ThemeSettings.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//

import SwiftUI
struct ThemeSettings: SettingsItemProtocol {
    var id: UUID = UUID()
    var name: String = "Theme"
    
    var icon: String? = "square.and.arrow.up.on.square"
    
    func content() -> some View {
            VStack {
                Text("General Settings")
                Toggle("Enable feature", isOn: .constant(true))
            }
            .padding()
        }
    
    
}
