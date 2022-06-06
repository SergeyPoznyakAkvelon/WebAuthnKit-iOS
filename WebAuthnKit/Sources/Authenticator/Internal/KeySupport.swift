//
//  KeySupport.swift
//  WebAuthnKit
//
//  Created by Lyo Kato on 2018/11/20.
//  Copyright © 2018 Lyo Kato. All rights reserved.
//

import Foundation
import CryptoKit
import KeychainAccess
import LocalAuthentication

public protocol KeySupport {
    var selectedAlg: COSEAlgorithmIdentifier { get }
    func createKeyPair(label: String) -> Optional<COSEKey>
    func sign(data: [UInt8], label: String, context: LAContext) -> Optional<[UInt8]>
}

public class KeySupportChooser {
    
    public init() {}

    public func choose(_ requestedAlgorithms: [COSEAlgorithmIdentifier])
        -> Optional<KeySupport> {
        WAKLogger.debug("<KeySupportChooser> choose")

        for alg in requestedAlgorithms {
            switch alg {
            case COSEAlgorithmIdentifier.es256:
                return ECDSAKeySupport(alg: .es256)
            default:
                WAKLogger.debug("<KeySupportChooser> currently this algorithm not supported")
                return nil
            }
        }

        return nil
    }
}

public class ECDSAKeySupport : KeySupport {
    
    public let selectedAlg: COSEAlgorithmIdentifier
    
    init(alg: COSEAlgorithmIdentifier) {
        self.selectedAlg = alg
    }
    
    private func getExistingKey(label: String) -> P256.Signing.PrivateKey? {
        let keychain = KeychainAccess.Keychain(service: label)
        
        do {
            if let privateKeyData = try keychain.getData("private") {
                return try CryptoKit.P256.Signing.PrivateKey.init(rawRepresentation: privateKeyData.bytes)
            }
        } catch let err {
            WAKLogger.debug("Failed to get key due to error \(err)")
        }
        
        return nil
    }
    
    private func createKey(label: String) throws -> P256.Signing.PrivateKey {
        if let key = getExistingKey(label: label) {
            return key
        } else {
            let keychain = KeychainAccess.Keychain(service: label)
            let newKey = CryptoKit.P256.Signing.PrivateKey()
            try keychain.set(newKey.rawRepresentation, key: "private")
            
            return newKey
        }
    }
    
    public func sign(data: [UInt8], label: String, context: LAContext) -> Optional<[UInt8]> {
        do {
            let key = try self.createKey(label: label)
            let signature = try key.signature(for: Data(bytes: data))
            return signature.rawRepresentation.bytes
        } catch let error {
            WAKLogger.debug("<ECDSAKeySupport> failed to sign: \(error)")
            return nil
        }
    }
    
    public func createKeyPair(label: String) -> Optional<COSEKey> {
        WAKLogger.debug("<ECDSAKeySupport> createKeyPair")
        do {
            let pair = try self.createKey(label: label)
            let publicKey = pair.publicKey.derRepresentation.bytes
            if publicKey.count != 91 {
                WAKLogger.debug("<ECDSAKeySupport> length of pubKey should be 91: \(publicKey.count)")
                return nil
            }
            
            let x = Array(publicKey[27..<59])
            let y = Array(publicKey[59..<91])
            
            let key: COSEKey = COSEKeyEC2(
                alg: self.selectedAlg.rawValue,
                crv: COSEKeyCurveType.p256,
                xCoord: x,
                yCoord: y
            )
            return key
            
        } catch let error {
            WAKLogger.debug("<ECDSAKeySupport> failed to create key-pair: \(error)")
            return nil
        }
    }
}
