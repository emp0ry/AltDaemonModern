//
//  DaemonRequestHandler.swift
//  AltDaemon
//
//  Created by Riley Testut on 6/1/20.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation

typealias DaemonConnectionManager = ConnectionManager<DaemonRequestHandler>

private final class DeferredAltStoreInstaller
{
    static let shared = DeferredAltStoreInstaller()

    // Give App Intents enough time to return their result to Shortcuts before
    // replacing AltStore terminates the process that hosts the intent.
    private let installationDelay: TimeInterval = 5
    private let staleFileAge: TimeInterval = 24 * 60 * 60
    private let fileManager = FileManager.default
    private let stagingQueue = DispatchQueue(label: "io.altstore.AltDaemon.selfInstallStaging", qos: .userInitiated)

    private var stagingDirectory: URL {
        return self.fileManager.temporaryDirectory.appendingPathComponent("io.altstore.altdaemon-staged-installs", isDirectory: true)
    }

    private init() {}

    func stage(_ sourceURL: URL) throws -> URL
    {
        return try self.stagingQueue.sync {
            let resourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true, (resourceValues.fileSize ?? 0) > 0 else {
                throw ALTServerError(.invalidRequest)
            }

            try self.fileManager.createDirectory(at: self.stagingDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: NSNumber(value: 0o700)])
            self.removeStaleFiles()

            let destinationURL = self.stagingDirectory
                .appendingPathComponent("AltStore-\(UUID().uuidString)")
                .appendingPathExtension("ipa")
            try self.fileManager.copyItem(at: sourceURL, to: destinationURL)

            let stagedValues = try destinationURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard stagedValues.isRegularFile == true,
                  stagedValues.fileSize == resourceValues.fileSize
            else {
                try? self.fileManager.removeItem(at: destinationURL)
                throw ALTServerError(.invalidRequest)
            }

            return destinationURL
        }
    }

    func install(_ fileURL: URL, bundleIdentifier: String, activeProfiles: Set<String>?)
    {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + self.installationDelay) {
            AppManager.shared.installApp(at: fileURL,
                                         bundleIdentifier: bundleIdentifier,
                                         activeProfiles: activeProfiles) { result in
                defer { try? self.fileManager.removeItem(at: fileURL) }

                switch result
                {
                case .success:
                    print("Installed staged AltStore self-refresh.")
                case .failure(let error):
                    print("Failed to install staged AltStore self-refresh:", error)
                }
            }
        }
    }

    private func removeStaleFiles()
    {
        guard let fileURLs = try? self.fileManager.contentsOfDirectory(at: self.stagingDirectory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles])
        else { return }

        let staleDate = Date().addingTimeInterval(-self.staleFileAge)
        for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix("AltStore-")
        {
            let modificationDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modificationDate == nil || modificationDate! < staleDate
            {
                try? self.fileManager.removeItem(at: fileURL)
            }
        }
    }
}

private let connectionManager = ConnectionManager(requestHandler: DaemonRequestHandler(),
                                                  connectionHandlers: [XPCConnectionHandler()])

extension DaemonConnectionManager
{
    static var shared: ConnectionManager {
        return connectionManager
    }
}

struct DaemonRequestHandler: RequestHandler
{
    func handleAnisetteDataRequest(_ request: AnisetteDataRequest, for connection: Connection, completionHandler: @escaping (Result<AnisetteDataResponse, Error>) -> Void)
    {
        Task {
            do
            {
                let anisetteData = try await AnisetteDataManager.shared.requestAnisetteData()

                let response = AnisetteDataResponse(anisetteData: anisetteData)
                completionHandler(.success(response))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func handlePrepareAppRequest(_ request: PrepareAppRequest, for connection: Connection, completionHandler: @escaping (Result<InstallationProgressResponse, Error>) -> Void)
    {
        guard let fileURL = request.fileURL else { return completionHandler(.failure(ALTServerError(.invalidRequest))) }
        
        print("Awaiting begin installation request...")
        
        connection.receiveRequest() { (result) in
            print("Received begin installation request with result:", result)
            
            do
            {
                guard case .beginInstallation(let request) = try result.get() else { throw ALTServerError(.unknownRequest) }
                guard let bundleIdentifier = request.bundleIdentifier else { throw ALTServerError(.invalidRequest) }

                if isAltStoreBundleIdentifier(bundleIdentifier)
                {
                    // Installing AltStore terminates the process hosting its App Intent. Copy
                    // the IPA before acknowledging the handoff because AltStore deletes its
                    // temporary IPA as soon as it receives the final progress response.
                    let stagedFileURL = try DeferredAltStoreInstaller.shared.stage(fileURL)
                    completionHandler(.success(InstallationProgressResponse(progress: 1.0)))
                    DeferredAltStoreInstaller.shared.install(stagedFileURL,
                                                             bundleIdentifier: bundleIdentifier,
                                                             activeProfiles: request.activeProfiles)
                    return
                }
                
                AppManager.shared.installApp(at: fileURL, bundleIdentifier: bundleIdentifier, activeProfiles: request.activeProfiles) { (result) in
                    let result = result.map { InstallationProgressResponse(progress: 1.0) }
                    print("Installed app with result:", result)
                    
                    completionHandler(result)
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func handleInstallProvisioningProfilesRequest(_ request: InstallProvisioningProfilesRequest, for connection: Connection,
                                                  completionHandler: @escaping (Result<InstallProvisioningProfilesResponse, Error>) -> Void)
    {
        AppManager.shared.install(request.provisioningProfiles, activeProfiles: request.activeProfiles) { (result) in
            switch result
            {
            case .failure(let error):
                print("Failed to install profiles \(request.provisioningProfiles.map { $0.bundleIdentifier }):", error)
                completionHandler(.failure(error))
                
            case .success:
                print("Installed profiles:", request.provisioningProfiles.map { $0.bundleIdentifier })
                
                let response = InstallProvisioningProfilesResponse()
                completionHandler(.success(response))
            }
        }
    }
    
    func handleRemoveProvisioningProfilesRequest(_ request: RemoveProvisioningProfilesRequest, for connection: Connection,
                                                 completionHandler: @escaping (Result<RemoveProvisioningProfilesResponse, Error>) -> Void)
    {
        AppManager.shared.removeProvisioningProfiles(forBundleIdentifiers: request.bundleIdentifiers) { (result) in
            switch result
            {
            case .failure(let error):
                print("Failed to remove profiles \(request.bundleIdentifiers):", error)
                completionHandler(.failure(error))
                
            case .success:
                print("Removed profiles:", request.bundleIdentifiers)
                
                let response = RemoveProvisioningProfilesResponse()
                completionHandler(.success(response))
            }
        }
    }
    
    func handleRemoveAppRequest(_ request: RemoveAppRequest, for connection: Connection, completionHandler: @escaping (Result<RemoveAppResponse, Error>) -> Void)
    {
        AppManager.shared.removeApp(forBundleIdentifier: request.bundleIdentifier) { (result) in
            switch result
            {
            case .failure(let error):
                print("Failed to remove app \(request.bundleIdentifier):", error)
                completionHandler(.failure(error))
                
            case .success:
                print("Removed app:", request.bundleIdentifier)
                
                let response = RemoveAppResponse()
                completionHandler(.success(response))
            }
        }
    }

    func handleEnableUnsignedCodeExecutionRequest(_ request: EnableUnsignedCodeExecutionRequest, for connection: Connection, completionHandler: @escaping (Result<EnableUnsignedCodeExecutionResponse, Error>) -> Void)
    {
        // AltDaemon installs already-signed applications and does not provide AltJIT's
        // developer-disk-image service.
        completionHandler(.failure(ALTServerError(.unknownRequest)))
    }
}
