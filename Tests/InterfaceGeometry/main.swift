import Dispatch
import Foundation
import IcliPrivate

// The geometry API needs only these error cases from IcliSystem. Its full bridge
// imports Darwin, so keep the host-side harness independent of that target.
enum IcliError: Error {
    case failed(String)
    case unavailable(String)
}

enum ExpectedError: Error {
    case thrown
}

func close(_ actual: Double, _ expected: Double) {
    precondition(abs(actual - expected) < 1e-9, "expected \(expected), got \(actual)")
}

func current() -> IcliInterfaceGeometry {
    var geometry = IcliInterfaceGeometry()
    precondition(icli_interface_geometry_current(&geometry), "missing scoped geometry")
    return geometry
}

func absent() {
    precondition(!icli_interface_geometry_current(nil), "geometry leaked beyond its scope")
}

func geometry(_ orientation: Int = 90, referenceWidth: Double = 669, referenceHeight: Double = 951) throws -> InterfaceGeometry {
    let sideways = orientation == 90 || orientation == 270
    return try InterfaceGeometry(width: sideways ? referenceHeight : referenceWidth,
                                 height: sideways ? referenceWidth : referenceHeight,
                                 referenceWidth: referenceWidth, referenceHeight: referenceHeight,
                                 scale: 3, orientation: orientation)
}

func rotations() throws {
    let expected = [(0, 0.25, 0.75), (90, 0.75, 0.75), (180, 0.75, 0.25), (270, 0.25, 0.25)]
    for (orientation, expectedX, expectedY) in expected {
        let snapshot = try geometry(orientation)
        withInterfaceGeometry(snapshot) {
            let active = current()
            let metrics = icli_interface_geometry_metrics(active)
            close(metrics.width, snapshot.width)
            close(metrics.height, snapshot.height)
            close(metrics.scale, 3)
            precondition(metrics.orientation == Int32(orientation))
            var nx = 0.0, ny = 0.0
            icli_interface_geometry_point_to_digitizer(active, snapshot.width * 0.25, snapshot.height * 0.75, &nx, &ny)
            close(nx, expectedX)
            close(ny, expectedY)
            for (x, y) in [(0.0, 0.0), (snapshot.width, 0), (0, snapshot.height), (snapshot.width, snapshot.height), (220.833, 419.333)] {
                var fx = 0.0, fy = 0.0, uprightX = 0.0, uprightY = 0.0
                icli_interface_geometry_point_to_fixed(active, x, y, &fx, &fy)
                icli_interface_geometry_fixed_to_point(active, fx, fy, &uprightX, &uprightY)
                close(uprightX, x)
                close(uprightY, y)
            }
        }
        absent()
    }
    // The active interface is larger than the capture surface. Its points
    // normalize against the active reference bounds, independent of pixels.
    withInterfaceGeometry(try geometry()) {
        var nx = 0.0, ny = 0.0
        icli_interface_geometry_point_to_digitizer(current(), 220.833, 419.333, &nx, &ny)
        close(nx, 419.333 / 669)
        close(ny, (951 - 220.833) / 951)
    }
}

func invalid() throws {
    let badDimensions = [0.0, -1, Double.nan, Double.infinity, -Double.infinity]
    for value in badDimensions {
        for index in 0 ..< 5 {
            var dimensions = [951.0, 669, 669, 951, 3]
            dimensions[index] = value
            do {
                _ = try InterfaceGeometry(width: dimensions[0], height: dimensions[1], referenceWidth: dimensions[2],
                                          referenceHeight: dimensions[3], scale: dimensions[4], orientation: 90)
                preconditionFailure("accepted invalid geometry")
            } catch IcliError.failed {}
        }
    }
    for orientation in [-90, 1, 360, Int.max, Int.min] {
        do {
            _ = try InterfaceGeometry(width: 951, height: 669, referenceWidth: 669, referenceHeight: 951, scale: 3, orientation: orientation)
            preconditionFailure("accepted noncardinal orientation")
        } catch IcliError.failed {}
    }
    do {
        _ = try InterfaceGeometry(width: 678, height: 466, referenceWidth: 669, referenceHeight: 951, scale: 3, orientation: 90)
        preconditionFailure("accepted mismatched upright and reference bounds")
    } catch IcliError.failed {}

    withInterfaceGeometry(try geometry()) {
        var invalid = current()
        invalid.width = 678
        precondition(!icli_interface_geometry_set(&invalid))
        close(current().width, 951)
    }
}

func nestedAndThrowing() throws {
    absent()
    let outer = try geometry()
    let inner = try geometry(0, referenceWidth: 320, referenceHeight: 480)
    let value = withInterfaceGeometry(outer) {
        close(current().width, 951)
        do {
            try withInterfaceGeometry(inner) {
                close(current().width, 320)
                throw ExpectedError.thrown
            }
            preconditionFailure("throw was swallowed")
        } catch ExpectedError.thrown {} catch { preconditionFailure("unexpected error: \(error)") }
        close(current().width, 951)
        return 42
    }
    precondition(value == 42)
    absent()
    do {
        try withInterfaceGeometry(outer) { throw ExpectedError.thrown }
        preconditionFailure("throw was swallowed")
    } catch ExpectedError.thrown {}
    absent()

    var saved = IcliInterfaceGeometry(width: 320, height: 480, reference_width: 320, reference_height: 480, scale: 2, orientation: 0)
    precondition(icli_interface_geometry_set(&saved))
    saved.width = 1 // The override owns a value copy.
    close(current().width, 320)
    withInterfaceGeometry(outer) { close(current().width, 951) }
    close(current().width, 320)
    precondition(icli_interface_geometry_set(nil))
    absent()
}

func concurrentIsolation() throws {
    let ready = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let outer = try geometry()
    withInterfaceGeometry(outer) {
        for index in 0 ..< 8 {
            group.enter()
            DispatchQueue.global().async {
                absent() // The caller's scope must not propagate to a queue.
                let width = Double(320 + index)
                let own = try! geometry(0, referenceWidth: width, referenceHeight: 480)
                withInterfaceGeometry(own) {
                    ready.signal()
                    precondition(proceed.wait(timeout: .now() + 10) == .success)
                    for _ in 0 ..< 1000 { close(current().width, width) }
                }
                absent()
                group.leave()
            }
        }
        for _ in 0 ..< 8 { precondition(ready.wait(timeout: .now() + 10) == .success) }
        close(current().width, 951)
        for _ in 0 ..< 8 { proceed.signal() }
        precondition(group.wait(timeout: .now() + 10) == .success)
        close(current().width, 951)
    }
    absent()
}

func captureGuard() throws {
    try requireCaptureCoordinateSpace()
    let supplied = try geometry()
    withInterfaceGeometry(supplied) {
        do {
            try requireCaptureCoordinateSpace()
            preconditionFailure("accepted an unbound capture coordinate space")
        } catch IcliError.unavailable {} catch { preconditionFailure("unexpected error: \(error)") }
    }
    try requireCaptureCoordinateSpace()
    // Matching point dimensions cannot establish that a different capture
    // source belongs to this display either. The API supplies no identity.
    withInterfaceGeometry(try geometry(0, referenceWidth: 320, referenceHeight: 480)) {
        do {
            try requireCaptureCoordinateSpace()
            preconditionFailure("accepted an override without a capture-source binding")
        } catch IcliError.unavailable {} catch { preconditionFailure("unexpected error: \(error)") }
    }
    try requireCaptureCoordinateSpace()
}

try rotations()
try invalid()
try nestedAndThrowing()
try concurrentIsolation()
try captureGuard()
print("interface geometry: rotations, normalization, validation, scope unwind, concurrent isolation and unbound capture guard passed")
