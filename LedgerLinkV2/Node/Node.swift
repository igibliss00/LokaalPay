//
//  NodeCD.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-20.
//

/*
 Abstract:
 Node Core Data saves and queries TreeConfigurableAccounts, TreeConfigurableTransactions, and TreeConfigurableReceipts.
 It also creates a new block. It performs the same tasks as NodeDB except not in-memory, but with Core Data.
 */

import Foundation
import web3swift
import Combine
import BigInt
import MultipeerConnectivity

protocol NodeConfigurable {
    func search(_ data: TreeConfigurableAccount) -> TreeConfigurableAccount?
    func search(_ data: Account) throws -> TreeConfigurableAccount?
    func search(_ addressString: String) -> Account?
    func search(_ data: TreeConfigurableTransaction) -> TreeConfigurableTransaction?
    func search(_ data: TreeConfigurableReceipt) -> TreeConfigurableReceipt?
    func addData(_ data: TreeConfigurableAccount)
    func addData(_ data: Account) throws
    func addData(_ data: [TreeConfigurableAccount])
    func addData(_ data: TreeConfigurableTransaction)
    func addData(_ data: [TreeConfigurableTransaction])
    func addData(_ data: TreeConfigurableReceipt)
    func addData(_ data: [TreeConfigurableReceipt])
    func transfer(_ treeConfigTransaction: TreeConfigurableTransaction) throws
    func transfer(_ encoded: TreeConfigurableTransaction, decoded: EthereumTransaction) throws
    func getMyAccount() throws -> Account?
}

/// Received transactions are parsed into TimestampedOperation format and added to the pool (validatedOperations) to be executed sequentially.
struct TimestampedOperation {
    let timestamp: Date
    let operation: AsyncOperation
}

@available(iOS 15.0.0, *)
final class Node {
    static let shared = Node()
    let localStorage = LocalStorage()
    var storage = Set<AnyCancellable>()
    var validatedOperations: [TimestampedOperation] = [] /// validated transactions to be added to the queue and executed in order
    var validatedTransactions: [TreeConfigurableTransaction] = [] /// validated transactions to be added to the upcoming block
    var validatedAccounts: [TreeConfigurableAccount] = [] /// updated accounts after the transfer to be added to the block
    var unvalidatedBlocks: Multiset<FullBlock> = [] /// receive blocks from peers and blocks generated by your own device prior to being added to the blockchain. Multiset keeps tally of each unique blocks.
    let queue = OperationQueue() /// Queue executes transactions in timestamped order sequentially
    weak var downloadDelegate: BlockChainDownloadDelegate?
    
    func save<T: LightConfigurable>(_ element: T, completion: @escaping (NodeError?) -> Void) async {
        await localStorage.save(element, completion: completion)
    }
    
    func save<T>(_ element: T, completion: @escaping (NodeError?) -> Void) async {
        await localStorage.save(element, completion: completion)
    }
    
    func save<T: LightConfigurable>(_ elements: [T], completion: @escaping (NodeError?) -> Void) async {
        await localStorage.save(elements, completion: completion)
    }
    
    func save<T>(_ element: [T], completion: @escaping (NodeError?) -> Void) async {
        await localStorage.save(element, completion: completion)
    }
    
    func saveSync<T>(_ elements: [T], completion: @escaping (NodeError?) -> Void) {
        localStorage.saveSync(elements, completion: completion)
    }
    
    func saveSync<T: LightConfigurable>(_ elements: [T], completion: @escaping (NodeError?) -> Void) {
        localStorage.saveSync(elements, completion: completion)
    }
    
    func fetch<T: CoreDatable>(_ predicate: FetchPredicate? = nil, format: String = "id == %@", completion: @escaping ([T]?, NodeError?) -> Void) {
        localStorage.fetch(predicate, format: format, completion: completion)
    }
    
    func delete<T: CoreDatable>(_ element: T) {
        localStorage.delete(element)
    }
    
    func deleteAll(of entity: LocalStorage.EntityName, format: String = "id == %@", predicate: String? = nil) {
        localStorage.deleteAll(of: entity, format: format, predicate: predicate)
    }
    
    func deleteAll() {
        localStorage.deleteAll()
    }
    
    /*
     1. Subtract the value from the sender's balance.
     2. Add the value to the recipient's balance.
     3. Update both accounts with the updated balances to Core Data.
     */
    func transfer(transaction: EthereumTransaction) {
        guard let addressString = transaction.sender?.address else { return }
        
        Deferred {
            /// Sender's account. Subtract the value from the sender's balance
            Future<Account, NodeError> { [weak self] promise in
                guard var senderAccount: Account = try? self?.localStorage.getAccount(addressString) else {
                    promise(.failure(.generalError("Unable to find the sender's account")))
                    return
                }
                
                guard let value = transaction.value,
                      senderAccount.balance >= value else {
                          promise(.failure(NodeError.generalError("Not enough balance")))
                          return
                      }
                
                senderAccount.balance -= value
                senderAccount.updateStorageRoot(with: value)
                promise(.success(senderAccount))
            }
            .eraseToAnyPublisher()
        }
        .flatMap { [weak self] (sender) -> AnyPublisher<[Account], NodeError> in
            /// Recipient's account. Add the value to the balance
            Future<[Account], NodeError> { promise in
                guard var recipient: Account = try? self?.localStorage.getAccount(transaction.to.address) else {
                    promise(.failure(.generalError("Unable to find the recipient's account")))
                    return
                }
                
                /// If the account exists, update the amount. If not, create a new one.
                if let value = transaction.value {
                    recipient.balance += value
                    recipient.updateStorageRoot(with: value)
                    let finalAccounts = [sender, recipient]
                    promise(.success(finalAccounts))
                } else {
                    /// TODO: the newly created account should somehow be eligible for the host's credits
                    let password = Int.random(in: 1000...9999)
                    guard let newWallet = try? EthereumKeystoreV3(password: "\(password)") else {
                        promise(.failure(.generalError("Unable to generate a new address")))
                        return
                    }
                    
                    guard let address = newWallet.addresses?.first else {
                        promise(.failure(.generalError("Unable to generate a new address")))
                        return
                    }
                    
                    guard let value = transaction.value else {
                        promise(.failure(.generalError("Unable to generate get the sent balance")))
                        return
                    }
                    
                    let recipient = Account(address: address, nonce: 0, balance: value)
                    let finalAccounts = [sender, recipient]
                    promise(.success(finalAccounts))
                }
            }
            .eraseToAnyPublisher()
        }
        .sink(receiveCompletion: { completion in
            switch completion {
                case .failure(let error):
                    print("error in transfer value", error)
                    break
                case .finished:
                    print("finished in transfer value")
                    break
            }
        }, receiveValue: { [weak self] (accounts) in
            /// Accounts to be added to a block
            self?.addValidatedAccounts(accounts)
            
            /// Save both accounts with the updated balances
            Node.shared.saveSync(accounts, completion: { error in
                if let error = error {
                    print(error)
                }
                print("Save both accounts with the updated balances")
            })
        })
        .store(in: &storage)
    }
    
    func getMyAccount(completion: @escaping (Account?, NodeError?) -> Void) {
        do {
            let wallet = try localStorage.getWallet()
            guard let addressString = wallet?.address else { return }
            fetch(.addressString(addressString)) { (accounts: [Account]?, error: NodeError?) in
                if let _ = error {
                    completion(nil , error)
                }

                print("check my balance", accounts as Any)
                if let accounts = accounts, let account = accounts.first {
                    completion(account, nil)
                }
            }
        } catch {
            completion(nil, NodeError.generalError("Unable to fetch the address"))
        }
    }
    
    func getMyAccount() -> Account? {
        do {
            let wallet = try localStorage.getWallet()
            guard let addressString = wallet?.address else { return nil }
            return try localStorage.getAccount(addressString)
        } catch {
            print(error)
            return nil
        }
    }
    
    func createWallet(
        password: String,
        chainID: String,
        isHost: Bool = false,
        extraData: Data? = nil,
        completion: @escaping (Data) -> Void
    ) {
        Deferred {
            Future<KeyWalletModel, NodeError> { promise in
                KeysService().createNewWallet(password: password) { (keyWalletModel, error) in
                    if let error = error {
                        promise(.failure(error))
                        return
                    }
                    
                    guard let keyWalletModel = keyWalletModel else {
                        promise(.failure(.generalError("Unable to get the key wallet model")))
                        return
                    }
                    
                    promise(.success(keyWalletModel))
                }
            }
            .eraseToAnyPublisher()
            .flatMap { keyWalletModel -> AnyPublisher<Bool, NodeError> in
                Future<Bool, NodeError> { [weak self] promise in
                    self?.localStorage.saveWallet(wallet: keyWalletModel, completion: { (error) in
                        if let error = error {
                            promise(.failure(error))
                            return
                        }
                        
                        print("stage 2.5")
                        promise(.success(true))
                    })
                }
                .eraseToAnyPublisher()
            }
            .flatMap { (_) -> AnyPublisher<Data, NodeError> in
                Future<Data, NodeError> { promise in
                    TransactionService().prepareTransaction(.createAccount, to: nil, password: password) { data, error in
                        if let error = error {
                            promise(.failure(error))
                            return
                        }
                        
                        guard let data = data else {
                            promise(.failure(.generalError("Unable to create a transaction")))
                            return
                        }
                        
                        print("stage 3")
                        
                        promise(.success(data))
                    }
                }
                .eraseToAnyPublisher()
            }
            .flatMap { [weak self] data -> AnyPublisher<Data, NodeError> in
                Future<Data, NodeError> { promise in
                    if isHost {
                        guard let extraData = extraData else {
                            promise(.failure(.generalError("Unable to extract extra data for the genesis block")))
                            return
                        }

                        self?.mintGenesisBlock(transactionData: data, extraData: extraData, promise: promise)
                    } else {
                        promise(.success(data))
                    }
                }
                .eraseToAnyPublisher()
            }
        }
        .sink { completion in
            switch completion {
                case .failure(let error):
                    print(error)
                    break
                case .finished:
                    print("createWallet finished")
                    break
            }
        } receiveValue: { data in
            completion(data)
        }
        .store(in: &storage)
    }
    
    /// Create a genesis block and save to Core Data
    /// Create a second block and add it to the unvalidated pool of blocks.
    /// The genesis block and the second block will be compared by the node and proceed to creating another block.
    func mintGenesisBlock(transactionData: Data, extraData: Data, promise: @escaping (Result<Data, NodeError>) -> Void) {
        print("mintGenesisBlock----------------")
        
        guard let account = getMyAccount() else {
            print("unable to get my account")
            return
        }
        
        do {
            let treeConfigTx = try TreeConfigurableTransaction(rlpTransaction: transactionData)
            let treeConfigAcct = try TreeConfigurableAccount(data: account)
            
            let defaultString = "0x0000000000000000000000000000000000000000"
            guard let defaultStateData = defaultString.data(using: .utf8) else {
                promise(.failure(.generalError("Unable to prepare the default data")))
                return
            }
            guard case .Node(hash: let stateRoot, datum: _, left: _, right: _) = try MerkleTree.buildTree(fromData: [defaultStateData]) else {
                promise(.failure(.generalError("Unable to get the state root")))
                return
            }
            
            guard case .Node(hash: let transactionsRoot, datum: _, left: _, right: _) = try MerkleTree.buildTree(fromData: [transactionData]) else {
                promise(.failure(.generalError("Unable to get the transaction root")))
                return
            }
            
            let genesisBlock = try FullBlock(number: 0, parentHash: Data(), nonce: nil, transactionsRoot: transactionsRoot, stateRoot: stateRoot, receiptsRoot: Data(), extraData: extraData, gasLimit: nil, gasUsed: nil, miner: account.address.address, transactions: [treeConfigTx], accounts: [treeConfigAcct])
            print("genesisBlock", genesisBlock)

            /// Genesis block is saved because it requires no validation
            self.saveSync([genesisBlock]) { (error) in
                if let error = error {
                    promise(.failure(error))
                }
                
                do {
                    let lightBlock = try LightBlock(data: genesisBlock)
                    let encoded = try JSONEncoder().encode(lightBlock)
                    let contractMethod = ContractMethod.sendBlock(encoded)
                    let encodedMethod = try JSONEncoder().encode(contractMethod)
                    NetworkManager.shared.sendDataToAllPeers(data: encodedMethod)
                    
                    promise(.success(encodedMethod))
                } catch {
                    promise(.failure(.generalError(error.localizedDescription)))
                }
            }
        } catch {
            promise(.failure(.generalError(error.localizedDescription)))
        }
    }
    
    func addValidatedOperation(_ operation: TimestampedOperation) {
        self.validatedOperations.append(operation)
    }
    
    func addValidatedTransaction(_ rlpData: Data) {
        guard let treeConfigTx = try? TreeConfigurableTransaction(rlpTransaction: rlpData) else { return }
        self.validatedTransactions.append(treeConfigTx)
    }
    
    func addValidatedTransaction(_ transaction: EthereumTransaction) {
        guard let treeConfigTx = try? TreeConfigurableTransaction(data: transaction) else { return }
        addValidatedTransaction(treeConfigTx)
    }
    
    func addValidatedTransaction(_ transaction: TreeConfigurableTransaction) {
        validatedTransactions.append(transaction)
    }
    
    func addValidatedAccount(_ account: Account) {
        guard let treeConfigAcct = try? TreeConfigurableAccount(data: account) else { return }
        validatedAccounts.append(treeConfigAcct)
    }

    func addValidatedAccounts(_ accounts: [Account]) {
        accounts.forEach { addValidatedAccount($0) }
    }

    func addUnvalidatedBlock(_ block: FullBlock) {
        unvalidatedBlocks.add(block)
    }
    
    /// Process the transactions received from peers according to the contract methods.
    func processTransaction(_ data: Data, peerID: MCPeerID) {
        verifyValidator { [weak self] (isValidator) in
            if isValidator {
                self?.processTransactionAsValidator(data, peerID: peerID)
            } else {
                self?.processTransactionAsNonValidator(data, peerID: peerID)
            }
        }
    }
    
    private func processTransactionAsValidator(_ data: Data, peerID: MCPeerID) {
        do {
            let decoded = try JSONDecoder().decode(ContractMethod.self, from: data)
            switch decoded {
                case .createAccount(let rlpData):
                    NetworkManager.shared.relayTransaction(data: data, peerID: peerID)
                    validateTransaction(rlpData) { [weak self] (result, error) in
                        if let transaction = result.0,
                           let extraData = result.1 {
                            let createAccount = CreateAccount(extraData: extraData)
                            let timestamp = extraData.timestamp
                            
                            /// Add the operations to be sorted according to the timestamp and to be executed in order
                            self?.addValidatedOperation(TimestampedOperation(timestamp: timestamp, operation: createAccount))
                            
                            /// Add the transactions to be added to the upcoming block
                            self?.addValidatedTransaction(transaction)
                        }
                    }
                    break
                case .transferValue(let rlpData):
                    NetworkManager.shared.relayTransaction(data: data, peerID: peerID)
                    validateTransaction(rlpData) { [weak self] (result, error) in
                        if let transaction = result.0,
                           let extraData = result.1 {
                            let transferValueOperation = TransferValueOperation(transaction: transaction)
                            let timestamp = extraData.timestamp
                            
                            /// Add the operations to be sorted according to the timestamp and to be executed in order
                            self?.addValidatedOperation(TimestampedOperation(timestamp: timestamp, operation: transferValueOperation))
                            
                            /// Add the transactions to be added to the upcoming block
                            guard let treeConfigTx = try? TreeConfigurableTransaction(data: transaction) else { return }
                            self?.addValidatedTransaction(treeConfigTx)
                        }
                    }
                    break
                case .blockchainDownloadRequest(let blockNumber):
                    /// Blockchain requested by the sender. Therefore, send the requested blockchain.
                    /// Usually requested when an account is newly created
                    NetworkManager.shared.sendBlockchain(blockNumber, format: "number >= %i", peerID: peerID)
                    break
                case .blockchainDownloadResponse(let packet):
                    /// Parse the requested blockchain
                    /// Non-transactions don't have to go through the queue such as the blockchain data sent from peers as a response to the request to update the local blockchain
                    /// Blockchain data received from peers to update the local blockchain.  This means your device has requested the blockchain info from another peer either during the creation of wallet or during the contract method execution.
                    
                    print("blockchainDownloadResponse packet", packet)
                    
                    guard let blocks = packet.blocks else { return }
                    if isBlockchainValid(blocks) {
                        parsePacket(packet)
                    } else {
                        print("invalid blockchain")
                    }
                    break
                case .sendBlock(let data):
                    print("sendBlock", data)
                    /// Light blocks sent from peers on a regular interval
                    NetworkManager.shared.relayBlock(data)
//                    let decoded = try JSONDecoder().decode(LightBlock.self, from: data)
//                    parseBlock(decoded)
                    break
                case .blockchainDownloadAllRequest:
                    /// Request a complete blockchain.
                    /// This is used when a new block to be added is incompatible with the local blockchain and needs a complete overhaul.
                    NetworkManager.shared.sendBlockchain(Int32(0), format: "number >= %i", peerID: peerID)
                    break
                case .blockchainDownloadAllResponse(let packet):
                    print(packet)
//                    deleteAll()
//                    guard let blocks = packet.blocks else { return }
//                    if isBlockchainValid(blocks) {
//                        for block in blocks {
//                            Node.shared.localStorage.saveRelationalBlock(block: block) { error in
//                                if let error = error {
//                                    print("blockchainDownloadAllResponse error", error)
//                                    return
//                                }
//                            }
//                        }
//                    }
                    
                    break
            }
        } catch {
            print("error in didReceive", error)
        }
    }
    
    private func processTransactionAsNonValidator(_ data: Data, peerID: MCPeerID) {
        do {
            let decoded = try JSONDecoder().decode(ContractMethod.self, from: data)
            switch decoded {
                case .createAccount(_):
                    NetworkManager.shared.relayTransaction(data: data, peerID: peerID)
                    break
                case .transferValue(_):
                    NetworkManager.shared.relayTransaction(data: data, peerID: peerID)
                    break
                case .blockchainDownloadRequest(let blockNumber):
                    /// Blockchain request by the sender. Therefore, send the requested blockchain.
                    /// Usually requested when an account is newly created
                    NetworkManager.shared.sendBlockchain(blockNumber, format: "number >= %i", peerID: peerID)
                    break
                case .blockchainDownloadResponse(let packet):
                    /// Parse the requested blockchain
                    /// Non-transactions don't have to go through the queue such as the blockchain data sent from peers as a response to the request to update the local blockchain
                    /// Blockchain data received from peers to update the local blockchain.  This means your device has requested the blockchain info from another peer either during the creation of wallet or during the contract method execution.
                    guard let blocks = packet.blocks else { return }
                    if isBlockchainValid(blocks) {
                        parsePacket(packet)
                    } else {
                        print("invalid blockchain")
                    }
                    break
                case .sendBlock(let data):
                    /// Light blocks sent from peers on a regular interval
                    NetworkManager.shared.relayBlock(data)
                    let decoded = try JSONDecoder().decode(LightBlock.self, from: data)
                    parseBlock(decoded)
                    break
                case .blockchainDownloadAllRequest:
                    /// Request a complete blockchain.
                    /// This is used when a new block to be added is incompatible with the local blockchain and needs a complete overhaul.
                    NetworkManager.shared.sendBlockchain(Int32(0), format: "number >= %i", peerID: peerID)
                    break
                case .blockchainDownloadAllResponse(let packet):
                    deleteAll()
                    guard let blocks = packet.blocks else { return }
                    if isBlockchainValid(blocks) {
                        for block in blocks {
                            Node.shared.localStorage.saveRelationalBlock(block: block) { error in
                                if let error = error {
                                    print("blockchainDownloadAllResponse error", error)
                                    return
                                }
                            }
                        }
                    }
                    
                    break
            }
        } catch {
            print("error in didReceive", error)
        }
    }

    /// What is a valid transaction?
    ///  1. The recovered public key should match the sender.
    ///  2. The transaction should not already exist in the blockchain.
    ///  3. The transaction should not already exist among validated transaction pool to be added to the upcoming block (no duplicted allowed).
    private func validateTransaction(_ rlpData: Data, completion: @escaping ((EthereumTransaction?, TransactionExtraData?), NodeError?) -> Void)  {
        /// 1. Validate the transaction by recovering the public key.
        guard let decodedTx = EthereumTransaction.fromRaw(rlpData),// RLP -> EthereumTransaction
              let publicKey = decodedTx.recoverPublicKey(),
              let senderAddress = Web3.Utils.publicToAddressString(publicKey),
              let senderAddressToBeCompared = decodedTx.sender?.address,
              senderAddress == senderAddressToBeCompared.lowercased(), // If the two info are different, discard the transaction.
              let decodedExtraData = try? JSONDecoder().decode(TransactionExtraData.self, from: decodedTx.data),
              let compressed = rlpData.compressed else {
                  completion((nil, nil), .generalError("Unable to validate the transaction"))
                  return
              }
        
        let chainID = UserDefaults.standard.integer(forKey: "chainID")
        guard decodedExtraData.chainID == BigUInt(chainID) else {
            completion((nil, nil), .generalError("Incorrect chain ID"))
            return
        }

        let transactionHash = compressed.sha256().toHexString()
        /// 2. Validate the transaction by checking for duplicates in the waiting pool. If a duplicate exists, don't add to the pool.
        let duplicates = validatedTransactions.filter ({ $0.id == transactionHash })
        guard duplicates.count == 0 else {
            completion((nil, nil), .generalError("Duplicate transaction exists"))
            return
        }

        /// 3. Validate the transaction by checking for duplicates in the blockchain
        Node.shared.fetch(.treeConfigTxId(transactionHash)) { (txs: [EthereumTransaction]?, error: NodeError?) in
            if let error = error {
                print("fetch error", error)
                completion((nil, nil), error)
                return
            }

            /// No matching transaction exists in Core Data so proceed to process the transaction
            guard let txs = txs, txs.count == 0  else {
                completion((nil, nil), .generalError("Duplicate transaction exists in the blockchain"))
                return
            }

            completion((decodedTx, decodedExtraData), nil)
        }
    }

    /// Parses Packet which consists of an array of Blocks (which includes TreeConfigAccouts and TreeConfigTransactions)
    /// The packets are sent as a response to a request for a portion of or a full blockchain by peers
    private func parsePacket(_ packet: Packet) {
        /// Calculate the blocks that don't exist locally and save them.
        /// If the device only receives one block, that most likely referrs to the genesis block, which the local Core Data should already have
        guard let blocks = packet.blocks, blocks.count > 1 else {
            return
        }
        
        do {
            let block: FullBlock? = try localStorage.getLatestBlock()
            if let block = block {
                let nonExistingBlocks = blocks.filter { $0.number > block.number }
                /// There is a chance that the local blockchain size might have increased during the transfer. If so, ignore the received block
                if nonExistingBlocks.count > 0 {
                    for nonExistingBlock in nonExistingBlocks {
                        Node.shared.localStorage.saveRelationalBlock(block: nonExistingBlock) { error in
                            if let error = error {
                                print("parse packet set error1", error)
                                return
                            }
                        }
                    }
                    self.downloadDelegate?.didReceiveBlockchain()
                }
            } else {
                /// no local blockchain exists yet because it's a brand new account
                /// delete potentially existing ones since no transactions could've/should've been occured
                Node.shared.deleteAll()
                for block in blocks {
                    Node.shared.localStorage.saveRelationalBlock(block: block) { error in
                        if let error = error {
                            print("parse packet set error1", error)
                            return
                        }
                    }
                }
                self.downloadDelegate?.didReceiveBlockchain()
            }
        } catch {
            print("parse packet error", error)
        }
        
        
//        Node.shared.localStorage.getLatestBlock { [weak self] (block: FullBlock?, error: NodeError?) in
//            if let error = error {
//                print(error)
//                return
//            }
//
//            if let block = block {
//                /// Only save the blocks that are greater in its block number than then the already existing blocks.
//                let nonExistingBlocks = blocks.filter { $0.number > block.number }
//                /// There is a chance that the local blockchain size might have increased during the transfer. If so, ignore the received block
//                if nonExistingBlocks.count > 0 {
//                    for nonExistingBlock in nonExistingBlocks {
//                        Node.shared.localStorage.saveRelationalBlock(block: nonExistingBlock) { error in
//                            if let error = error {
//                                print("parse packet set error1", error)
//                                return
//                            }
//
//                            self?.downloadDelegate?.didReceiveBlockchain()
//                        }
//                    }
//                }
//            } else {
//                /// no local blockchain exists yet because it's a brand new account
//                /// delete potentially existing ones since no transactions could've/should've been occured
//                Node.shared.deleteAll()
//                for block in blocks {
//                    Node.shared.localStorage.saveRelationalBlock(block: block) { error in
//                        if let error = error {
//                            print("parse packet set error1", error)
//                            return
//                        }
//
//                        self?.downloadDelegate?.didReceiveBlockchain()
//                    }
//                }
//            }
//        }
        
        /// Following are only for non-relational Core Data
        /// Relational Core Data automatically saves the related entities for us.
        /// Save the transactions.
        if let transactions = packet.transactions, transactions.count > 0 {
            Node.shared.saveSync(transactions) { error in
                if let error = error {
                    print("transaction save error", error)
                    return
                }
            }
        }

        /// Save the accounts.
        if let accounts = packet.accounts, accounts.count > 0 {
            Node.shared.saveSync(accounts) { error in
                if let error = error {
                    print("accounts save error", error)
                    return
                }
            }
        }
    }
    
    /// Calculate the block hash for each block and verify that the latest block has the correct hash
    /// This method is usually executed when you download a whole blockchain from peers, not when the validator regularly sends a block
    func isBlockchainValid(_ blocks: [LightBlock]) -> Bool {
        guard blocks.count > 1 else { return true }
                
        /// Only unique blocks have to exist
        var sortedBlocks = blocks.uniqued()
        
        /// Sort them according to the block number to compare the hash against the parent hash
        quicksortDutchFlag(&sortedBlocks, low: 0, high: blocks.count - 1)
        
        for i in 0 ..< sortedBlocks.count - 1 {
            guard let fullBlock = sortedBlocks[i].decode(),
                  let nextBlock = sortedBlocks[i + 1].decode() else { return false }
            let blockHash = try? fullBlock.generateBlockHash()
            if (fullBlock.hash == blockHash) && (nextBlock.parentHash == blockHash) {
                continue
            } else {
                return false
            }
        }
        
        return true
    }

    /// Receive the block sent from peers
    private func parseBlock(_ block: LightBlock) {
        guard let fullBlock = block.decode() else { return }
        addUnvalidatedBlock(fullBlock)
    }
}

#if DEBUG
extension Node {
    func exposeValidateTransaction(_ rlpData: Data, completion: @escaping ((EthereumTransaction?, TransactionExtraData?), NodeError?) -> Void) {
        return validateTransaction(rlpData, completion: completion)
    }
}
#endif
