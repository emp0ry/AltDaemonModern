//
//  AnisetteDataManager.swift
//  AltDaemon
//
//  Created by Riley Testut on 6/1/20.
//  Modern anisette v3 implementation Copyright © 2026 AltDaemonModern contributors.
//

import Foundation
import CryptoKit
import Security
import Starscream

import AltSign

private enum AnisettePreferenceKey
{
    static let serverURL = "io.altstore.altdaemon.anisette.serverURL"
    static let clientInfo = "io.altstore.altdaemon.anisette.clientInfo"
    static let userAgent = "io.altstore.altdaemon.anisette.userAgent"
    static let identifier = "io.altstore.altdaemon.anisette.v3.identifier"
    static let adiPB = "io.altstore.altdaemon.anisette.v3.adiPB"
}

private enum AnisetteEnvironmentKey
{
    static let serverURL = "ALTDAEMON_ANISETTE_URL"
    static let clientInfo = "ALTDAEMON_ANISETTE_CLIENT_INFO"
    static let userAgent = "ALTDAEMON_ANISETTE_USER_AGENT"
    static let allowInsecureServer = "ALTDAEMON_ALLOW_INSECURE_ANISETTE"
    static let stateSuite = "ALTDAEMON_ANISETTE_STATE_SUITE"
}

private enum ModernAnisetteError: LocalizedError
{
    case invalidServerURL(String)
    case insecureServerURL(String)
    case randomGenerationFailed(OSStatus)
    case invalidIdentifier
    case invalidResponse(String)
    case httpError(Int, String)
    case providerError(String, String?)
    case notProvisioned
    case provisioningLimitExceeded

    var errorDescription: String?
    {
        switch self
        {
        case .invalidServerURL(let value):
            return "The anisette server URL is invalid: \(value)"

        case .insecureServerURL(let value):
            return "The anisette server must use HTTPS: \(value)"

        case .randomGenerationFailed(let status):
            return "Could not generate an anisette identifier (Security error \(status))."

        case .invalidIdentifier:
            return "The saved anisette identifier is invalid."

        case .invalidResponse(let context):
            return "Received an invalid response while \(context)."

        case .httpError(let statusCode, let context):
            return "Received HTTP \(statusCode) while \(context)."

        case .providerError(let result, let message):
            if let message = message, !message.isEmpty
            {
                return "The anisette provider returned \(result): \(message)"
            }
            return "The anisette provider returned \(result)."

        case .notProvisioned:
            return "The anisette identity is not provisioned."

        case .provisioningLimitExceeded:
            return "The anisette provisioning session exceeded its message limit."
        }
    }
}

private struct AnisetteConfiguration
{
    // Keep these in sync with the maintained client identity used by SideStore.
    // Both values can be overridden without rebuilding the daemon.
    static let defaultServerURL = "https://ani.sidestore.io"
    static let defaultClientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
    static let defaultUserAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/3594.4.19)"

    let serverURL: URL
    let clientInfo: String
    let userAgent: String
    let localUserID: String
    let deviceID: String
    let locale: Locale
    let timeZone: TimeZone

    static func load(identifierData: Data, defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AnisetteConfiguration
    {
        let serverValue = environment[AnisetteEnvironmentKey.serverURL]
            ?? defaults.string(forKey: AnisettePreferenceKey.serverURL)
            ?? self.defaultServerURL

        guard let serverURL = URL(string: serverValue), let scheme = serverURL.scheme?.lowercased(), serverURL.host != nil else
        {
            throw ModernAnisetteError.invalidServerURL(serverValue)
        }

        let allowsInsecureServer = environment[AnisetteEnvironmentKey.allowInsecureServer] == "1"
        if scheme != "https" && !(allowsInsecureServer && scheme == "http")
        {
            throw ModernAnisetteError.insecureServerURL(serverValue)
        }

        let clientInfo = environment[AnisetteEnvironmentKey.clientInfo]
            ?? defaults.string(forKey: AnisettePreferenceKey.clientInfo)
            ?? self.defaultClientInfo

        let userAgent = environment[AnisetteEnvironmentKey.userAgent]
            ?? defaults.string(forKey: AnisettePreferenceKey.userAgent)
            ?? self.defaultUserAgent

        guard identifierData.count == 16 else { throw ModernAnisetteError.invalidIdentifier }

        let identifierBytes = [UInt8](identifierData)
        let uuid = UUID(uuid: (identifierBytes[0], identifierBytes[1], identifierBytes[2], identifierBytes[3],
                               identifierBytes[4], identifierBytes[5], identifierBytes[6], identifierBytes[7],
                               identifierBytes[8], identifierBytes[9], identifierBytes[10], identifierBytes[11],
                               identifierBytes[12], identifierBytes[13], identifierBytes[14], identifierBytes[15]))

        let digest = SHA256.hash(data: identifierData)
        let localUserID = digest.map { String(format: "%02X", $0) }.joined()

        return AnisetteConfiguration(serverURL: serverURL,
                                     clientInfo: clientInfo,
                                     userAgent: userAgent,
                                     localUserID: localUserID,
                                     deviceID: uuid.uuidString.uppercased(),
                                     locale: .current,
                                     timeZone: .current)
    }
}

private struct AnisettePayload
{
    let machineID: String
    let oneTimePassword: String
    let routingInfo: UInt64
    let localUserID: String
    let deviceID: String
    let clientInfo: String
    let date: Date
    let locale: Locale
    let timeZone: TimeZone
}

private final class AnisetteStateStore
{
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil, environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        if let defaults = defaults
        {
            self.defaults = defaults
        }
        else if let suiteName = environment[AnisetteEnvironmentKey.stateSuite],
                let suiteDefaults = UserDefaults(suiteName: suiteName)
        {
            self.defaults = suiteDefaults
        }
        else
        {
            self.defaults = .standard
        }
    }

    func identifierData() throws -> Data
    {
        if let identifier = self.defaults.string(forKey: AnisettePreferenceKey.identifier),
           let data = Data(base64Encoded: identifier),
           data.count == 16
        {
            return data
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ModernAnisetteError.randomGenerationFailed(status) }

        let data = Data(bytes)
        self.defaults.set(data.base64EncodedString(), forKey: AnisettePreferenceKey.identifier)

        // A replacement identifier must never be paired with an old ADI blob.
        self.defaults.removeObject(forKey: AnisettePreferenceKey.adiPB)
        return data
    }

    var adiPB: String?
    {
        get { return self.defaults.string(forKey: AnisettePreferenceKey.adiPB) }
        set { self.defaults.set(newValue, forKey: AnisettePreferenceKey.adiPB) }
    }

    func clearProvisioning()
    {
        self.defaults.removeObject(forKey: AnisettePreferenceKey.adiPB)
    }
}

private actor ModernAnisetteV3Provider
{
    private let stateStore: AnisetteStateStore
    private let session: URLSession

    init(stateStore: AnisetteStateStore = AnisetteStateStore())
    {
        self.stateStore = stateStore

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func requestAnisetteData() async throws -> AnisettePayload
    {
        let identifierData = try self.stateStore.identifierData()
        let configuration = try AnisetteConfiguration.load(identifierData: identifierData)

        if self.stateStore.adiPB == nil
        {
            self.stateStore.adiPB = try await self.provision(identifierData: identifierData, configuration: configuration)
        }

        do
        {
            return try await self.fetchHeaders(identifierData: identifierData, configuration: configuration)
        }
        catch ModernAnisetteError.notProvisioned
        {
            // ADI state can expire or become invalid when a provider changes. Reprovision
            // once with the same stable identifier, then surface any subsequent error.
            self.stateStore.clearProvisioning()
            self.stateStore.adiPB = try await self.provision(identifierData: identifierData, configuration: configuration)
            return try await self.fetchHeaders(identifierData: identifierData, configuration: configuration)
        }
    }
}

private extension ModernAnisetteV3Provider
{
    func provision(identifierData: Data, configuration: AnisetteConfiguration) async throws -> String
    {
        let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
        var lookupRequest = self.appleRequest(url: lookupURL, configuration: configuration)
        lookupRequest.httpMethod = "GET"

        let lookupData = try await self.perform(lookupRequest, context: "looking up Apple's provisioning service")
        guard let lookup = try PropertyListSerialization.propertyList(from: lookupData, options: [], format: nil) as? [String: Any],
              let urls = lookup["urls"] as? [String: Any],
              let startValue = urls["midStartProvisioning"] as? String,
              let finishValue = urls["midFinishProvisioning"] as? String,
              let startURL = URL(string: startValue),
              let finishURL = URL(string: finishValue)
        else
        {
            throw ModernAnisetteError.invalidResponse("looking up Apple's provisioning service")
        }

        return try await self.runProvisioningSession(identifierData: identifierData,
                                                     startURL: startURL,
                                                     finishURL: finishURL,
                                                     configuration: configuration)
    }

    func runProvisioningSession(identifierData: Data, startURL: URL, finishURL: URL, configuration: AnisetteConfiguration) async throws -> String
    {
        let httpsURL = configuration.serverURL
            .appendingPathComponent("v3")
            .appendingPathComponent("provisioning_session")

        guard var components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false) else
        {
            throw ModernAnisetteError.invalidServerURL(httpsURL.absoluteString)
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let webSocketURL = components.url else
        {
            throw ModernAnisetteError.invalidServerURL(httpsURL.absoluteString)
        }

        let provisioningSession = AnisetteProvisioningWebSocketSession(
            url: webSocketURL,
            identifier: identifierData.base64EncodedString(),
            startProvisioning: { try await self.startProvisioning(at: startURL, configuration: configuration) },
            finishProvisioning: { cpim in
                try await self.finishProvisioning(cpim: cpim, at: finishURL, configuration: configuration)
            }
        )
        return try await provisioningSession.start()
    }

    func startProvisioning(at url: URL, configuration: AnisetteConfiguration) async throws -> String
    {
        let body: [String: Any] = ["Header": [String: Any](), "Request": [String: Any]()]
        var request = self.appleRequest(url: url, configuration: configuration)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        let data = try await self.perform(request, context: "starting anisette provisioning")
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let spim = self.nonEmptyString(response["spim"])
        else
        {
            throw ModernAnisetteError.invalidResponse("starting anisette provisioning")
        }
        return spim
    }

    func finishProvisioning(cpim: String, at url: URL, configuration: AnisetteConfiguration) async throws -> [String: String]
    {
        let body: [String: Any] = ["Header": [String: Any](), "Request": ["cpim": cpim]]
        var request = self.appleRequest(url: url, configuration: configuration)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        let data = try await self.perform(request, context: "finishing anisette provisioning")
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let ptm = self.nonEmptyString(response["ptm"]),
              let tk = self.nonEmptyString(response["tk"])
        else
        {
            throw ModernAnisetteError.invalidResponse("finishing anisette provisioning")
        }
        return ["ptm": ptm, "tk": tk]
    }

    func fetchHeaders(identifierData: Data, configuration: AnisetteConfiguration) async throws -> AnisettePayload
    {
        guard let adiPB = self.stateStore.adiPB else { throw ModernAnisetteError.notProvisioned }

        let url = configuration.serverURL
            .appendingPathComponent("v3")
            .appendingPathComponent("get_headers")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifierData.base64EncodedString(),
            "adi_pb": adiPB,
        ], options: [])

        let data = try await self.perform(request, context: "fetching anisette headers", retryLimit: 3)
        let json = try self.jsonDictionary(from: data, context: "fetching anisette headers")

        if let result = self.nonEmptyString(json["result"]), result.contains("Error")
        {
            let message = self.nonEmptyString(json["message"])
            if message?.contains("-45061") == true { throw ModernAnisetteError.notProvisioned }
            throw ModernAnisetteError.providerError(result, message)
        }

        guard let machineID = self.nonEmptyString(json["X-Apple-I-MD-M"]),
              let oneTimePassword = self.nonEmptyString(json["X-Apple-I-MD"]),
              let routingInfoValue = self.nonEmptyString(json["X-Apple-I-MD-RINFO"]),
              let routingInfo = UInt64(routingInfoValue)
        else
        {
            throw ModernAnisetteError.invalidResponse("fetching anisette headers")
        }

        return AnisettePayload(machineID: machineID,
                               oneTimePassword: oneTimePassword,
                               routingInfo: routingInfo,
                               localUserID: configuration.localUserID,
                               deviceID: configuration.deviceID,
                               clientInfo: configuration.clientInfo,
                               date: Date(),
                               locale: configuration.locale,
                               timeZone: configuration.timeZone)
    }
}

private extension ModernAnisetteV3Provider
{
    func appleRequest(url: URL, configuration: AnisetteConfiguration) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.setValue(configuration.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(configuration.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(self.appleDateString(Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(configuration.locale.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(configuration.timeZone.abbreviation() ?? "UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    func perform(_ request: URLRequest, context: String, retryLimit: Int = 0) async throws -> Data
    {
        var attempt = 0

        while true
        {
            do
            {
                let (data, response) = try await self.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else
                {
                    throw ModernAnisetteError.invalidResponse(context)
                }

                guard (200...299).contains(httpResponse.statusCode) else
                {
                    if attempt < retryLimit && Self.retryableHTTPStatusCodes.contains(httpResponse.statusCode)
                    {
                        attempt += 1
                        try await Self.waitBeforeRetry(attempt: attempt)
                        continue
                    }
                    throw ModernAnisetteError.httpError(httpResponse.statusCode, context)
                }

                guard data.count <= 1_048_576 else
                {
                    throw ModernAnisetteError.invalidResponse(context)
                }
                return data
            }
            catch let error as URLError
            {
                if attempt < retryLimit && Self.retryableURLErrorCodes.contains(error.code)
                {
                    attempt += 1
                    try await Self.waitBeforeRetry(attempt: attempt)
                    continue
                }
                throw error
            }
        }
    }

    static let retryableHTTPStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
    ]

    static func waitBeforeRetry(attempt: Int) async throws
    {
        let delaySeconds = min(1 << max(0, attempt - 1), 4)
        try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
    }

    func jsonDictionary(from data: Data, context: String) throws -> [String: Any]
    {
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else
        {
            throw ModernAnisetteError.invalidResponse(context)
        }
        return json
    }

    func nonEmptyString(_ value: Any?) -> String?
    {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func appleDateString(_ date: Date) -> String
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}

private final class AnisetteProvisioningWebSocketSession: WebSocketDelegate, @unchecked Sendable
{
    private let url: URL
    private let identifier: String
    private let startProvisioning: () async throws -> String
    private let finishProvisioning: (String) async throws -> [String: String]

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var socket: WebSocket?
    private var messageCount = 0

    init(url: URL,
         identifier: String,
         startProvisioning: @escaping () async throws -> String,
         finishProvisioning: @escaping (String) async throws -> [String: String])
    {
        self.url = url
        self.identifier = identifier
        self.startProvisioning = startProvisioning
        self.finishProvisioning = finishProvisioning
    }

    func start() async throws -> String
    {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()

            var request = URLRequest(url: self.url)
            request.timeoutInterval = 20

            let socket = WebSocket(request: request)
            self.socket = socket
            socket.delegate = self
            socket.connect()
        }
    }

    func didReceive(event: WebSocketEvent, client: WebSocketClient)
    {
        switch event
        {
        case .text(let string):
            self.handleText(string, client: client)

        case .binary(let data):
            guard let string = String(data: data, encoding: .utf8) else
            {
                self.fail(ModernAnisetteError.invalidResponse("reading the anisette provisioning session"), client: client)
                return
            }
            self.handleText(string, client: client)

        case .disconnected(let reason, let code):
            self.fail(ModernAnisetteError.providerError("WebSocketDisconnected", "\(reason) (code \(code))"), client: nil)

        case .error(let error):
            self.fail(error ?? ModernAnisetteError.providerError("WebSocketError", nil), client: client)

        case .peerClosed:
            self.fail(ModernAnisetteError.providerError("WebSocketPeerClosed", nil), client: nil)

        case .cancelled:
            self.fail(ModernAnisetteError.providerError("WebSocketCancelled", nil), client: nil)

        default:
            break
        }
    }

    private func handleText(_ string: String, client: WebSocketClient)
    {
        self.lock.lock()
        self.messageCount += 1
        let exceededMessageLimit = self.messageCount > 24
        self.lock.unlock()

        guard !exceededMessageLimit else
        {
            self.fail(ModernAnisetteError.provisioningLimitExceeded, client: client)
            return
        }

        do
        {
            guard let data = string.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let result = Self.nonEmptyString(json["result"])
            else
            {
                throw ModernAnisetteError.invalidResponse("reading the anisette provisioning session")
            }

            switch result
            {
            case "GiveIdentifier":
                try self.send(["identifier": self.identifier], through: client)

            case "GiveStartProvisioningData":
                Task {
                    do
                    {
                        let spim = try await self.startProvisioning()
                        try self.send(["spim": spim], through: client)
                    }
                    catch
                    {
                        self.fail(error, client: client)
                    }
                }

            case "GiveEndProvisioningData":
                guard let cpim = Self.nonEmptyString(json["cpim"]) else
                {
                    throw ModernAnisetteError.invalidResponse("finishing anisette provisioning")
                }

                Task {
                    do
                    {
                        let values = try await self.finishProvisioning(cpim)
                        try self.send(values, through: client)
                    }
                    catch
                    {
                        self.fail(error, client: client)
                    }
                }

            case "ProvisioningSuccess":
                guard let adiPB = Self.nonEmptyString(json["adi_pb"]) else
                {
                    throw ModernAnisetteError.invalidResponse("saving anisette provisioning")
                }
                self.succeed(adiPB, client: client)

            default:
                if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly"
                {
                    throw ModernAnisetteError.providerError(result, Self.nonEmptyString(json["message"]))
                }
            }
        }
        catch
        {
            self.fail(error, client: client)
        }
    }

    private func send(_ dictionary: [String: String], through client: WebSocketClient) throws
    {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        guard let string = String(data: data, encoding: .utf8) else
        {
            throw ModernAnisetteError.invalidResponse("encoding an anisette provisioning message")
        }
        client.write(string: string)
    }

    private func succeed(_ value: String, client: WebSocketClient)
    {
        let continuation = self.takeContinuation()
        client.disconnect(closeCode: 1000)
        continuation?.resume(returning: value)
    }

    private func fail(_ error: Error, client: WebSocketClient?)
    {
        let continuation = self.takeContinuation()
        client?.disconnect(closeCode: 1000)
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<String, Error>?
    {
        self.lock.lock()
        defer { self.lock.unlock() }

        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }

    private static func nonEmptyString(_ value: Any?) -> String?
    {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AnisetteDataManager
{
    static let shared = AnisetteDataManager()

    private let provider = ModernAnisetteV3Provider()

    private init() {}

    func requestAnisetteData() async throws -> ALTAnisetteData
    {
        let payload = try await self.provider.requestAnisetteData()

        return ALTAnisetteData(machineID: payload.machineID,
                               oneTimePassword: payload.oneTimePassword,
                               localUserID: payload.localUserID,
                               routingInfo: payload.routingInfo,
                               deviceUniqueIdentifier: payload.deviceID,
                               deviceSerialNumber: "0",
                               deviceDescription: payload.clientInfo,
                               date: payload.date,
                               locale: payload.locale,
                               timeZone: payload.timeZone)
    }
}
