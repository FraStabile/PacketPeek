//
//  NetworkUtils.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 14/04/25.
//

import Foundation
import SystemConfiguration

class NetworkUtils {
    static func getLocalNetworkIPAddress() -> String? {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET),
               let name = String(cString: interface.ifa_name, encoding: .utf8),
               name != "lo0" {

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, socklen_t(0), NI_NUMERICHOST)

                address = String(cString: hostname)
                break
            }
        }

        freeifaddrs(ifaddr)
        return address
    }
}

