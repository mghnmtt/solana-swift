//
//  RenVM+LockAndMint.swift
//  SolanaSwift
//
//  Created by Chung Tran on 09/09/2021.
//

import Foundation
import RxSwift

public typealias Long = Int64

extension RenVM {
    public class LockAndMint {
        // MARK: - Dependencies
        let rpcClient: RenVMRpcClientType
        let chain: RenVMChainType
        
        // MARK: - State
        var session: Session
        var state = State()
        
        init(
            rpcClient: RenVMRpcClientType,
            chain: RenVMChainType,
            destinationAddress: Data,
            sessionDay: Long
        ) {
            self.rpcClient = rpcClient
            self.chain = chain
            self.session = Session(destinationAddress: destinationAddress, sessionDay: sessionDay)
        }
        
        func generateGatewayAddress() -> Single<Data> {
            let sendTo: Data
            do {
                sendTo = try chain.getAssociatedTokenAddress(address: session.destinationAddress)
            } catch {
                return .error(error)
            }
            state.sendTo = sendTo
            let sendToHex = sendTo.hexString
            let tokenGatewayContractHex = Hash.generateSHash().hexString
            let gHash = Hash.generateGHash(to: sendToHex, tokenIdentifier: tokenGatewayContractHex, nonce: Data(hex: session.nonce).bytes)
            state.gHash = gHash
            
            return rpcClient.selectPublicKey()
                .observe(on: CurrentThreadScheduler.instance)
                .map {[weak self] gPubkey in
                    guard let self = self else {throw Error.unknown}
                    guard let gPubkey = gPubkey
                    else {throw Error("Provider's public key not found")}
                    
                    self.state.gPubKey = gPubkey
                    
                    let gatewayAddress = Script.createAddressByteArray(
                        gGubKeyHash: gPubkey.hash160,
                        gHash: gHash,
                        prefix: Data([self.rpcClient.network.p2shPrefix])
                    )
                    self.session.gatewayAddress = gatewayAddress
                    return self.session.gatewayAddress
                }
        }
        
        func getDepositState(
            transactionHash: String,
            txIndex: String,
            amount: String
        ) throws -> State {
            let nonce = Data(hex: session.nonce)
            let txid = Data(hex: reverseHex(src: transactionHash))
            let nHash = Hash.generateNHash(nonce: nonce.bytes, txId: txid.bytes, txIndex: UInt32(txIndex) ?? 0)
            let pHash = Hash.generatePHash()
            
            guard let gHash = state.gHash,
                  let gPubkey = state.gPubKey,
                  let to = state.sendTo
            else {throw Error("Some parameters are missing")}
            
            let mintTx = MintTransactionInput(gHash: gHash, gPubkey: gPubkey, nHash: nHash, nonce: nonce, amount: amount, pHash: pHash, to: try chain.dataToAddress(data: to), txIndex: txIndex, txid: txid)
            
            let txHash = try mintTx.hash().base64urlEncodedString()
            
            state.txIndex = txIndex
            state.amount = amount
            state.nHash = nHash
            state.txid = txid
            state.pHash = pHash
            state.txHash = txHash
            
            return state
        }
        
        func submitMintTransaction() -> Single<String> {
            guard let gHash = state.gHash,
                  let gPubkey = state.gPubKey,
                  let nHash = state.nHash,
                  let amount = state.amount,
                  let pHash = state.pHash,
                  let sendTo = state.sendTo,
                  let to = try? chain.dataToAddress(data: sendTo),
                  let txIndex = state.txIndex,
                  let txid = state.txid
            else {return .error(Error("Some parameters are missing"))}
            let nonce = Data(hex: session.nonce)
            
            let mintTx = MintTransactionInput(
                gHash: gHash,
                gPubkey: gPubkey,
                nHash: nHash,
                nonce: nonce,
                amount: amount,
                pHash: pHash,
                to: to,
                txIndex: txIndex,
                txid: txid
            )
            
            let hash: String
            do {
                hash = try mintTx.hash().base64urlEncodedString()
            } catch {
                return .error(error)
            }
            
            return rpcClient.submitTxMint(hash: hash, input: mintTx)
                .map {_ in hash}
        }
        
        func mint(signer: Data) -> Single<String> {
            guard let txHash = state.txHash else {
                return .error(Error("txHash not found"))
            }
            return rpcClient.queryMint(txHash: txHash)
                .flatMap { [weak self] res in
                    guard let self = self else {throw Error.unknown}
                    return self.chain.submitMint(
                        address: self.session.destinationAddress,
                        signer: signer,
                        responceQueryMint: res
                    )
                }
        }
    }
}

extension RenVM.LockAndMint {
    public struct State {
        public var gHash: Data?
        public var gPubKey: Data?
        public var sendTo: Data? // PublicKey
        public var txid: Data?
        public var nHash: Data?
        public var pHash: Data?
        public var txHash: String?
        public var txIndex: String?
        public var amount: String?
    }
    
    public struct Session {
        init(
            destinationAddress: Data,
            nonce: String? = nil,
            sessionDay: Long = Long(Date().timeIntervalSince1970 / 1000 / 60 / 60 / 24),
            expiryTimeInDays: Long = 3,
            gatewayAddress: Data = Data()
        ) {
            self.destinationAddress = destinationAddress
            self.nonce = nonce ?? generateNonce(sessionDay: sessionDay)
            self.createdAt = sessionDay
            self.expiryTime = (sessionDay + 3) * 60 * 60 * 24 * 1000
            self.gatewayAddress = gatewayAddress
        }
        
        public private(set) var destinationAddress: Data
        public private(set) var nonce: String
        public private(set) var createdAt: Long
        public private(set) var expiryTime: Long
        public internal(set) var gatewayAddress: Data
        
    }
}

private func generateNonce(sessionDay: Long) -> String {
    let string = String(repeating: " ", count: 28) + sessionDay.hexString
    let data = string.getBytes() ?? Data()
    return data.hexString
}

private func reverseHex(src: String) -> String {
    var newStr = Array(src)
    for i in stride(from: 0, to: src.count / 2, by: 2) {
        newStr.swapAt(i, newStr.count - i - 2)
        newStr.swapAt(i + 1, newStr.count - i - 1)
    }
    return String(newStr)
}

private extension Long {
    var hexString: String {
        String(self, radix: 16, uppercase: false)
    }
}

private extension String {
    func getBytes() -> Data? {
        data(using: .utf8)
    }
}