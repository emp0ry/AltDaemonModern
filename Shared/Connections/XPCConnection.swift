//
//  XPCConnection.swift
//  AltKit
//
//  Created by Riley Testut on 6/15/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation

private struct PendingXPCReceive
{
    let expectedSize: Int
    let completionHandler: (Data?, Error?) -> Void
}

@objc private protocol XPCConnectionProxy
{
    func ping(completionHandler: @escaping () -> Void)
    func receive(_ data: Data, completionHandler: @escaping (Bool, Error?) -> Void)
}

extension XPCConnection
{
    public static let unc0verMachServiceName = "cy:io.altstore.altdaemon"
    public static let odysseyMachServiceName = "lh:io.altstore.altdaemon"
    
    public static let machServiceNames = [unc0verMachServiceName, odysseyMachServiceName]
}

public class XPCConnection: NSObject, Connection
{
    public let xpcConnection: NSXPCConnection

    private let stateLock = NSLock()
    private var buffer = Data(capacity: 1024)
    private var pendingReceives: [PendingXPCReceive] = []
    private var error: Error?
    private var didDisconnect = false
    
    public init(_ xpcConnection: NSXPCConnection)
    {
        let proxyInterface = NSXPCInterface(with: XPCConnectionProxy.self)
        xpcConnection.remoteObjectInterface = proxyInterface
        xpcConnection.exportedInterface = proxyInterface

        self.xpcConnection = xpcConnection
        
        super.init()
        
        xpcConnection.interruptionHandler = { [weak self] in
            self?.failPendingReceives(with: ALTServerError(.lostConnection))
        }
                
        xpcConnection.exportedObject = self
        xpcConnection.resume()
    }

    deinit
    {
        self.disconnect()
    }
}

private extension XPCConnection
{
    func currentError() -> Error?
    {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.error
    }

    func failPendingReceives(with error: Error)
    {
        let pending: [PendingXPCReceive]

        self.stateLock.lock()
        if self.error == nil
        {
            self.error = error
        }
        pending = self.pendingReceives
        self.pendingReceives.removeAll()
        self.stateLock.unlock()

        for receive in pending
        {
            receive.completionHandler(nil, error)
        }
    }

    func takeReadyReceivesLocked() -> [(Data, (Data?, Error?) -> Void)]
    {
        var ready: [(Data, (Data?, Error?) -> Void)] = []

        while let receive = self.pendingReceives.first,
              self.buffer.count >= receive.expectedSize
        {
            self.pendingReceives.removeFirst()
            let data = Data(self.buffer.prefix(receive.expectedSize))
            self.buffer.removeFirst(receive.expectedSize)
            ready.append((data, receive.completionHandler))
        }

        return ready
    }

    func makeProxy(errorHandler: @escaping (Error) -> Void) -> XPCConnectionProxy
    {
        let proxy = self.xpcConnection.remoteObjectProxyWithErrorHandler { (error) in
            print("Error messaging remote object proxy:", error)
            self.failPendingReceives(with: error)
            errorHandler(error)
        } as! XPCConnectionProxy
        
        return proxy
    }
}

public extension XPCConnection
{
    func connect(completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        let proxy = self.makeProxy { (error) in
            completionHandler(.failure(error))
        }

        proxy.ping {
            completionHandler(.success(()))
        }
    }
    
    func disconnect()
    {
        let shouldInvalidate: Bool

        self.stateLock.lock()
        shouldInvalidate = !self.didDisconnect
        self.didDisconnect = true
        self.stateLock.unlock()

        self.failPendingReceives(with: ALTServerError(.lostConnection))
        if shouldInvalidate
        {
            self.xpcConnection.invalidate()
        }
    }
    
    func __send(_ data: Data, completionHandler: @escaping (Bool, Error?) -> Void)
    {
        if let error = self.currentError()
        {
            return completionHandler(false, error)
        }
        
        let proxy = self.makeProxy { (error) in
            completionHandler(false, error)
        }
        
        proxy.receive(data) { (success, error) in
            completionHandler(success, error)
        }
    }
    
    func __receiveData(expectedSize: Int, completionHandler: @escaping (Data?, Error?) -> Void)
    {
        guard expectedSize >= 0 else
        {
            return completionHandler(nil, ALTServerError(.invalidRequest))
        }

        var immediateResult: (Data?, Error?)?

        self.stateLock.lock()
        if let error = self.error
        {
            immediateResult = (nil, error)
        }
        else if expectedSize == 0
        {
            immediateResult = (Data(), nil)
        }
        else if self.buffer.count >= expectedSize
        {
            let data = Data(self.buffer.prefix(expectedSize))
            self.buffer.removeFirst(expectedSize)
            immediateResult = (data, nil)
        }
        else
        {
            self.pendingReceives.append(PendingXPCReceive(expectedSize: expectedSize,
                                                          completionHandler: completionHandler))
        }
        self.stateLock.unlock()

        if let result = immediateResult
        {
            completionHandler(result.0, result.1)
        }
    }
}

extension XPCConnection
{
    override public var description: String {
        return "\(self.xpcConnection.endpoint) (XPC)"
    }
}

extension XPCConnection: XPCConnectionProxy
{
    fileprivate func ping(completionHandler: @escaping () -> Void)
    {
        completionHandler()
    }
    
    fileprivate func receive(_ data: Data, completionHandler: @escaping (Bool, Error?) -> Void)
    {
        let ready: [(Data, (Data?, Error?) -> Void)]
        let connectionError: Error?

        self.stateLock.lock()
        connectionError = self.error
        if connectionError == nil
        {
            self.buffer.append(data)
            ready = self.takeReadyReceivesLocked()
        }
        else
        {
            ready = []
        }
        self.stateLock.unlock()

        guard connectionError == nil else
        {
            completionHandler(false, connectionError)
            return
        }

        completionHandler(true, nil)
        for (receivedData, receiveCompletion) in ready
        {
            receiveCompletion(receivedData, nil)
        }
    }
}
