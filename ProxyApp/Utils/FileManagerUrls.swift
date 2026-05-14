//
//  FileManagerUrls.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 28/04/25.
//


import Foundation

struct FileManagerUrls {
    static private let executableName = "proxycore"
    static private let runtimeFolder = "PacketPeekRuntime"

    /// Falls back to the home directory if `applicationSupportDirectory` is unavailable
    /// (theoretically impossible on macOS, but safer than crashing).
    private static var applicationSupport: URL {
        if let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first {
            return url
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
    }

    static var executableDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PacketPeek/\(executableName)")
    }

    static var workingDirectory: URL {
        applicationSupport.appendingPathComponent(runtimeFolder)
    }

    static var settingsFileURL: URL {
        workingDirectory.appendingPathComponent("settings.json")
    }

    /// Path to the bearer-token file written by the Go daemon at startup.
    static var apiTokenURL: URL {
        workingDirectory.appendingPathComponent("api.token")
    }

    /// Path to the CA cert file written by the Go daemon (used by SimulatorIntegration).
    static var caCertURL: URL {
        workingDirectory.appendingPathComponent("ca.pem")
    }
}
