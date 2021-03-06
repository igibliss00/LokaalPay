//
//  Digest+Extensions.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-14.
//

import Foundation
import CryptoKit

extension Digest {
    var bytes: [UInt8] { Array(makeIterator()) }
    var data: Data { Data(bytes) }
    
    var hexStr: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
