//
//  InternalAuthenticatorGetAsesrtionSession.swift
//  WebAuthnKit
//
//  Created by Lyo Kato on 2018/11/20.
//  Copyright © 2018 Lyo Kato. All rights reserved.
//

import Foundation
import PromiseKit
import CryptoSwift

public class InternalAuthenticatorGetAssertionSession : AuthenticatorGetAssertionSession {
    
    public weak var delegate : AuthenticatorGetAssertionSessionDelegate?
    
    private let setting: InternalAuthenticatorSetting
    
    public var attachment: AuthenticatorAttachment {
        get {
            return self.setting.attachment
        }
    }
    
    public var transport: AuthenticatorTransport {
        get {
            return self.setting.transport
        }
    }
    
    private let ui:                UserConsentUI
    private let credentialStore:   CredentialStore
    private let keySupportChooser: KeySupportChooser
    
    private var started = false
    private var stopped = false
    
    init(
        setting:             InternalAuthenticatorSetting,
        ui:                  UserConsentUI,
        credentialStore:     CredentialStore,
        keySupportChooser:   KeySupportChooser
    ) {
        self.setting             = setting
        self.ui                  = ui
        self.credentialStore     = credentialStore
        self.keySupportChooser   = keySupportChooser
    }
    
    public func start() {
        WAKLogger.debug("<GetAssertionSession> start")
        if self.stopped {
            WAKLogger.debug("<GetAssertionSession> alread stopped")
            return
        }
        if self.started {
            WAKLogger.debug("<GetAssertionSession> alread started")
            return
        }
        self.started = true
        self.delegate?.authenticatorSessionDidBecomeAvailable(session: self)
    }
    
    public func canPerformUserVerification() -> Bool {
        return self.setting.allowUserVerification
    }
    
    // 6.3.4 authenticatorCancel Operation
    public func cancel() {
        WAKLogger.debug("<GetAssertionSession> cancel")
        if self.stopped {
            WAKLogger.debug("<GetAssertionSession> already stopped")
            return
        }
        if self.ui.opened {
            WAKLogger.debug("<GetAssertionSession> during user interaction")
           self.ui.cancel()
        } else {
            WAKLogger.debug("<GetAssertionSession> stop by clientCancelled")
            self.stop(by: .clientCancelled)
        }
    }
    
    private func stop(by reason: AuthenticatorError) {
        WAKLogger.debug("<GetAssertionSession> stop")
        if !self.started {
            WAKLogger.debug("<GetAssertionSession> not started")
            return
        }
        if self.stopped  {
            WAKLogger.debug("<GetAssertionSession> already stopped")
            return
        }
        self.stopped = true
        self.delegate?.authenticatorSessionDidStopOperation(
            session: self,
            reason:  reason
        )
    }
    
    private func completed() {
        self.stopped = true
    }
    
    public func getAssertion(
        rpId:                          String,
        hash:                          [UInt8],
        allowCredentialDescriptorList: [PublicKeyCredentialDescriptor],
        requireUserPresence:           Bool,
        requireUserVerification:       Bool
        // extensions: [] CBOR MAP
        ) {
        
        WAKLogger.debug("<GetAssertionSession> get assertion")
        
        let credSources =
            self.gatherCredentialSources(
                rpId:                          rpId,
                allowCredentialDescriptorList: allowCredentialDescriptorList
        )
        
        if credSources.isEmpty {
            WAKLogger.debug("<GetAssertion> not found allowable credential source, stop session")
            self.stop(by: .notAllowedError)
            return
        }
        
        firstly {
            
            self.ui.requestUserSelection(
                sources:             credSources,
                requireVerification: requireUserVerification
            )
            
            }.done { cred in
                
                var newSignCount: UInt32 = 0
                
                var copiedCred = cred
                copiedCred.signCount = cred.signCount + self.setting.counterStep
                newSignCount = copiedCred.signCount
                if !self.credentialStore.saveCredentialSource(copiedCred) {
                    self.stop(by: .unknownError)
                    return
                }

                let extensions = SimpleOrderedDictionary<String>()
                
                let authenticatorData = AuthenticatorData(
                    rpIdHash:               rpId.bytes.sha256(),
                    userPresent:            requireUserPresence,
                    userVerified:           requireUserVerification,
                    signCount:              newSignCount,
                    attestedCredentialData: nil,
                    extensions:             extensions
                )
                
                let authenticatorDataBytes = authenticatorData.toBytes()
                
                var data = authenticatorDataBytes
                data.append(contentsOf: hash)
                
                guard let alg = COSEAlgorithmIdentifier.fromInt(cred.alg) else {
                    WAKLogger.debug("<GetAssertion> insufficient capability (alg), stop session")
                    self.stop(by: .notSupportedError)
                    return
                }

                guard let keySupport =
                    self.keySupportChooser.choose([alg]) else {
                        WAKLogger.debug("<GetAssertion> insufficient capability (alg), stop session")
                        self.stop(by: .notSupportedError)
                        return
                }
                
                guard let signature = keySupport.sign(data: data, label: cred.keyLabel) else {
                    self.stop(by: .unknownError)
                    return
                }
                
                var assertion = AuthenticatorAssertionResult(
                    authenticatorData: authenticatorDataBytes,
                    signature:         signature
                )
                
                assertion.userHandle = cred.userHandle
                
                if allowCredentialDescriptorList.count != 1 {
                    assertion.credentailId = cred.id
                }
                
                self.completed()
                self.delegate?.authenticatorSessionDidDiscoverCredential(
                    session:   self,
                    assertion: assertion
                )
                
            }.catch { error in
                switch error {
                case AuthenticatorError.notAllowedError:
                    self.stop(by: .notAllowedError)
                    return
                default:
                    self.stop(by: .unknownError)
                    return
                }
        }
        
    }
    
    private func gatherCredentialSources(
        rpId: String,
        allowCredentialDescriptorList: [PublicKeyCredentialDescriptor]
        ) -> [PublicKeyCredentialSource] {
        
        if allowCredentialDescriptorList.isEmpty {
            return self.credentialStore.loadAllCredentialSources(rpId: rpId)
        } else {
            return allowCredentialDescriptorList.compactMap {
                return self.credentialStore.lookupCredentialSource(
                    rpId:         rpId,
                    credentialId: $0.id
                )
            }
        }
    }

}
