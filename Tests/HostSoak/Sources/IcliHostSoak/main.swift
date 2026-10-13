import Darwin
import Dispatch
import Foundation
import IcliKit

// One process, many calls, worker threads: the shape of a daemon that links
// IcliKit. Each check records into one JSON report printed at the end; the
// process exits non-zero when any check fails. A crash (an Objective-C
// exception from NaN in JSON, say) shows up as the process dying instead of
// reaching the summary.

var failures: [String] = []
var report: [String: Any] = [:]

func check(_ name: String, _ condition: Bool, _ detail: Any) {
    report[name] = ["passed": condition, "detail": detail]
    if !condition {
        failures.append(name)
    }
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

/// Runs `body` on a GCD worker, as a daemon's request handler would.
func onWorker<T>(_ body: @escaping () -> T) -> T {
    var value: T?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        value = body()
        done.signal()
    }
    done.wait()
    return value!
}

func encodable(_ value: Any) -> Bool {
    JSONSerialization.isValidJSONObject(value)
        && (try? JSONSerialization.data(withJSONObject: value)) != nil
}

let iterations = Int(ProcessInfo.processInfo.environment["SOAK_ITERATIONS"] ?? "") ?? 150
let scratch = JailbreakRoot.current.scratchDirectory() + "/icli-host-soak-\(getpid())"
try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)

// 1. Screen captures: each one used to leak a display-sized image.
_ = onWorker { try? takeScreenshot(path: scratch + "/warm.jpg") }
let before = footprintMB()
let captures = onWorker { () -> Int in
    var done = 0
    for index in 0 ..< iterations {
        autoreleasepool {
            _ = screenInfo()
            _ = rotationInfo()
            let path = scratch + "/shot-\(index % 4).jpg"
            if (try? takeScreenshot(path: path)) != nil {
                done += 1
            }
        }
    }
    return done
}

let peak = footprintMB()
// The system frees each capture's surface a few seconds after the image is
// released, so a burst peaks and then settles. Before 0.7.11 it never did.
sleep(5)
let after = footprintMB()
check("capture_footprint", captures == iterations && after - before < 60, [
    "captures": captures, "before_mb": before, "peak_mb": peak, "settled_mb": after, "growth_mb": after - before,
])

// 2. Concurrent reads from eight workers.
let group = DispatchGroup()
let errors = NSMutableArray()
let calls: [(String, () throws -> Any)] = [
    ("frontmost", { frontmostApp() }),
    ("elements", { try uiElements(maxElements: 200) }),
    ("jetsam", { try jetsamSnapshot() }),
    ("services", { try listServices() }),
    ("processes", { try listProcesses(filter: nil) }),
    ("apps", { try listApps() }),
    ("brightness", { autoBrightness() as Any }),
    ("bootstrap", { JailbreakRoot.current.jbroot }),
]
let concurrentFootprint = footprintMB()
for worker in 0 ..< 8 {
    DispatchQueue.global().async(group: group) {
        for round in 0 ..< max(iterations / 5, 10) {
            autoreleasepool {
                let (name, call) = calls[(worker + round) % calls.count]
                do {
                    let value = try call()
                    if !encodable(["value": value]) {
                        errors.add("\(name): not JSON-encodable")
                    }
                } catch {
                    // An app without accessibility or a refused privilege is
                    // an answer; the process surviving is what is checked.
                    if name != "elements" {
                        errors.add("\(name): \(error)")
                    }
                }
            }
        }
    }
}

group.wait()
check("concurrent_reads", errors.count == 0, [
    "errors": Array(errors.compactMap { $0 as? String }.prefix(10)),
    "growth_mb": footprintMB() - concurrentFootprint,
])

// 3. Waits on a worker thread: the syslog capture used to spin a core.
let cpuBefore = cpuSeconds()
let syslog = onWorker { try? captureSyslog(seconds: 2, maxLines: 50) }
let syslogCPU = cpuSeconds() - cpuBefore
check("syslog_worker_wait", syslog != nil && syslogCPU < 1.0, ["cpu_seconds": syslogCPU])

// 4. Plists and preferences that hold non-finite reals.
let plistPath = scratch + "/nan.plist"
try """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>nan</key><real>nan</real><key>inf</key><real>+infinity</real>
<key>nested</key><array><real>-infinity</real><date>2026-10-03T00:00:00Z</date><data>AQI=</data></array></dict></plist>
""".write(toFile: plistPath, atomically: true, encoding: .utf8)
let plist = try readPlist(plistPath)
check("nan_plist", encodable(plist), plist)
let domain = "dev.owngoal.icli.HostSoak"
let cfDomain = domain as CFString
let cfUser = "mobile" as CFString
CFPreferencesSetValue("nan" as CFString, NSNumber(value: Double.nan), cfDomain, cfUser, kCFPreferencesAnyHost)
CFPreferencesSetValue(
    "list" as CFString,
    [NSNumber(value: Double.infinity)] as CFArray,
    cfDomain,
    cfUser,
    kCFPreferencesAnyHost
)
CFPreferencesSynchronize(cfDomain, cfUser, kCFPreferencesAnyHost)
let preference = try readPreference(domain: domain, key: nil, user: .mobile)
check("nan_preference", encodable(preference), preference)
for key in ["nan", "list"] {
    CFPreferencesSetValue(key as CFString, nil, cfDomain, cfUser, kCFPreferencesAnyHost)
}

CFPreferencesSynchronize(cfDomain, cfUser, kCFPreferencesAnyHost)

// 5. A blocking XPC request answers, or fails, within its timeout.
let start = Date()
let developer = onWorker { try? developerModeStatus() }
check("developer_mode_bounded", Date().timeIntervalSince(start) < 15, ["answered": developer != nil])

// 6. The accessibility switches go back to what they were.
// Read the switches the way icli sets them, through libAccessibility.
let accessibility = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
func switchesOn() -> [Bool] {
    ["_AXSApplicationAccessibilityEnabled", "_AXSAutomationEnabled"].map { name in
        guard let symbol = dlsym(accessibility, name) else { return false }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)()
    }
}

// A query needs an unlocked device with an app in front: Settings, which
// every device has, and then back to the home screen.
_ = try? launchApp("com.apple.Preferences")
if lockState()["locked"] as? Bool == true {
    check("accessibility_restore", true, "skipped: the device is locked")
} else {
    restoreAccessibilitySwitches()
    let initial = switchesOn()
    var queryError = ""
    do { _ = try uiElements(maxElements: 20) } catch { queryError = "\(error)" }
    let during = switchesOn()
    restoreAccessibilitySwitches()
    let restored = switchesOn()
    check("accessibility_restore", during == [true, true] && restored == initial, [
        "initial": initial, "during_query": during, "after_restore": restored, "query_error": queryError,
    ])
}

_ = try? pressButton("home")

// 7. The CLI's printer survives what JSONSerialization would throw on.
let printed = Pipe()
let savedOut = dup(STDOUT_FILENO)
dup2(printed.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
Envelope.printJSON(["value": Double.nan, "when": Date(), "bytes": Data([1])])
fflush(stdout)
dup2(savedOut, STDOUT_FILENO)
close(savedOut)
try printed.fileHandleForWriting.close()
let printedText = String(decoding: printed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
check("envelope_nan", printedText.contains("\"value\" : \"nan\""), printedText)

// Not a defer: exit() below skips top-level defers. cfprefsd writes the emptied
// domain back after a sync, so its file goes once cfprefsd has settled.
try? FileManager.default.removeItem(atPath: scratch)
sleep(1)
let preferences = "/var/mobile/Library/Preferences/\(domain).plist"
// Dopamine's cfprefsd keeps a non-Apple domain inside the jbroot.
for path in Set([preferences, JailbreakRoot.current.jbrootPath(preferences)]) {
    try? FileManager.default.removeItem(atPath: path)
}

report["iterations"] = iterations
report["failures"] = failures
report["footprint_mb"] = footprintMB()
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output + Data("\n".utf8))
exit(failures.isEmpty ? 0 : 1)
