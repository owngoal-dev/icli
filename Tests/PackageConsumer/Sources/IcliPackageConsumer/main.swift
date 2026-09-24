import Foundation
import IcliKit

/// This consumer imports only the public library product. No CLI entry point,
/// ArgumentParser dependency, or private bridge import is needed. The launchd
/// read APIs below come from IcliSystem, which IcliKit re-exports.
let comparison = try compareDebianVersions("1.0~beta", "1.0")
precondition(comparison["relation"] as? String == "lt")
let packages = try packageStatus("com.icli.icli")
precondition(packages["installed"] as? Bool == true)
let environment = try environmentReport()
precondition(environment["spawns_processes"] as? Bool == false)
let launchdAPIs: [Any] = [
    listServices as () throws -> [String: Any],
    disabledServiceOverrides as () throws -> [String: Any],
    serviceStatus as (String) throws -> [String: Any],
    printService as (String) throws -> [String: Any],
    startService as (String) throws -> [String: Any],
    stopService as (String) throws -> [String: Any],
    removeService as (String) throws -> [String: Any],
    signalService as (String, String) throws -> [String: Any],
    launchdEnvironment as (String) throws -> [String: Any],
    setLaunchdEnvironment as (String, String?) throws -> [String: Any],
]
precondition(launchdAPIs.count == 10)
/// The 0.6.0 device features, which vphoned will call in-process. Referencing
/// each with its full type keeps them public and their signatures stable.
let deviceFeatureAPIs: [Any] = [
    simulateLocation as (Double, Double, Double, Double, Double, Double?, Double?) throws -> [String: Any],
    clearSimulatedLocation as () throws -> [String: Any],
    currentLocation as (Double) throws -> [String: Any],
    developerModeStatus as () throws -> [String: Any],
    enableDeveloperMode as () throws -> [String: Any],
    lowPowerMode as () throws -> [String: Any],
    setLowPowerMode as (Bool) throws -> [String: Any],
    clipboardInfo as (String?) throws -> [String: Any],
    clipboardImagePNG as () throws -> Data?,
    setClipboardImage as (Data) throws -> [String: Any],
    readPreference as (String, String?, PreferenceUser) throws -> [String: Any],
    writePreference as (String, String, PreferenceValue, PreferenceUser, String?) throws -> [String: Any],
    deletePreference as (String, String, PreferenceUser, String?) throws -> [String: Any],
    touch as (TouchPhase, Double, Double, Bool) throws -> [String: Any],
    touchSequence as ([TouchEvent], Bool) throws -> [String: Any],
    hidEvent as (Int, Int, Bool) throws -> [String: Any],
    hidPress as (Int, Int) throws -> [String: Any],
    installIPAInContainer as (String, AppRegistrationType) throws -> [String: Any],
    installIPAInContainer as (String, AppRegistrationType, (String) throws -> Void) throws -> [String: Any],
    installPackage as (String, Bool, AppRegistrationType) throws -> [String: Any],
    uninstallApp as (String, Bool) throws -> [String: Any],
]
precondition(deviceFeatureAPIs.count == 21)
let keychainMetadataAPI: (String?) throws -> [String: Any] = listKeychainDatabaseMetadata
_ = keychainMetadataAPI
// A host builds these values from its own protocol, not from command-line text.
let events = [TouchEvent(phase: .down, x: 0.5, y: 0.5, delayMS: 50), TouchEvent(phase: .up, x: 0.5, y: 0.5)]
let decoded = try TouchEvent.list(fromJSON: #"[{"phase":"down","x":1,"y":2}]"#)
precondition(decoded.first?.phase == events.first?.phase)
precondition(AppRegistrationType(rawValue: "system") == .system)
// Only reads run on the device. The write must be refused before cfprefsd sees it.
let developerMode = try developerModeStatus()
let lowPower = try lowPowerMode()
var rejectsNonPropertyList = false
do {
    _ = try writePreference(domain: "dev.owngoal.icli.PackageConsumer", key: "null", value: .plist([NSNull()]))
} catch {
    rejectsNonPropertyList = true
}
precondition(rejectsNonPropertyList)
let report: [String: Any] = [
    "library": "IcliKit",
    "comparison": comparison,
    "installed_version": packages["version"] ?? "",
    "layout": environment["layout"] ?? "",
    "launchd_api_count": launchdAPIs.count,
    "device_feature_api_count": deviceFeatureAPIs.count,
    "developer_mode": developerMode,
    "low_power_mode": lowPower,
]
try print(String(decoding: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
