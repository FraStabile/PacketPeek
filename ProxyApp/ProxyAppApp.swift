//
//  ProxyAppApp.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
//

import SwiftUI
import SwiftData

@main
struct ProxyAppApp: App {
    @StateObject var proxyCore: ProxyCore = ProxyCore()
    var body: some Scene {
        WindowGroup {
            ContentView(proxyCore: proxyCore)
                .environmentObject(proxyCore)
        }
    }
}
