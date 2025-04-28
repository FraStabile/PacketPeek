//
//  Excatuable.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 18/04/25.
//


import Foundation
import CryptoKit

final class ExecutableInstaller {
    private let executableName = "proxycore"
    
    var execURL: URL {
        FileManagerUrls.executableDirectory
    }
    
    private var workingDirectory: URL {
        FileManagerUrls.workingDirectory
    }
    
    init() {
        installOrUpdateExecutableIfNeeded()
    }
    
    // MARK: - Installazione/Update Binario
    
    private func installOrUpdateExecutableIfNeeded() {
        guard let bundleURL = Bundle.main.resourceURL?.appendingPathComponent(executableName),
              FileManager.default.fileExists(atPath: bundleURL.path) else {
            print("⚠️ Binario non trovato nel bundle.")
            return
        }
        
        let needsUpdate = !FileManager.default.fileExists(atPath: execURL.path) || {
            let installedHash = sha256(of: execURL)
            let bundleHash = sha256(of: bundleURL)
            return installedHash != bundleHash
        }()
        
        guard needsUpdate else {
            print("ℹ️ Binario già aggiornato.")
            return
        }
        
        do {
            try FileManager.default.createDirectory(at: execURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: execURL.path) {
                try FileManager.default.removeItem(at: execURL)
            }
            try FileManager.default.copyItem(at: bundleURL, to: execURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
            print("✅ Binario aggiornato correttamente.")
        } catch {
            print("❌ Errore durante aggiornamento del binario:", error)
        }
    }
    
    // MARK: - Hash
    
    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}

