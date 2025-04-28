//
//  FileManagerUrls.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 28/04/25.
//


import Foundation
struct FileManagerUrls {
    static private let executableName = "proxycore"
    static var executableDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PacketPeek/\(executableName)")
    }
    
    static var workingDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PacketPeekRuntime")
    }
    
    static var settingsFileURL: URL {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PacketPeekRuntime")
                .appendingPathComponent("settings.json")
        }
}
