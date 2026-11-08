import IcliPrivate

/// A trusted active display's point geometry, independent of capture pixels.
public struct InterfaceGeometry: Sendable {
    public let width: Double
    public let height: Double
    public let referenceWidth: Double
    public let referenceHeight: Double
    public let scale: Double
    public let orientation: Int

    /// Orientation uses IcliKit's clockwise degrees: 0, 90, 180 or 270.
    /// Reference dimensions describe the fixed digitizer and AX coordinate
    /// space. Upright dimensions must match them after that rotation.
    public init(width: Double, height: Double, referenceWidth: Double, referenceHeight: Double, scale: Double, orientation: Int) throws {
        self.width = width
        self.height = height
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.scale = scale
        self.orientation = orientation
        guard [0, 90, 180, 270].contains(orientation), icli_interface_geometry_valid(bridgeValue) else {
            throw IcliError.failed("interface geometry needs finite positive dimensions and scale, a cardinal orientation, and matching upright and reference dimensions")
        }
    }

    fileprivate var bridgeValue: IcliInterfaceGeometry {
        IcliInterfaceGeometry(width: width, height: height, reference_width: referenceWidth,
                              reference_height: referenceHeight, scale: scale, orientation: Int32(orientation))
    }
}

/// Uses one immutable geometry snapshot for synchronous IcliKit operations.
/// Metrics, AX visibility and coordinate conversion use it on the calling
/// thread. Nested scopes restore their predecessor, including after a throw.
/// The scope does not propagate to other threads, queues or asynchronous tasks.
/// Capture, OCR and screen descriptions are unavailable in this scope: the
/// supplied display geometry does not identify or bind a capture source.
public func withInterfaceGeometry<T>(_ geometry: InterfaceGeometry, _ operation: () throws -> T) rethrows -> T {
    var previous = IcliInterfaceGeometry()
    let hadPrevious = icli_interface_geometry_current(&previous)
    var current = geometry.bridgeValue
    icli_interface_geometry_set(&current)
    defer {
        if hadPrevious {
            icli_interface_geometry_set(&previous)
        } else {
            icli_interface_geometry_set(nil)
        }
    }
    return try operation()
}

func requireCaptureCoordinateSpace() throws {
    guard !icli_interface_geometry_current(nil) else {
        throw IcliError.unavailable("Screen capture, OCR and screen descriptions are unavailable inside an interface geometry override because its display is not bound to the capture source.")
    }
}
