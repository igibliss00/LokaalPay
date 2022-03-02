//
//  NetworkManager.swift
//  LedgerLinkV2
//
//  Created by J C on 2022-02-17.
//

/*
 Transactions are to be sent out as soon as they're created.
 The receieved transactions are to be relayed immediately as well.
 The blocks, however, are created and added on a regular interval.
 
 When a node receives a transaction, check the block number to see if latest blocks have to be downloaded from other nodes before processing the transactions to a new block.
 */

import Foundation
import MultipeerConnectivity
import MediaPlayer
import web3swift
import BigInt
import Combine

final class NetworkManager: NSObject {
    static let shared = NetworkManager()
    private let serviceType = "ledgerlink"
    private var peerID: MCPeerID!
    private var session: MCSession!
    private var nearbyServiceAdvertiser: MCNearbyServiceAdvertiser!
    private var nearbyBrowser: MCNearbyServiceBrowser!
    var peerDataHandler: ((Data, MCPeerID) -> Void)?
    var peerConnectedHandler: ((MCPeerID) -> Void)?
    var peerDisconnectedHandler: ((MCPeerID) -> Void)?
    private let maxNumPeers: Int = 10
    private var player: AVQueuePlayer!
    private var playerLooper: AVPlayerLooper!
    private var isServerRunning = false
    private var timer: Timer!
    private let transactionService = TransactionService()
    var blockchainReceiveHandler: ((String) -> Void)?
    let notificationCenter = NotificationCenter.default
    private var storage = Set<AnyCancellable>()
    private var transactionRelayHistory = [Data: Set<MCPeerID>]()
    private var blockRelayHistory = [Data: Set<MCPeerID>]()

    override init() {
        super.init()
        self.configureSession()
        self.setupNotifications()
    }
    
    private func configureSession() {
        peerID = MCPeerID(displayName: UIDevice.current.name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        
        nearbyBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        nearbyBrowser.delegate = self
    }
    
//    enum Methods: String {
//        case transfer
//        case downloadBlockchain
//        case blockchainReceived
//    }
    
    // MARK: - `MPCSession` public methods.
    func start() {
        guard isServerRunning == false else { return }
        self.nearbyServiceAdvertiser = MCNearbyServiceAdvertiser(peer: self.peerID, discoveryInfo: nil, serviceType: self.serviceType)
        self.nearbyServiceAdvertiser.delegate = self
        self.nearbyServiceAdvertiser?.startAdvertisingPeer()
        self.nearbyBrowser.startBrowsingForPeers()
        self.isServerRunning = true
        
        /// Start the pinging only at every 0 or 30 second so that all the devices could be synchronized.
        let date = Date()
        let roundedDate = date.rounded(on: 30, .second)
        if self.timer != nil {
            self.timer.invalidate()
        }
        /// From the 0 or 30 second mark, the auto relay is run at a specified interval
        self.timer = Timer(fireAt: roundedDate, interval: 10, target: self, selector: #selector(self.autoRelay), userInfo: nil, repeats: true)
        RunLoop.main.add(self.timer, forMode: .common)
    }
    
    func suspend() {
        nearbyServiceAdvertiser?.stopAdvertisingPeer()
        nearbyBrowser.stopBrowsingForPeers()
    }
    
    func disconnect() {
        suspend()
        player = nil
        playerLooper = nil
        timer?.invalidate()
        isServerRunning = false
        session.disconnect()
    }
    
    func getServerStatus() -> Bool {
        return isServerRunning
    }
    
    func getConnectedPeerNumbers() -> Int {
        return session.connectedPeers.count
    }
    
    @objc private func autoRelay() {
        guard isServerRunning else { return }
        
        if session.connectedPeers.count == 0 {
//            suspend()
            start()
        }

        /// The relay history has to be refreshed
        
        /// Dispatching blocks on a regular interval
        Node.shared.createBlock { [weak self] (block) in
            do {
                let encoded = try JSONEncoder().encode(block)
                guard let compressed = encoded.compressed else { return }
                let contractMethod = ContractMethod.sendBlock(compressed)
                let encodedMethod = try JSONEncoder().encode(contractMethod)
                self?.sendDataToAllPeers(data: encodedMethod)
                self?.transactionRelayHistory.removeAll()
                self?.blockRelayHistory.removeAll()
            } catch {
                print("block send error", error)
            }
        }
    }
    
    // MARK: - `MPCSession` private methods.
    private func peerConnected(peerID: MCPeerID) {
        if let handler = peerConnectedHandler {
            DispatchQueue.main.async {
                handler(peerID)
            }
        }
        if session.connectedPeers.count == maxNumPeers {
            self.suspend()
        }
    }
    
    private func peerDisconnected(peerID: MCPeerID) {
        if let handler = peerDisconnectedHandler {
            DispatchQueue.main.async {
                handler(peerID)
            }
        }
        
        if session.connectedPeers.count < maxNumPeers {
            self.start()
        }
    }
    
    func sendDataToAllPeers(data: Data) {
        print("session.connectedPeers", session.connectedPeers)
        guard !session.connectedPeers.isEmpty else { return }
        sendData(data: data, peers: session.connectedPeers, mode: .reliable)
    }
    
    func sendData(data: Data, peers: [MCPeerID], mode: MCSessionSendDataMode) {
        do {
            let filteredPeers = peers.filter { $0 != session.myPeerID }
            print("filteredPeers", filteredPeers as Any)
            try session.send(data, toPeers: filteredPeers, with: mode)
        } catch let error {
            NSLog("Error sending data: \(error)")
        }
    }
}

// MARK: - MCSessionDelegate
extension NetworkManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
            case .connected:
                print("connected")
                peerConnected(peerID: peerID)
            case .notConnected:
                print("notConnected")
                peerDisconnected(peerID: peerID)
            case .connecting:
                print("connecting")
                break
            @unknown default:
                fatalError("Unhandled MCSessionState")
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        print("didReceive", data)
        
        Node.shared.processTransaction(data, peerID: peerID)
       
        
//        let queue = OperationQueue()
//
//        /// Non-transactions don't have to go through the queue such as the blockchain data sent from peers as a response to the request to update the local blockchain
//        if let uncompressed = data.decompressed {
//            if let packet = try? JSONDecoder().decode(Packet.self, from: uncompressed) {
//                /// Blockchain data received from peers to update the local blockchain.  This means your device has requested the blockchain info from another peer either during the creation of wallet or during the contract method execution.
//                parsePacket(packet)
//            } else if let lightBlock = try? JSONDecoder().decode(LightBlock.self, from: data) {
//                /// New block received from peers on a regular interval.
//                parseBlock(lightBlock)
//            }
//        } else if let blockNumber = try? JSONDecoder().decode(Int32.self, from: data) {
//            print("block request received from \(peerID) for \(session.myPeerID)", blockNumber as Any)
//            /// Received a request to send over blockchain, accounts, and transactions.  Only the latest block number is needed to know how many blocks to send over.
//            sendBlockchain(blockNumber, format: "number > %i", peerID: peerID)
//        } else if let rlpDataArray = data.decompressedToArray {
//            print("rlpDataArray", rlpDataArray as Any)
//            /// Parse an array of RLP-encoded transactions sent from peers and add them to the queue
//            for rlpData in rlpDataArray {
//                let parseOperation = ParseTransactionOperation(rlpData: rlpData, peerID: peerID)
//                let contractMethodOperation = ContractMethodOperation()
//                contractMethodOperation.addDependency(parseOperation)
//
//                queue.addOperations([parseOperation, contractMethodOperation], waitUntilFinished: true)
//                print("Operation finished with: \(contractMethodOperation.result!)")
//            }
//        } else {
//            print("single RLP")
//            /// Parse a single uncompressed, RLP-encoded transaction and add it to the queue. Account creation and value transfer are sent this way.
//            let parseOperation = ParseTransactionOperation(rlpData: data, peerID: peerID)
//            let contractMethodOperation = ContractMethodOperation()
//            contractMethodOperation.addDependency(parseOperation)
//            queue.addOperations([parseOperation, contractMethodOperation], waitUntilFinished: true)
//            print("Operation finished with: \(contractMethodOperation.result!)")
//        }
    }
    
    func relayBlock(_ blockData: Data) {
        /// Check the sent history to prevent duplicate sends
        if var sentPeersSet = blockRelayHistory[blockData] {
            sentPeersSet.insert(peerID)
            let unsentPeers = Set(session.connectedPeers).subtracting(sentPeersSet)
            sendData(data: blockData, peers: Array(unsentPeers), mode: .reliable)
            unsentPeers.forEach { sentPeersSet.insert($0) }
            blockRelayHistory.updateValue(sentPeersSet, forKey: blockData)
        } else {
            /// No peers have been contacted regarding this specific data yet
            let unsentPeers = session.connectedPeers.filter { $0 != peerID }
            blockRelayHistory.updateValue(Set(unsentPeers), forKey: blockData)
            sendData(data: blockData, peers: session.connectedPeers, mode: .reliable)
        }
    }
    
    func relayTransaction(data: Data, peerID: MCPeerID) {
        /// Check the sent history to prevent duplicate sends
        if var sentPeersSet = transactionRelayHistory[data] {
            sentPeersSet.insert(peerID)
            let unsentPeers = Set(session.connectedPeers).subtracting(sentPeersSet)
            sendData(data: data, peers: Array(unsentPeers), mode: .reliable)
            unsentPeers.forEach { sentPeersSet.insert($0) }
            transactionRelayHistory.updateValue(sentPeersSet, forKey: data)
        } else {
            /// No peers have been contacted regarding this specific data yet
            let unsentPeers = session.connectedPeers.filter { $0 != peerID }
            transactionRelayHistory.updateValue(Set(unsentPeers), forKey: data)
            sendData(data: data, peers: session.connectedPeers, mode: .reliable)
        }
    }

    func requestBlockchainFromAllPeers(completion: @escaping(NodeError?) -> Void) {
        guard !session.connectedPeers.isEmpty else {
            completion(.generalError("No peers"))
            return
        }
        requestBlockchain(peerIDs: session.connectedPeers, completion: completion)
    }
    
    /// Download blockchain by requesting it from another peer
    /// Request blocks with a number that's later than the latest local block.
    func requestBlockchain(peerIDs: [MCPeerID], completion: @escaping (NodeError?) -> Void) {
        do {
            let block: LightBlock? = try Node.shared.localStorage.getLastestBlockSync()
            print("latestBlock", block as Any)
            /// local blockchain may or may not exists
            let blockNumber = block?.number ?? Int32(0)
            let contractMethod = ContractMethod.blockchainDownloadRequest(blockNumber)
            let data = try JSONEncoder().encode(contractMethod)
            self.sendData(data: data, peers: peerIDs, mode: .reliable)
            completion(nil)
        } catch {
            print(error)
            completion(.generalError("request block error"))
        }
    }
    
    /// Request a complete blockchain.
    /// This is used when a new block to be added is incompatible with the local blockchain and needs a complete overhaul.
    func requestAllBlockchain(completion: @escaping(NodeError?) -> Void) {
        do {
            let contractMethod = ContractMethod.blockchainDownloadAllRequest
            let data = try JSONEncoder().encode(contractMethod)
            self.sendData(data: data, peers: session.connectedPeers, mode: .reliable)
            completion(nil)
        } catch {
            completion(.generalError("request block error"))
        }
    }
    
    func sendBlockchain(_ blockNumber: Int32, format: String, peerID: MCPeerID) {
        let accounts = Future<[TreeConfigurableAccount]?, NodeError> { promise in
            Node.shared.localStorage.getAllAccountsSync { (accts: [TreeConfigurableAccount]?, error: NodeError?) in
                if let error = error {
                    promise(.failure(error))
                    return
                }
                
                promise(.success(accts))
            }
        }
        
        let transactions = Future<[TreeConfigurableTransaction]?, NodeError> { promise in
            Node.shared.localStorage.getAllTransactionsAsync { (tx: [TreeConfigurableTransaction]?, error: NodeError?) in
                if let error = error {
                    promise(.failure(error))
                    return
                }
                
                promise(.success(tx))
            }
        }
        
        let blocks = Future<[LightBlock]?, NodeError> { promise in
            Node.shared.localStorage.getBlocks(from: blockNumber, format: format) { (blocks: [LightBlock]?, error: NodeError?) in
                if let error = error {
                    promise(.failure(error))
                    return
                }
                
                promise(.success(blocks))
            }
        }
        
        Publishers.CombineLatest3(accounts, transactions, blocks)
            .collect()
            .eraseToAnyPublisher()
            .flatMap({ (results) -> AnyPublisher<Data, NodeError> in
                Future<Data, NodeError> { promise in
                    
                    var packet = Packet()
                    for (acct, tx, block) in results {
                        if let acct = acct {
                            packet.accounts?.append(contentsOf: acct)
                        }
                        
                        if let tx = tx {
                            packet.transactions?.append(contentsOf: tx)
                        }
                        
                        if let block = block {
                            packet.blocks?.append(contentsOf: block)
                        }
                    }
                    
                    do {
                        let contractMethod = ContractMethod.blockchainDownloadResponse(packet)
                        let encodedMethod = try JSONEncoder().encode(contractMethod)
                        promise(.success(encodedMethod))
                    } catch {
                        promise(.failure(.generalError("Unable to encode data")))
                        return
                    }
                }
                .eraseToAnyPublisher()
            })
            .sink { completion in
                switch completion {
                    case .finished:
                        print("sendBlockchain finished")
                    case .failure(let error):
                        print("sendBlockchain error", error)
                }
                print(completion)
            } receiveValue: { finalValue in
                print("finalValue", finalValue)
                NetworkManager.shared.sendData(data: finalValue, peers: [peerID], mode: .reliable)
            }
            .store(in: &self.storage)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        print("didReceive stream", stream)
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        print("didStartReceivingResourceWithName", resourceName)
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        print("didFinishReceivingResourceWithName", resourceName)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension NetworkManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("didReceiveInvitationFromPeer", peerID)
        invitationHandler(true, session)
    }
}

//extension NetworkManager: MCBrowserViewControllerDelegate {
//    func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
//        dismiss(animated: true)
//    }
//
//    func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
//        dismiss(animated: true)
//    }
//}

// MARK: - MCNearbyServiceBrowserDelegate
extension NetworkManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("foundPeer", peerID)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 0)

        //        session.nearbyConnectionData(forPeer: peerID) { [weak self] (data, error) in
        //            if let error = error {
        //                print("nearby error", error)
        //            }
        //
        //            if let data = data {
        //                print("connectPeer", data)
        //                self?.session.connectPeer(peerID, withNearbyConnectionData: data)
        //            }
        //        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("lostPeer", peerID)
    }
}

// MARK: - Player
extension NetworkManager {
    private func getPlayerItems() -> [AVPlayerItem] {
        let itemNames = ["1"]
        return itemNames.map {
            let url = Bundle.main.url(forResource: $0, withExtension: "mp3")!
            return AVPlayerItem(url: url)
        }
    }
    
    private func makePlayer() -> AVQueuePlayer? {
        let player = AVQueuePlayer()
        let items = getPlayerItems()
        guard let item = items.first else { return nil }
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .advance
        //        player.addObserver(self, forKeyPath: "currentItem", options: [.new, .initial] , context: nil)
        player.volume = 0
        
        self.playerLooper = makeLooper(player: player, item: item)
        return player
    }
    
    private func makeLooper(player: AVQueuePlayer, item: AVPlayerItem) -> AVPlayerLooper {
        let looper = AVPlayerLooper(player: player, templateItem: item)
        return looper
    }
    
    /// Checking the state of the application twice seem redundant, but background to foreground sometimes triggers the player.
    private func stateCheckAndPlay() {
        DispatchQueue.main.async { [weak self] in
            if UIApplication.shared.applicationState == .active {
                self?.toggleBackgroundMode(false)
            } else if UIApplication.shared.applicationState == .inactive {
            } else if UIApplication.shared.applicationState == .background {
                self?.toggleBackgroundMode(true)
            }
        }
    }
    
    final func toggleBackgroundMode(_ isBackgrounded: Bool) {
        if isBackgrounded {
            guard isServerRunning == true else { return }
            if player == nil {
                player = self.makePlayer()
            }
            player.play()
            player.volume = 0

            do {
                try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback, options: .mixWithOthers )
            } catch {
                print("Failed to set audio session category. Error: \(error)")
            }
            
            let seconds: Float64 = 10;
            let preferredTimeScale: Int32 = 1;
            let forInterval = CMTimeMakeWithSeconds(seconds, preferredTimescale: preferredTimeScale)
            
            player.addPeriodicTimeObserver(forInterval: forInterval, queue: DispatchQueue.main) { time in
                
            }
        } else {
            player = nil
            playerLooper = nil
        }
    }
    
    /// Observe the audio interruptions.
    private func setupNotifications() {
        // Get the default notification center instance.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleInterruption),
                       name: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance())
        
        nc.addObserver(self,
                       selector: #selector(handleRouteChange),
                       name: AVAudioSession.routeChangeNotification,
                       object: nil)
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                  return
              }
        
        /// Interuption ended takes time to reboot.
        switch type {
            case .began:
                break
            case .ended:
                stateCheckAndPlay()
                break
            default: ()
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        stateCheckAndPlay()
    }
    
    private func hasHeadphones(in routeDescription: AVAudioSessionRouteDescription) -> Bool {
        // Filter the outputs to only those with a port type of headphones.
        return !routeDescription.outputs.filter({$0.portType == .headphones}).isEmpty
    }
}

struct Packet: Codable {
    var accounts: [TreeConfigurableAccount]?
    var transactions: [TreeConfigurableTransaction]?
    var blocks: [LightBlock]?
}
