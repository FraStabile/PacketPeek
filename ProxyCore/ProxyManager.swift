import Foundation

class ProxyManager {
    static let shared = ProxyManager()
    private let proxyPort = 8080
    private let launchAgentLabel = "com.proxyapp.proxycore"
    private let launchAgentPath = "~/Library/LaunchAgents/com.proxyapp.proxycore.plist"
    
    private init() {}
    
    func startProxy() {
        if !isProxyRunning() {
            do {
                try runCommand("launchctl", args: ["load", launchAgentPath.expandingTildeInPath])
                // Wait a bit for the proxy to start
                Thread.sleep(forTimeInterval: 1.0)
            } catch {
                print("Error starting proxy: \(error)")
            }
        }
    }
    
    func stopProxy() {
        do {
            try runCommand("launchctl", args: ["unload", launchAgentPath.expandingTildeInPath])
        } catch {
            print("Error stopping proxy: \(error)")
        }
    }
    
    func isProxyRunning() -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        if socket < 0 {
            return false
        }
        defer {
            close(socket)
        }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let result = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return result == 0
    }
    
    private func runCommand(_ command: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(command)")
        process.arguments = args
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw NSError(domain: "ProxyManager",
                         code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "Command failed"])
        }
    }
}

extension String {
    var expandingTildeInPath: String {
        return (self as NSString).expandingTildeInPath
    }
}
