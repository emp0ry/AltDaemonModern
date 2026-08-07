//
//  XPCConnectionHandler.swift
//  AltDaemon
//
//  Created by Riley Testut on 9/14/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import Security

class XPCConnectionHandler: NSObject, ConnectionHandler
{
    var connectionHandler: ((Connection) -> Void)?
    var disconnectionHandler: ((Connection) -> Void)?
    
    private let dispatchQueue = DispatchQueue(label: "io.altstore.XPCConnectionListener", qos: .utility)
    private let listeners = XPCConnection.machServiceNames.map { NSXPCListener.makeListener(machServiceName: $0) }
    
    deinit
    {
        self.stopListening()
    }
        
    func startListening()
    {
        for listener in self.listeners
        {
            listener.delegate = self
            listener.resume()
        }
    }
    
    func stopListening()
    {
        self.listeners.forEach { $0.suspend() }
    }
}

private extension XPCConnectionHandler
{
    func isAllowedAltStoreBundleIdentifier(_ bundleIdentifier: String) -> Bool
    {
        let canonicalIdentifier = "com.rileytestut.AltStore"
        if bundleIdentifier == canonicalIdentifier || bundleIdentifier.hasPrefix(canonicalIdentifier + ".")
        {
            return true
        }

        let components = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 5,
              components[0] == "com",
              components[2] == "com",
              components[3] == "rileytestut",
              components[4] == "AltStore"
        else { return false }

        let teamIdentifier = components[1]
        guard teamIdentifier.count == 10,
              teamIdentifier.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.uppercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
              })
        else { return false }

        // Additional components are permitted for official beta/variant bundle IDs.
        return true
    }

    func disconnect(_ connection: Connection)
    {
        connection.disconnect()
        
        self.disconnectionHandler?(connection)
    }
}

extension XPCConnectionHandler: NSXPCListenerDelegate
{
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool
    {
        let maximumPathLength = 4 * UInt32(MAXPATHLEN)
        
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(maximumPathLength))
        pathBuffer.initialize(repeating: 0, count: Int(maximumPathLength))
        defer {
            pathBuffer.deinitialize(count: Int(maximumPathLength))
            pathBuffer.deallocate()
        }
        
        guard proc_pidpath(newConnection.processIdentifier, pathBuffer, maximumPathLength) > 0 else { return false }
        
        let path = String(cString: pathBuffer)
        let fileURL = URL(fileURLWithPath: path)
                
        var unmanagedCode: Unmanaged<ALTSecStaticCode>?
        var status = SecStaticCodeCreateWithPath(fileURL as CFURL, 0, &unmanagedCode)
        guard status == errSecSuccess, let code = unmanagedCode?.takeRetainedValue() else { return false }
        
        var unmanagedSigningInfo: Unmanaged<CFDictionary>?
        status = SecCodeCopySigningInformation(code, kSecCSInternalInformation | kSecCSSigningInformation, &unmanagedSigningInfo)
        guard status == errSecSuccess, let signingInfo = unmanagedSigningInfo?.takeRetainedValue() else { return false }
        
        // Only accept connections from AltStore.
        guard
            let codeSigningInfo = signingInfo as? [String: Any],
            let bundleIdentifier = codeSigningInfo["identifier"] as? String,
            self.isAllowedAltStoreBundleIdentifier(bundleIdentifier)
        else { return false }
        
        let connection = XPCConnection(newConnection)
        newConnection.invalidationHandler = { [weak self, weak connection] in
            guard let self = self, let connection = connection else { return }
            self.disconnect(connection)
        }

        self.connectionHandler?(connection)
        
        return true
    }
}
