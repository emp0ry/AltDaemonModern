//
//  NSError+Serialization.swift
//  AltDaemon
//
//  Minimal, daemon-safe error serialization helpers used by CodableError.
//

import Foundation

extension NSError
{
    typealias UserInfoProvider = (Error, String) -> Any?

    @objc
    class func alt_setUserInfoValueProvider(forDomain domain: String, provider: UserInfoProvider?)
    {
        NSError.setUserInfoValueProvider(forDomain: domain) { error, key in
            let nsError = error as NSError

            if key == NSLocalizedDescriptionKey
            {
                if nsError.localizedFailure != nil { return nil }
                return provider?(error, key) ?? nsError.localizedFailureReason
            }

            return provider?(error, key)
        }
    }

    @objc(alt_localizedFailure)
    var localizedFailure: String?
    {
        return (self.userInfo[NSLocalizedFailureErrorKey] as? String)
            ?? (NSError.userInfoValueProvider(forDomain: self.domain)?(self, NSLocalizedFailureErrorKey) as? String)
    }

    @objc(alt_localizedDebugDescription)
    var localizedDebugDescription: String?
    {
        return (self.userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? (NSError.userInfoValueProvider(forDomain: self.domain)?(self, NSDebugDescriptionErrorKey) as? String)
    }

    func sanitizedForSerialization() -> NSError
    {
        var userInfo = self.userInfo
        userInfo[NSLocalizedDescriptionKey] = self.localizedDescription
        userInfo[NSLocalizedFailureErrorKey] = self.localizedFailure
        userInfo[NSLocalizedFailureReasonErrorKey] = self.localizedFailureReason
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = self.localizedRecoverySuggestion
        userInfo[NSDebugDescriptionErrorKey] = self.localizedDebugDescription

        userInfo = userInfo.filter { (_, value) in
            guard let secureCodable = value as? NSSecureCoding else { return false }

            switch secureCodable
            {
            case let array as NSArray:
                return array.allSatisfy { $0 is NSSecureCoding }

            case let dictionary as NSDictionary:
                return dictionary.allValues.allSatisfy { $0 is NSSecureCoding }

            default:
                return true
            }
        }

        if let underlyingError = userInfo[NSUnderlyingErrorKey] as? Error
        {
            userInfo[NSUnderlyingErrorKey] = (underlyingError as NSError).sanitizedForSerialization()
        }

        if #available(iOS 14.5, *), let underlyingErrors = userInfo[NSMultipleUnderlyingErrorsKey] as? [Error]
        {
            userInfo[NSMultipleUnderlyingErrorsKey] = underlyingErrors.map { ($0 as NSError).sanitizedForSerialization() }
        }

        return NSError(domain: self.domain, code: self.code, userInfo: userInfo)
    }
}
