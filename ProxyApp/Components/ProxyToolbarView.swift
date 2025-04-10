//
//  ProxyToolbarView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//

import SwiftUI

struct ProxyToolbarView: View {
    @EnvironmentObject private var proxyCore: ProxyCore

    var body: some View {
        HStack {
            // Play button
            Button(action: {
                proxyCore.startDaemon()
            }) {
                Image(systemName: "play.fill")
            }
            .disabled(proxyCore.isRunning)

            // Stop button
            Button(action: {
                proxyCore.stopDaemon()
            }) {
                Image(systemName: "stop.fill")
            }
            .disabled(!proxyCore.isRunning)

            Spacer()

            // Central Capsule
            HStack(spacing: 8) {
                Circle()
                    .fill(proxyCore.isRunning ? .green : .red)
                    .frame(width: 12, height: 12)

                Text("Running on localhost:\("8080")")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.gray.opacity(0.8)))

            Spacer()
        }
        .padding(.horizontal)
    }
}
