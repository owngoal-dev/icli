import CoreFoundation
import Darwin
import Foundation
import IcliSystem

/// Whose preferences a prefs call reads or writes. `mobile` is the user the
/// device's apps and settings run as, and is the default even under sudo.
public enum PreferenceUser: String, CaseIterable {
    case mobile, root, current, any

    /// The CFPreferences user name. A named user that is the caller itself is
    /// passed as the current user, which cfprefsd serves without a lookup.
    var cfUser: CFString {
        switch self {
        case .mobile: geteuid() == 501 ? kCFPreferencesCurrentUser : "mobile" as CFString
        case .root: geteuid() == 0 ? kCFPreferencesCurrentUser : "root" as CFString
        case .current: kCFPreferencesCurrentUser
        case .any: kCFPreferencesAnyUser
        }
    }
}

/// A typed preference value, as `defaults write` takes it.
public enum PreferenceValue {
    case string(String)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    /// An array or dictionary of property-list values.
    case plist(Any)

    public static let typeNames = ["string", "int", "float", "bool", "date", "data", "json"]

    /// Parses command-line text: `data` is Base64, `date` is ISO-8601 or
    /// seconds since 1970, `json` is a JSON array or object.
    public init(text: String, type: String) throws {
        switch type {
        case "string": self = .string(text)
        case "int":
            guard let value = Int64(text) else { throw IcliError.failed("not an integer: \(text)") }
            self = .int(value)
        case "float":
            guard let value = Double(text), value.isFinite else {
                throw IcliError.failed("not a finite number: \(text)")
            }
            self = .float(value)
        case "bool":
            switch text.lowercased() {
            case "true", "yes", "1": self = .bool(true)
            case "false", "no", "0": self = .bool(false)
            default: throw IcliError.failed("not a boolean (true/false, yes/no, 1/0): \(text)")
            }
        case "date":
            if let seconds = Double(text), seconds.isFinite {
                self = .date(Date(timeIntervalSince1970: seconds))
            } else if let date = parseISO8601(text) {
                self = .date(date)
            } else {
                throw IcliError.failed("not an ISO-8601 date or epoch seconds: \(text)")
            }
        case "data":
            guard let data = Data(base64Encoded: text) else { throw IcliError.failed("data must be Base64") }
            self = .data(data)
        case "json":
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  value is [Any] || value is [String: Any],
                  PropertyListSerialization.propertyList(value, isValidFor: .binary)
            else {
                throw IcliError.failed("json must be an array or object without nulls")
            }
            self = .plist(value)
        default:
            throw IcliError.failed("type must be one of \(PreferenceValue.typeNames.joined(separator: ", "))")
        }
    }

    var propertyList: CFPropertyList {
        switch self {
        case let .string(value): value as CFString
        case let .int(value): NSNumber(value: value)
        case let .float(value): NSNumber(value: value)
        case let .bool(value): value ? kCFBooleanTrue : kCFBooleanFalse
        case let .date(value): value as NSDate
        case let .data(value): value as NSData
        case let .plist(value): value as AnyObject
        }
    }
}

/// One key, or with no key the whole domain as `{key: {value, type}}`, for a
/// domain name or an absolute path to a .plist file.
public func readPreference(domain: String, key: String?, user: PreferenceUser = .mobile) throws -> [String: Any] {
    let domain = try checkedDomain(domain)
    var result: [String: Any] = ["domain": domain, "user": user.rawValue]
    if let key {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, user.cfUser, kCFPreferencesAnyHost)
        result["key"] = key
        result["exists"] = value != nil
        let typed = value.map(describePreference) ?? ["value": NSNull(), "type": "null"]
        result.merge(typed) { $1 }
        return result
    }
    var values: [String: Any] = [:]
    if let keys = CFPreferencesCopyKeyList(domain as CFString, user.cfUser, kCFPreferencesAnyHost),
       let all = CFPreferencesCopyMultiple(keys, domain as CFString, user.cfUser, kCFPreferencesAnyHost) as? [String: Any]
    {
        values = all.mapValues { describePreference($0 as CFPropertyList) }
    }
    result["values"] = values
    result["count"] = values.count
    return result
}

/// Writes through cfprefsd, synchronizes, and returns the value read back.
public func writePreference(
    domain: String,
    key: String,
    value: PreferenceValue,
    user: PreferenceUser = .mobile,
    notify: String? = nil
) throws -> [String: Any] {
    let domain = try checkedDomain(domain)
    try checkedKey(key)
    // .plist can come from a host's own decoded JSON, not only init(text:type:).
    guard PropertyListSerialization.propertyList(value.propertyList, isValidFor: .binary) else {
        throw IcliError.failed("\(key) is not a property-list value (no nulls; dictionary keys must be strings)")
    }
    CFPreferencesSetValue(key as CFString, value.propertyList, domain as CFString, user.cfUser, kCFPreferencesAnyHost)
    try synchronize(domain, user)
    guard let stored = CFPreferencesCopyValue(key as CFString, domain as CFString, user.cfUser, kCFPreferencesAnyHost),
          CFEqual(stored, value.propertyList)
    else {
        throw IcliError.unavailable("cfprefsd did not store \(key) in \(domain) for user \(user.rawValue).")
    }
    postNotification(notify)
    var result = try readPreference(domain: domain, key: key, user: user)
    if let notify {
        result["notified"] = notify
    }
    return result
}

/// Removes one key and confirms it is gone. `removed` is false when the key
/// was not set.
public func deletePreference(
    domain: String,
    key: String,
    user: PreferenceUser = .mobile,
    notify: String? = nil
) throws -> [String: Any] {
    let domain = try checkedDomain(domain)
    try checkedKey(key)
    let existed = CFPreferencesCopyValue(key as CFString, domain as CFString, user.cfUser, kCFPreferencesAnyHost) != nil
    CFPreferencesSetValue(key as CFString, nil, domain as CFString, user.cfUser, kCFPreferencesAnyHost)
    try synchronize(domain, user)
    guard CFPreferencesCopyValue(key as CFString, domain as CFString, user.cfUser, kCFPreferencesAnyHost) == nil else {
        throw IcliError.unavailable("cfprefsd did not remove \(key) from \(domain) for user \(user.rawValue).")
    }
    postNotification(notify)
    var result: [String: Any] = [
        "domain": domain,
        "key": key,
        "user": user.rawValue,
        "removed": existed,
        "exists": false
    ]
    if let notify {
        result["notified"] = notify
    }
    return result
}

private func checkedDomain(_ domain: String) throws -> String {
    guard !domain.isEmpty, !domain.contains("\0") else { throw IcliError.failed("domain must not be empty") }
    guard domain.hasPrefix("/") else { return domain }
    guard domain.hasSuffix(".plist") else {
        throw IcliError.failed("a path domain must be an absolute path ending in .plist")
    }
    return domain
}

private func checkedKey(_ key: String) throws {
    guard !key.isEmpty, !key.contains("\0") else { throw IcliError.failed("key must not be empty") }
}

private func synchronize(_ domain: String, _ user: PreferenceUser) throws {
    guard CFPreferencesSynchronize(domain as CFString, user.cfUser, kCFPreferencesAnyHost) else {
        throw IcliError.unavailable("cfprefsd refused to synchronize \(domain) for user \(user.rawValue).")
    }
}

private func postNotification(_ name: String?) {
    guard let name, !name.isEmpty else { return }
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString),
        nil,
        nil,
        true
    )
}

private func parseISO8601(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

/// `{value, type}` with JSON-safe values: data as Base64, dates as ISO-8601.
private func describePreference(_ value: CFPropertyList) -> [String: Any] {
    let type = CFGetTypeID(value)
    switch type {
    case CFBooleanGetTypeID(): return ["value": CFBooleanGetValue((value as! CFBoolean)), "type": "bool"]
    case CFNumberGetTypeID():
        let number = value as! NSNumber
        return CFNumberIsFloatType((value as! CFNumber))
            ? ["value": number.doubleValue, "type": "float"]
            : ["value": number.int64Value, "type": "int"]
    case CFStringGetTypeID(): return ["value": value as! String, "type": "string"]
    case CFDateGetTypeID(): return ["value": formatDate(value as! Date), "type": "date"]
    case CFDataGetTypeID(): return ["value": (value as! Data).base64EncodedString(), "type": "data"]
    case CFArrayGetTypeID(): return ["value": jsonValue(value), "type": "array"]
    case CFDictionaryGetTypeID(): return ["value": jsonValue(value), "type": "dictionary"]
    default: return ["value": String(describing: value), "type": "unknown"]
    }
}

private func jsonValue(_ value: Any) -> Any {
    switch value {
    case let data as Data: data.base64EncodedString()
    case let date as Date: formatDate(date)
    case let dictionary as [String: Any]: dictionary.mapValues(jsonValue)
    case let array as [Any]: array.map(jsonValue)
    default: value
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    if date.timeIntervalSince1970.rounded() != date.timeIntervalSince1970 {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    return formatter.string(from: date)
}
