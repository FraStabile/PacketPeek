//
//  TutorialModalView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import SwiftUI

struct TutorialModalView: View {
    @Environment(\.dismiss) var dismiss
    @State private var currentIndex = 0

    let slides: [TutorialSlide] = {
        let ip = NetworkUtils.getLocalNetworkIPAddress() ?? "192.168.X.X"
        return [
            TutorialSlide(
                title: "1. Imposta il Proxy",
                description: "Vai nelle impostazioni del tuo dispositivo e imposta il proxy con:\n\n• IP: \(ip)\n• Porta: 8080",
                systemImage: "network"
            ),
            TutorialSlide(
                title: "2. Verifica la Connessione",
                description: "Apri il browser e vai su:\n\n\(ip):8081/welcome\n\nSe il proxy è attivo, vedrai una pagina con:\n\n\"Server proxy connesso\"\n\ne due pulsanti per scaricare i certificati.",
                systemImage: "link"
            ),
            TutorialSlide(
                title: "3. Installa i Certificati",
                description: "Scarica il certificato, aprilo e installalo. Poi vai in Impostazioni > Certificati > Rendi attendibile per HTTPs.\n\nFatto! Ora puoi sniffare il traffico HTTPS.",
                systemImage: "checkmark.shield"
            )
        ]
    }()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: slides[currentIndex].systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 60)
                    .padding()
                    .foregroundColor(.accentColor)

                Text(slides[currentIndex].title)
                    .font(.title2)
                    .bold()

                Text(slides[currentIndex].description)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .transition(.slide)

            HStack {
                Button("Indietro") {
                    withAnimation {
                        if currentIndex > 0 {
                            currentIndex -= 1
                        }
                    }
                }
                .disabled(currentIndex == 0)

                Spacer()

                Text("\(currentIndex + 1)/\(slides.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(currentIndex < slides.count - 1 ? "Avanti" : "Fine") {
                    withAnimation {
                        if currentIndex < slides.count - 1 {
                            currentIndex += 1
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct TutorialSlide {
    let title: String
    let description: String
    let systemImage: String
}

