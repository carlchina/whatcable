import Foundation
import IOKit
import WhatCableCore

/// Watches `IOPortTransportStateUSB3` services. These appear dynamically
/// when a USB 3 SuperSpeed device is connected and disappear on unplug.
/// Each service carries the negotiated signaling generation (Gen 1 / Gen 2)
/// which lets the app show the precise USB 3 speed instead of a generic
/// "5 Gbps or faster" label.
@MainActor
public final class USB3TransportWatcher: ObservableObject {
    @Published public private(set) var transports: [USB3Transport] = []

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USB3TransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in w.handleAdded(iter) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let w = Unmanaged<USB3TransportWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in w.handleRemoved(iter) }
        }

        let matching = IOServiceMatching("IOPortTransportStateUSB3")
        IOServiceAddMatchingNotification(port, kIOMatchedNotification, matching, added, selfPtr, &addedIter)
        handleAdded(addedIter)

        let matching2 = IOServiceMatching("IOPortTransportStateUSB3")
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching2, removed, selfPtr, &removedIter)
        handleRemoved(removedIter)
    }

    public func stop() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        transports.removeAll()
    }

    public func refresh() {
        transports.removeAll()
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateUSB3"), &iter) == KERN_SUCCESS {
            handleAdded(iter)
            IOObjectRelease(iter)
        }
    }

    private func handleAdded(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            if let t = makeTransport(from: service), !transports.contains(where: { $0.id == t.id }) {
                transports.append(t)
            }
            IOObjectRelease(service)
        }
    }

    private func handleRemoved(_ iter: io_iterator_t) {
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            transports.removeAll { $0.id == entryID }
            IOObjectRelease(service)
        }
    }

    private func makeTransport(from service: io_service_t) -> USB3Transport? {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let parent = Self.parentPortIdentity(from: dict)
        let portKey = "\(parent.type)/\(parent.number)"

        let signaling = (dict["SuperSpeedSignaling"] as? NSNumber)?.intValue
        let signalingDesc = dict["SuperSpeedSignalingDescription"] as? String
        let dataRole = (dict["DataRole"] as? String)
            ?? (dict["PortDataRole"] as? String)

        return USB3Transport(
            id: entryID,
            portKey: portKey,
            signaling: signaling,
            signalingDescription: signalingDesc,
            dataRole: dataRole
        )
    }

    /// Reads the parent port type and number from the service's properties.
    /// Same approach as `PowerSourceWatcher.parentPortIdentity(from:)`.
    nonisolated static func parentPortIdentity(from dict: [String: Any]) -> (type: Int, number: Int) {
        let type = (dict["ParentBuiltInPortType"] as? NSNumber)?.intValue
            ?? (dict["ParentPortType"] as? NSNumber)?.intValue
            ?? 0
        let number = (dict["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
            ?? (dict["ParentPortNumber"] as? NSNumber)?.intValue
            ?? Int(((dict["Priority"] as? NSNumber)?.uint64Value ?? 0) & 0xFF)
        return (type, number)
    }
}

extension USB3TransportWatcher {
    /// USB3 transports attached to a given port.
    public func transports(for port: USBCPort) -> [USB3Transport] {
        guard let key = port.portKey else { return [] }
        return transports.filter { $0.portKey == key }
    }
}
