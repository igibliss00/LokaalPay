//
//  CoreDataServices+Generic.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-23.
//

import Foundation
import CoreData
import web3swift
import BigInt

// MARK: - Generics

@available(iOS 15.0.0, *)
extension LocalStorage {
    /// Save individual LightConfigurable element
    func save<T: LightConfigurable>(_ element: T, completion: @escaping (NodeError?) -> Void) async {
        switch element {
            case is TreeConfigurableAccount:
                guard let entity = NSEntityDescription.insertNewObject(forEntityName: EntityName.stateCoreData.rawValue, into: self.context) as? StateCoreData else { return }
                entity.id = element.id
                entity.data = element.data
                break
            case is TreeConfigurableTransaction:
                guard let entity = NSEntityDescription.insertNewObject(forEntityName: EntityName.transactionCoreData.rawValue, into: self.context) as? TransactionCoreData else { return }
                entity.id = element.id
                entity.data = element.data
                break
            case is TreeConfigurableReceipt:
                guard let entity = NSEntityDescription.insertNewObject(forEntityName: EntityName.receiptCoreData.rawValue, into: self.context) as? ReceiptCoreData else { return }
                entity.id = element.id
                entity.data = element.data
                break
            case is LightBlock:
                guard let lightBlock = element as? LightBlock else { return }
                guard let entity = NSEntityDescription.insertNewObject(forEntityName: EntityName.blockCoreData.rawValue, into: self.context) as? BlockCoreData else { return }
                entity.id = lightBlock.id
                let number = Int32(lightBlock.number)
                entity.number = number
                entity.data = lightBlock.data
            default:
                return
        }
        
        let taskContext = newTaskContext()
        // Add name and author to identify source of persistent history changes.
        taskContext.name = "save"
        taskContext.transactionAuthor = "Saver"
        
        /// delete request for already existing items
        let request: NSFetchRequest<StateCoreData> = StateCoreData.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", element.id)
        
        /// - Tag: perform
        await taskContext.perform {
            
            do {
                /// deletion
                let results = try taskContext.fetch(request)
                for result in results {
                    taskContext.delete(result)
                }
                
                /// Delete if a duplicate exists and update a new one
                try taskContext.save()
                completion(nil)
            } catch {
                completion(NodeError.generalError("Block save error"))
            }
        }
    }
    
    /// Save individual full fledged element
    func save<T>(_ element: T, completion: @escaping (NodeError?) -> Void) async {
        if let account = element as? Account {
            do {
                let treeConfigAccount = try TreeConfigurableAccount(data:account)
                await save(treeConfigAccount, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare state to save"))
            }
        } else if let transaction = element as? EthereumTransaction {
            do {
                let treeConfigTransaction = try TreeConfigurableTransaction(data: transaction)
                await save(treeConfigTransaction, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare transaction to save"))
            }
        } else if let receipt = element as? TransactionReceipt {
            do {
                let treeConfigReceipt = try TreeConfigurableReceipt(data: receipt)
                await save(treeConfigReceipt, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare receipt to save"))
            }
        } else if let block = element as? FullBlock {
            do {
                let lightBlock = try LightBlock(data: block)
                await save(lightBlock, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare block to save"))
            }
        } else {
            completion(NodeError.generalError("Wrong type"))
        }
    }
    
    /// Save an array of LightConfigurable elements
    func save<T: LightConfigurable>( _ elements: [T], completion: @escaping (NodeError?) -> Void) async {
        let taskContext = newTaskContext()
        // Add name and author to identify source of persistent history changes.
        taskContext.name = "saveTransactionContext"
        taskContext.transactionAuthor = "transactionSaver"
        
        do {
            /// - Tag: perform
            try await taskContext.perform {
                // Execute the batch insert.
                /// - Tag: batchInsertRequest
                guard let batchInsertRequest = self.newBatchInsertRequest(with: elements) else {
                    completion(NodeError.generalError("Unable to create a request"))
                    return
                }
                if let fetchResult = try? taskContext.execute(batchInsertRequest),
                   let batchInsertResult = fetchResult as? NSBatchInsertResult,
                   let success = batchInsertResult.result as? Bool, success {
                    return
                }
                print("Failed to execute batch insert request.")
                throw NodeError.generalError("Batch insert error")
            }
            
            print("Successfully inserted data.")
            completion(nil)
        } catch {
            completion(NodeError.generalError("Unable to save"))
        }
    }
    
    func saveSync<T>( _ elements: [T], completion: @escaping (NodeError?) -> Void) {
        if let accounts = elements as? [Account] {
            do {
                let treeConfigAccounts = try accounts.map { try TreeConfigurableAccount(data: $0) }
                saveSync(treeConfigAccounts, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare state to save"))
            }
        } else if let treeConfigAccounts = elements as? [TreeConfigurableAccount] {
            saveSync(treeConfigAccounts, completion: completion)
        } else if let transactions = elements as? [EthereumTransaction] {
            do {
                let treeConfigTxs = try transactions.map { try TreeConfigurableTransaction(data: $0) }
                saveSync(treeConfigTxs, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare transaction to save"))
            }
        } else if let treeConfigTxs = elements as? [TreeConfigurableTransaction] {
            saveSync(treeConfigTxs, completion: completion)
        } else if let receipts = elements as? [TransactionReceipt] {
            do {
                let treeConfigReceipts = try receipts.map { try TreeConfigurableReceipt(data: $0) }
                saveSync(treeConfigReceipts, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare receipt to save"))
            }
        } else if let blocks = elements as? [FullBlock] {
            do {
                let lightBlocks = try blocks.map { try LightBlock(data: $0) }
                saveSync(lightBlocks, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare block to save"))
            }
        } else if let blocks = elements as? [LightBlock] {
            saveSync(blocks, completion: completion)
        } else {
            completion(NodeError.generalError("Wrong type"))
        }
    }
    
    /// Save an array of LightConfigurables synchronously
    func saveSync<T: LightConfigurable>( _ elements: [T], completion: @escaping (NodeError?) -> Void) {
        guard elements.count > 0 else { return }

        if let accounts = elements as? [TreeConfigurableAccount] {
            accounts.forEach{ delete($0) }
        }

        let taskContext = newTaskContext()
        // Add name and author to identify source of persistent history changes.
        taskContext.name = "saveTransactionContext"
        taskContext.transactionAuthor = "transactionSaver"

        do {
            /// - Tag: performAndWait
            try taskContext.performAndWait {
                // Execute the batch insert.
                /// - Tag: batchInsertRequest
                guard let batchInsertRequest = self.newBatchInsertRequest(with: elements) else {
                    completion(NodeError.generalError("Unable to create a request"))
                    return
                }
                if let fetchResult = try? taskContext.execute(batchInsertRequest),
                   let batchInsertResult = fetchResult as? NSBatchInsertResult,
                   let success = batchInsertResult.result as? Bool, success {
                    return
                }
                throw NodeError.generalError("Batch insert error")
            }

            print("Successfully inserted data.")
            completion(nil)
        } catch {
            completion(NodeError.generalError("Unable to save"))
        }
    }
    
    /// Save an array of full fledged elements
    func save<T>(_ elements: [T], completion: @escaping (NodeError?) -> Void) async {
        if let accounts = elements as? [Account] {
            do {
                let results = try accounts.compactMap { try TreeConfigurableAccount(data: $0) }
                await save(results, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare state to save"))
            }
        } else if let transactions = elements as? [EthereumTransaction] {
            do {
                let results = try transactions.compactMap { try TreeConfigurableTransaction(data: $0) }
                await save(results, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare transaction to save"))
            }
        } else if let receipts = elements as? [TransactionReceipt] {
            do {
                let results = try receipts.compactMap { try TreeConfigurableReceipt(data: $0) }
                await save(results, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare receipt to save"))
            }
        } else if let blocks = elements as? [FullBlock] {
            do {
                let results = try blocks.compactMap { try LightBlock(data: $0) }
                await save(results, completion: completion)
            } catch {
                completion(NodeError.generalError("Unable to prepare receipt to save"))
            }
        } else {
            completion(NodeError.generalError("Wrong type"))
        }
    }
 
    /// All elements are searchable
//    func fetch<T: LightConfigurable>(_ predicateString: String? = nil, format: String = "id == %@", completion: @escaping ([T]?, NodeError?) -> Void) {
//        switch T.self {
//            case is Account.Type:
//                let fetchRequest = NSFetchRequest<StateCoreData>(entityName: EntityName.stateCoreData.rawValue)
//                if predicateString != nil {
//                    fatalError()
////                    fetchRequest.predicate = NSPredicate(format: "address == %@", EthereumAddress(predicateString) as! CVarArg)
//                }
//
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<StateCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let accounts: [Account] = results.compactMap { (element: StateCoreData) in
//                        guard let data = element.data else { return nil }
//                        do {
//                            return try Account(data)
//                        } catch {
//                            return nil
//                        }
//                    }
//
//                    completion(accounts as? [T], nil)
//                }
//
//                do {
//                    /// Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is EthereumTransaction.Type:
//                let fetchRequest = NSFetchRequest<TransactionCoreData>(entityName: EntityName.transactionCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: "hash == %@", Data(hex: predicateString) as CVarArg)
//                }
//                /// Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<TransactionCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let transactions: [EthereumTransaction] = results.compactMap { (element: TransactionCoreData) in
//                        guard let data = element.data,
//                              let decompressed = data.decompressed,
//                              let decoded = EthereumTransaction.fromRaw(decompressed) else { return nil }
//
//                        return decoded
//                    }
//
//                    completion(transactions as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is TransactionReceipt.Type:
//                let fetchRequest = NSFetchRequest<ReceiptCoreData>(entityName: EntityName.receiptCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: format, predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<ReceiptCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let receipts: [TransactionReceipt] = results.compactMap { (element: ReceiptCoreData) in
//                        guard let data = element.data,
//                              let decompressed = data.decompressed,
//                              let decoded = try? TransactionReceipt.fromRaw(decompressed) else { return nil }
//
//                        return decoded
//                    }
//
//                    completion(receipts as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is FullBlock.Type:
//                let fetchRequest = NSFetchRequest<BlockCoreData>(entityName: EntityName.blockCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: "hash == %@", predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<BlockCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let fullBlocks: [FullBlock] = results.compactMap { (element: BlockCoreData) in
//                        guard let data = element.data else { return nil }
//
//                        do {
//                            guard let decompressed = data.decompressed else {
//                                throw NodeError.compressionError
//                            }
//
//                            let decoded = try JSONDecoder().decode(FullBlock.self, from: decompressed)
//                            return decoded
//                        } catch {
//                            return nil
//                        }
//                    }
//
//                    completion(fullBlocks as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is TreeConfigurableAccount.Type:
//                let fetchRequest = NSFetchRequest<StateCoreData>(entityName: EntityName.stateCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: format, predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<StateCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let accounts: [TreeConfigurableAccount] = results.compactMap { (element: StateCoreData) in
//                        guard let id = element.id,
//                              let data = element.data else { return nil }
//                        return TreeConfigurableAccount(id: id, data: data)
//                    }
//
//                    completion(accounts as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is TreeConfigurableTransaction.Type:
//                let fetchRequest = NSFetchRequest<TransactionCoreData>(entityName: EntityName.transactionCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: format, predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<TransactionCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let treeConfigTxs: [TreeConfigurableTransaction] = results.compactMap { (element: TransactionCoreData) in
//                        guard let id = element.id,
//                              let data = element.data else { return nil }
//
//                        return TreeConfigurableTransaction(id: id, data: data)
//                    }
//
//                    completion(treeConfigTxs as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is TreeConfigurableReceipt.Type:
//                let fetchRequest = NSFetchRequest<ReceiptCoreData>(entityName: EntityName.receiptCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: format, predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<ReceiptCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let treeConfigReceipts: [TreeConfigurableReceipt] = results.compactMap { (element: ReceiptCoreData) in
//                        guard let id = element.id,
//                              let data = element.data else { return nil }
//
//                        return TreeConfigurableReceipt(id: id, data: data)
//                    }
//
//                    completion(treeConfigReceipts as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            case is LightBlock.Type:
//                let fetchRequest = NSFetchRequest<BlockCoreData>(entityName: EntityName.blockCoreData.rawValue)
//                if let predicateString = predicateString {
//                    fetchRequest.predicate = NSPredicate(format: format, predicateString)
//                }
//                // Initialize Asynchronous Fetch Request
//                let asynchronousFetchRequest = NSAsynchronousFetchRequest<BlockCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
//                    guard let results = asynchronousFetchResult.finalResult else { return }
//                    let lightBlocks: [LightBlock] = results.compactMap { (element: BlockCoreData) in
//                        guard let id = element.id,
//                              let data = element.data else { return nil }
//                        let number = element.number
//                        return LightBlock(id: id, number: number, data: data)
//                    }
//
//                    completion(lightBlocks as? [T], nil)
//                }
//
//                do {
//                    // Execute Asynchronous Fetch Request
//                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
//                } catch {
//                    let fetchError = error as NSError
//                    print("\(fetchError), \(fetchError.userInfo)")
//                    completion(nil, NodeError.generalError("Unable to fetch data"))
//                }
//                break
//            default:
//                break
//        }
//    }
    
    /// All elements are searchable
    func fetch<T: CoreDatable>(_ predicate: FetchPredicate? = nil, format: String = "id == %@", completion: @escaping ([T]?, NodeError?) -> Void) {
        switch T.self {
            case is Account.Type:
                let fetchRequest = NSFetchRequest<StateCoreData>(entityName: EntityName.stateCoreData.rawValue)
                if case .addressString(let addressString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, addressString)
                } else if case .address(let address) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, address.address)
                }

                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<StateCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let accounts: [Account] = results.compactMap { (element: StateCoreData) in
                        guard let data = element.data else { return nil }
                        do {
                            return try Account(data)
                        } catch {
                            return nil
                        }
                    }

                    completion(accounts as? [T], nil)
                }

                do {
                    /// Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is EthereumTransaction.Type:
                let fetchRequest = NSFetchRequest<TransactionCoreData>(entityName: EntityName.transactionCoreData.rawValue)
                if case .transactionRLP(let data) = predicate {
                    guard let compressed = data.compressed else {
                        completion(nil, NodeError.generalError("Predicate preparation error"))
                        return
                    }
                    
                    let id = compressed.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, id)
                } else if case .transaction(let tx) = predicate {
                    guard let rlpEncoded = tx.encode(),
                          let compressed = rlpEncoded.compressed else {
                              completion(nil, NodeError.generalError("Predicate preparation error"))
                              return
                          }
                    let id = compressed.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, id)
                } else if case .treeConfigTxId(let id) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, id)
                }
                
                /// Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<TransactionCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let transactions: [EthereumTransaction] = results.compactMap { (element: TransactionCoreData) in
                        guard let data = element.data,
                              let decompressed = data.decompressed,
                              let decoded = EthereumTransaction.fromRaw(decompressed) else { return nil }

                        return decoded
                    }

                    completion(transactions as? [T], nil)
                }

                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is TransactionReceipt.Type:
                let fetchRequest = NSFetchRequest<ReceiptCoreData>(entityName: EntityName.receiptCoreData.rawValue)
                if case .receiptRLP(let data) = predicate {
                    guard let compressed = data.compressed else {
                        completion(nil, NodeError.generalError("Unable to prepare the predicate"))
                        return
                    }
                    
                    let id = compressed.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, id)
                } else if case .receipt(let receipt) = predicate {
                    guard let rlpEncoded = receipt.encode(),
                          let compressed = rlpEncoded.compressed else {
                              completion(nil, NodeError.generalError("Unable to prepare the predicate"))
                        return
                    }
                    
                    let id = compressed.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, id)
                } else if case .treeConfigReceiptId(let id) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, id)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<ReceiptCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let receipts: [TransactionReceipt] = results.compactMap { (element: ReceiptCoreData) in
                        guard let data = element.data,
                              let decompressed = data.decompressed,
                              let decoded = try? TransactionReceipt.fromRaw(decompressed) else { return nil }

                        return decoded
                    }

                    completion(receipts as? [T], nil)
                }

                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is FullBlock.Type:
                let fetchRequest = NSFetchRequest<BlockCoreData>(entityName: EntityName.blockCoreData.rawValue)
                if case .fullBlockHash(let data) = predicate {
                    let hashString = data.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: "hash == %@", hashString)
                } else if case .lightBlockId(let id) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, id)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<BlockCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let fullBlocks: [FullBlock] = results.compactMap { (element: BlockCoreData) in
                        guard let data = element.data else { return nil }

                        do {
                            guard let decompressed = data.decompressed else {
                                throw NodeError.compressionError
                            }

                            let decoded = try JSONDecoder().decode(FullBlock.self, from: decompressed)
                            return decoded
                        } catch {
                            return nil
                        }
                    }

                    completion(fullBlocks as? [T], nil)
                }

                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is TreeConfigurableAccount.Type:
                let fetchRequest = NSFetchRequest<StateCoreData>(entityName: EntityName.stateCoreData.rawValue)
                if case .treeConfigAccountId(let addressString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, addressString)
                } else if case .addressString(let addressString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, addressString)
                } else if case .address(let address) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, address.address)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<StateCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let accounts: [TreeConfigurableAccount] = results.compactMap { (element: StateCoreData) in
                        guard let id = element.id,
                              let data = element.data else { return nil }
                        return TreeConfigurableAccount(id: id, data: data)
                    }
                    
                    completion(accounts as? [T], nil)
                }
                
                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is TreeConfigurableTransaction.Type:
                let fetchRequest = NSFetchRequest<TransactionCoreData>(entityName: EntityName.transactionCoreData.rawValue)
                if case .treeConfigTxId(let idString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, idString)
                } else if case .transactionRLP(let data) = predicate {
                    guard let compressed = data.compressed else {
                        completion(nil, NodeError.generalError("Unable to prepare the predicate"))
                        return
                    }
                    
                    let id = compressed.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, id)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<TransactionCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let treeConfigTxs: [TreeConfigurableTransaction] = results.compactMap { (element: TransactionCoreData) in
                        guard let id = element.id,
                              let data = element.data else { return nil }
                        
                        return TreeConfigurableTransaction(id: id, data: data)
                    }
                    
                    completion(treeConfigTxs as? [T], nil)
                }
                
                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is TreeConfigurableReceipt.Type:
                let fetchRequest = NSFetchRequest<ReceiptCoreData>(entityName: EntityName.receiptCoreData.rawValue)
                if case .treeConfigReceiptId(let idString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, idString)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<ReceiptCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let treeConfigReceipts: [TreeConfigurableReceipt] = results.compactMap { (element: ReceiptCoreData) in
                        guard let id = element.id,
                              let data = element.data else { return nil }
                        
                        return TreeConfigurableReceipt(id: id, data: data)
                    }
                    
                    completion(treeConfigReceipts as? [T], nil)
                }
                
                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            case is LightBlock.Type:
                let fetchRequest = NSFetchRequest<BlockCoreData>(entityName: EntityName.blockCoreData.rawValue)
                if case .lightBlockId(let idString) = predicate {
                    fetchRequest.predicate = NSPredicate(format: format, idString)
                } else if case .fullBlockHash(let hashData) = predicate {
                    let idString = hashData.sha256().toHexString()
                    fetchRequest.predicate = NSPredicate(format: format, idString)
                }
                
                // Initialize Asynchronous Fetch Request
                let asynchronousFetchRequest = NSAsynchronousFetchRequest<BlockCoreData>(fetchRequest: fetchRequest) { (asynchronousFetchResult) -> Void in
                    guard let results = asynchronousFetchResult.finalResult else { return }
                    let lightBlocks: [LightBlock] = results.compactMap { (element: BlockCoreData) in
                        guard let id = element.id,
                              let data = element.data else { return nil }
                        let number = element.number
                        return LightBlock(id: id, number: number, data: data)
                    }
                    
                    completion(lightBlocks as? [T], nil)
                }
                
                do {
                    // Execute Asynchronous Fetch Request
                    let _ = try context.execute(asynchronousFetchRequest) as? NSPersistentStoreAsynchronousResult
                } catch {
                    let fetchError = error as NSError
                    print("\(fetchError), \(fetchError.userInfo)")
                    completion(nil, NodeError.generalError("Unable to fetch data"))
                }
                break
            default:
                break
        }
    }

    /// Delete an individual element
    func delete<T: CoreDatable>(_ element: T) {
        var entityName: String!
        var predicateString: String!
        
        if let account = element as? Account {
            entityName = EntityName.stateCoreData.rawValue
            predicateString = account.address.address
        } else if let transaction = element as? EthereumTransaction {
            entityName = EntityName.transactionCoreData.rawValue
            guard let encoded = transaction.encode(),
                  let compressed = encoded.compressed else { return }
            predicateString = compressed.sha256().toHexString()
        } else if let receipt = element as? TransactionReceipt {
            entityName = EntityName.receiptCoreData.rawValue
            guard let encoded = receipt.encode(),
                  let compressed = encoded.compressed else { return }
            predicateString = compressed.sha256().toHexString()
        } else if let treeConfigAcct = element as? TreeConfigurableAccount {
            entityName = EntityName.stateCoreData.rawValue
            predicateString = treeConfigAcct.id
        } else if let treeConfigTx = element as? TreeConfigurableTransaction {
            entityName = EntityName.transactionCoreData.rawValue
            predicateString = treeConfigTx.id
        } else if let treeConfigReceipt = element as? TreeConfigurableReceipt {
            entityName = EntityName.receiptCoreData.rawValue
            predicateString = treeConfigReceipt.id
        }
        
        guard let predicateString = predicateString,
              let entityName = entityName else { return }
        
        coreDataStack.saveContext()
        
        // Create Fetch Request
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        fetchRequest.predicate = NSPredicate(format: "id == %@", predicateString)
        
        // Initialize Batch Delete Request
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        // Configure Batch Update Request
        batchDeleteRequest.resultType = .resultTypeCount
        
        do {
            // Execute Batch Request
            guard let batchDeleteResult = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult else {
                return
            }
            
            print("The batch delete request has deleted \(batchDeleteResult.result!) records.")
            
            // Reset Managed Object Context
            context.reset()
            
        } catch {
            let updateError = error as NSError
            print("\(updateError), \(updateError.userInfo)")
        }
    }
    
    /// Delete all within the same category
    func deleteAll(of entity: EntityName, format: String = "id == %@", predicate: String? = nil) {
        coreDataStack.saveContext()
        
        // Create Fetch Request
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entity.rawValue)
        if let predicate = predicate {
            fetchRequest.predicate = NSPredicate(format: format, predicate)
        }
        
        // Initialize Batch Delete Request
        let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        // Configure Batch Update Request
        batchDeleteRequest.resultType = .resultTypeCount
        
        do {
            // Execute Batch Request
            guard let batchDeleteResult = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult else {
                return
            }
            
            print("The batch delete request has deleted \(batchDeleteResult.result!) records.")
            
            // Reset Managed Object Context
            context.reset()
            
        } catch {
            let updateError = error as NSError
            print("\(updateError), \(updateError.userInfo)")
        }
    }
    
    /// Delete everything
    func deleteAll() {
        EntityName.allCases.forEach { deleteAll(of: $0) }
        
    }
}

protocol CoreDatable {}

enum FetchPredicate {
    case address(EthereumAddress)
    case addressString(String)
    case transaction(EthereumTransaction)
    case transactionRLP(Data)
    case receipt(TransactionReceipt)
    case receiptRLP(Data)
    case fullBlockHash(Data)
    case treeConfigAccountId(String)
    case treeConfigTxId(String)
    case treeConfigReceiptId(String)
    case lightBlockId(String)
}


extension Account: CoreDatable { }
extension EthereumTransaction: CoreDatable { }
extension TransactionReceipt: CoreDatable { }
extension FullBlock: CoreDatable { }
