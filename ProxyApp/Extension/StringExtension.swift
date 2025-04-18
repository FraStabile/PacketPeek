//
//  StringExtension.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 16/04/25.
//


import Foundation
extension String {
    var host : String {
        let urlComponents = URLComponents(string: self)
        return urlComponents?.host ?? ""
    }
    
    var port: Int? {
        let urlComponents = URLComponents(string: self)
        return urlComponents?.port
    }
    
    var path : String {
        let urlComponents = URLComponents(string: self)
        return urlComponents?.path ?? ""
    }
    
    
    func trim() -> String {
           return self.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
     }
}
