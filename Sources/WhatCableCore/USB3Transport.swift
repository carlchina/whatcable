import Foundation

/// USB 3 SuperSpeed link state for one port, sourced from the
/// `IOPortTransportStateUSB3` IOKit service. These services appear
/// dynamically when a USB 3 device is connected and disappear on unplug.
///
/// The main value here is knowing the negotiated generation: Gen 1
/// (5 Gbps) vs Gen 2 (10 Gbps). Without this data the app can still
/// detect "USB3 is active" from `transportsActive`, but can only say
/// "5 Gbps or faster" instead of the precise speed.
public struct USB3Transport: Identifiable, Hashable, Sendable {
    public let id: UInt64
    /// Port correlation key matching `PowerSource.portKey`.
    /// Format: `"\(parentPortType)/\(parentPortNumber)"`.
    public let portKey: String
    /// SuperSpeed signaling generation: 1 = Gen 1 (5 Gbps), 2 = Gen 2 (10 Gbps).
    /// Nil if the IOKit property was absent or unreadable.
    public let signaling: Int?
    /// Human-readable description from IOKit, e.g. "Gen 1" or "Gen 2".
    public let signalingDescription: String?
    /// Data role as reported by the transport: "host", "device", etc.
    public let dataRole: String?

    public init(
        id: UInt64,
        portKey: String,
        signaling: Int?,
        signalingDescription: String?,
        dataRole: String?
    ) {
        self.id = id
        self.portKey = portKey
        self.signaling = signaling
        self.signalingDescription = signalingDescription
        self.dataRole = dataRole
    }

    /// User-facing label for the negotiated USB 3 speed.
    /// Returns nil when generation data is unavailable (caller should
    /// fall back to the generic "SuperSpeed USB" text).
    public var speedLabel: String? {
        guard let gen = signaling else { return nil }
        switch gen {
        case 1: return "USB 3.2 Gen 1 (5 Gbps)"
        case 2: return "USB 3.2 Gen 2 (10 Gbps)"
        default: return "USB 3.2 Gen \(gen)"
        }
    }
}
