//
//  HomeViewModel.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//
import Foundation
import Combine

import Foundation
import Combine
struct ProxyElementUI: Identifiable {
    let id = UUID()
    var basePath: String
    var url: String
    var methodLabel: String
}
struct ProxyUIModel: Identifiable {
    let id = UUID()
    var ip: String = ""
    var logs: [ProxyElementUI] = []
}


class HomeViewModel: ObservableObject {
    @Published var uniqueIPs: [String] = [] // Lista degli IP unici
    private var uniqueIPSet: Set<String> = [] // Set per gli IP unici
    private var cancellables: Set<AnyCancellable> = []
    @Published var proxyUIModel: [ProxyUIModel] = []
    
    init(proxyCore: ProxyCore) {
        // Ascoltiamo i log e aggiorniamo la lista degli IP
        proxyCore.$logs
            .receive(on: RunLoop.main)
            .sink { [weak self] logs in
                // Elabora ogni log e aggiorna l'interfaccia utente
                guard let log = logs.last else { return }
                self?.updateUniqueIPs(from: log)
            }
            .store(in: &cancellables)
    }
    
    // Funzione per aggiornare gli IP unici man mano che arrivano nuovi log
    private func updateUniqueIPs(from log: ProxyLog) {
        let ip = log.clientIP.components(separatedBy: ":").first ?? ""
        
        // Debug: stampa per verificare se il log viene ricevuto correttamente
        print("Received log from IP: \(ip), URL: \(log.url), Method: \(log.method)")
        
        if !uniqueIPSet.contains(ip) {
            // Nuovo IP, lo aggiungiamo
            uniqueIPSet.insert(ip)
            uniqueIPs.append(ip)
            proxyUIModel.append(ProxyUIModel(ip: ip, logs: [ProxyElementUI(basePath: log.url, url: log.url, methodLabel: log.method)]))
        } else {
            // IP già esistente, aggiorniamo i suoi log
            if let index = proxyUIModel.firstIndex(where: { $0.ip == ip }) {
                // Debug: stampa per verificare quale IP viene aggiornato
                print("Updating logs for existing IP: \(ip)")
                proxyUIModel[index].logs.append(ProxyElementUI(basePath: log.url, url: log.url, methodLabel: log.method))
            }
        }
    }
}
