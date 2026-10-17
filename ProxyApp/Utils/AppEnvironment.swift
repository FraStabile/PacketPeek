//
//  AppEnvironment.swift
//  ProxyApp
//
//  With TEST_HOST the real app launches for every test run. Startup side
//  effects (daemon, system proxy, executable install) must be skipped there,
//  or running tests would change the proxy settings of the machine.
//

import Foundation

enum AppEnvironment {
    static func isRunningTests(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
