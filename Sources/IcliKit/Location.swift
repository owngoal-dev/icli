import Foundation
import IcliPrivate
import IcliSystem

/// A bridge result, with any error reported as `unavailable`: each one means
/// locationd cannot simulate or report a location here.
private func decodeLocation(_ raw: String?) throws -> [String: Any] {
    do {
        return try decodeBridgeJSON(raw, "location response")
    } catch let IcliError.failed(message) {
        throw IcliError.unavailable(message)
    }
}

private func readLocation(timeout: Double, matching target: (Double, Double)? = nil) throws -> [String: Any] {
    try decodeLocation(takeCString(icli_location_read_json(timeout, target != nil, target?.0 ?? 0, target?.1 ?? 0)))
}

/// Makes locationd report a fixed simulated location to every client until
/// `clearSimulatedLocation()` runs. The simulation stays on after this process
/// exits. A nil speed or course is reported as unknown (-1).
public func simulateLocation(
    latitude: Double,
    longitude: Double,
    altitude: Double = 0,
    horizontalAccuracy: Double = 5,
    verticalAccuracy: Double = 5,
    speed: Double? = nil,
    course: Double? = nil
) throws -> [String: Any] {
    guard latitude.isFinite, (-90 ... 90).contains(latitude) else {
        throw IcliError.failed("latitude must be between -90 and 90")
    }
    guard longitude.isFinite, (-180 ... 180).contains(longitude) else {
        throw IcliError.failed("longitude must be between -180 and 180")
    }
    guard altitude.isFinite, abs(altitude) <= 100_000 else {
        throw IcliError.failed("altitude must be between -100000 and 100000 metres")
    }
    guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else {
        throw IcliError.failed("horizontal accuracy must be 0 or more metres")
    }
    guard verticalAccuracy.isFinite, verticalAccuracy >= 0 else {
        throw IcliError.failed("vertical accuracy must be 0 or more metres")
    }
    if let speed {
        guard speed.isFinite, speed >= 0 else { throw IcliError.failed("speed must be 0 or more metres per second") }
    }
    if let course {
        guard course.isFinite, (0 ..< 360).contains(course) else {
            throw IcliError.failed("course must be at least 0 and less than 360 degrees")
        }
    }
    _ = try decodeLocation(takeCString(icli_location_simulate_json(
        latitude,
        longitude,
        altitude,
        horizontalAccuracy,
        verticalAccuracy,
        speed ?? -1,
        course ?? -1
    )))
    // locationd accepts the request without a reply, and ignores it without
    // the simulation entitlement, so only a read-back proves it took effect.
    let reported: [String: Any]
    do {
        reported = try readLocation(timeout: 5, matching: (latitude, longitude))
    } catch {
        _ = try? clearSimulatedLocation()
        throw error
    }
    guard reported["fresh"] as? Bool == true, reported["simulated"] as? Bool == true else {
        _ = try? clearSimulatedLocation()
        throw IcliError.unavailable("locationd did not apply the simulated location")
    }
    return ["simulating": true, "location": reported]
}

/// Stops the simulation so locationd returns to real fixes, and confirms it
/// no longer refreshes the simulated one. Until the next real fix, locationd
/// keeps handing out the last simulated location as a stale reading; when
/// that location is far from the real one, a Wi-Fi-only device can reject
/// real fixes for about 15 minutes.
public func clearSimulatedLocation() throws -> [String: Any] {
    _ = try decodeLocation(takeCString(icli_location_clear_json()))
    // locationd stops asynchronously and can still stamp one more simulated fix.
    let deadline = Date().addingTimeInterval(6)
    repeat {
        Thread.sleep(forTimeInterval: 1.5)
        // Without a readable location there is nothing left to confirm.
        guard let reading = try? readLocation(timeout: 1.5) else { return ["simulating": false] }
        if reading["fresh"] as? Bool != true || reading["simulated"] as? Bool != true {
            return ["simulating": false, "location": reading]
        }
    } while Date() < deadline
    throw IcliError.failed("locationd still reports a fresh simulated location")
}

/// The location CoreLocation reports to a client, read as a System Services
/// location bundle so no permission prompt is needed. Waits up to `timeout`
/// seconds for a fresh fix; otherwise returns the last known location with
/// `fresh` false. `simulated` is CoreLocation's own source flag.
public func currentLocation(timeout: Double = 10) throws -> [String: Any] {
    guard timeout.isFinite, timeout > 0, timeout <= 300 else {
        throw IcliError.failed("timeout must be more than 0 and at most 300 seconds")
    }
    return try readLocation(timeout: timeout)
}
