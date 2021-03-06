//
//  Array+Extensions.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-07.
//

import Foundation
import web3swift

extension Array where Element == Data {
    var compressed: Data? {
        let encoder = JSONEncoder()
        if let jsonData = try? encoder.encode(self) {
            guard let compressed = try? (jsonData as NSData).compressed(using: .lzfse) else {
                return nil
            }
            
            let data = Data(referencing: compressed)
            return data
        } else {
            return nil
        }
    }
}

extension Dictionary where Key == String, Value == Data {
    var compressed: Data? {
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(self),
              let compressed = try? (jsonData as NSData).compressed(using: .lzfse) else {
            return nil
        }
        
        let data = Data(compressed)
        return data
    }
}

public extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter{ seen.insert($0).inserted }
    }
}
