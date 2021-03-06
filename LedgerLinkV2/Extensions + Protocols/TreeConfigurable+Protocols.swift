//
//  TreeConfigurable+Protocols.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-11.
//

import Foundation
import Compression

/**
 TreeConfigurable is for a binary tree to be able to sort the nodes
 Codable because the Merkle tree needs to encode in order to convert a type to Data.
 Hashable because the Merkle tree needs to hash the converted data.
 Comparable because the Red Black tree needs to sort.
 */
protocol LightConfigurable: Codable, Hashable, Comparable, CoreDatable, PropertyLoopable {
    associatedtype T
    var id: String { get set }
    var data: Data { get set }
    init(data: T) throws
    func decode() -> T?
}

extension LightConfigurable {
    func compress(_ sourceData: Data, algorithm: Algorithm = .lzfse) -> Data {
        let pageSize = 128
        var compressedData = Data()
        
        do {
            let outputFilter = try OutputFilter(.compress, using: algorithm) { (data: Data?) -> Void in
                if let data = data {
                    compressedData.append(data)
                }
            }
            
            var index = 0
            let bufferSize = sourceData.count
            
            while true {
                let rangeLength = min(pageSize, bufferSize - index)
                
                let subdata = sourceData.subdata(in: index ..< index + rangeLength)
                index += rangeLength
                
                try outputFilter.write(subdata)
                
                if (rangeLength == 0) {
                    break
                }
            }
        }catch {
            fatalError("Error occurred during encoding: \(error.localizedDescription).")
        }
        
        return compressedData
    }
}

// MARK: - PropertyLoopable

protocol PropertyLoopable {
    func allProperties() throws -> [String: Any]
}

extension PropertyLoopable {
    func allProperties() throws -> [String: Any] {
        var result: [String: Any] = [:]
        let mirror = Mirror(reflecting: self)
        for (labelMaybe, valueMaybe) in mirror.children {
            guard let label = labelMaybe else {
                continue
            }
            
            result[label] = valueMaybe
        }
        
        return result
    }
}
