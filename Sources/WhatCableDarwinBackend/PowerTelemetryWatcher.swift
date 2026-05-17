import Foundation
import IOKit
import WhatCableCore

@MainActor
public final class PowerTelemetryWatcher: ObservableObject {
    @Published public private(set) var latestSnapshot: PowerMonitorSnapshot?

    public let snapshots: AsyncStream<PowerMonitorSnapshot>

    private var continuation: AsyncStream<PowerMonitorSnapshot>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var regressionSamples: [RegressionSample] = []
    private var cachedPortKeys: [String]?

    private struct RegressionSample {
        let voltageDrop: Double
        let current: Double
    }

    public init() {
        var continuation: AsyncStream<PowerMonitorSnapshot>.Continuation?
        snapshots = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard pollTask == nil else { return }
        cachedPortKeys = Self.hpmPortKeys()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        regressionSamples.removeAll()
        cachedPortKeys = nil
        latestSnapshot = nil
    }

    public func refresh() {
        guard let dict = Self.appleSmartBatteryProperties() else { return }
        let timestamp = Date()
        let telemetry = wcDictionary(dict["PowerTelemetryData"])
        let system = PowerSample(
            timestamp: timestamp,
            systemVoltageIn: wcInt(telemetry["SystemVoltageIn"]),
            systemCurrentIn: wcInt(telemetry["SystemCurrentIn"]),
            systemPowerIn: wcInt(telemetry["SystemPowerIn"])
        )

        let portKeys = cachedPortKeys ?? []
        // PowerOutDetails has live metering but only covers USB-C ports.
        // PortControllerInfo covers all ports (including MagSafe) but only
        // has contracted/negotiated data, not live current draw.
        // Merge both: prefer PowerOutDetails where available, fill in the
        // rest from PortControllerInfo so MagSafe and other ports appear.
        var portSamples = Self.portPowerSamples(from: dict["PowerOutDetails"], portKeys: portKeys)
        let controllerSamples = Self.portPowerSamplesFromControllerInfo(dict["PortControllerInfo"], portKeys: portKeys)
        let coveredKeys = Set(portSamples.map(\.portKey))
        for sample in controllerSamples where !coveredKeys.contains(sample.portKey) {
            portSamples.append(sample)
        }

        appendRegressionSamples(from: portSamples)
        let snapshot = PowerMonitorSnapshot(
            timestamp: timestamp,
            systemSample: system,
            portSamples: portSamples,
            resistanceEstimate: resistanceEstimate()
        )
        latestSnapshot = snapshot
        continuation?.yield(snapshot)
    }

    private func appendRegressionSamples(from portSamples: [PortPowerSample]) {
        let usable = portSamples.compactMap { sample -> RegressionSample? in
            guard sample.current > 0,
                  sample.configuredVoltage > 0,
                  sample.adapterVoltage > 0,
                  sample.configuredVoltage >= sample.adapterVoltage else {
                return nil
            }
            return RegressionSample(
                voltageDrop: Double(sample.configuredVoltage - sample.adapterVoltage),
                current: Double(sample.current)
            )
        }
        regressionSamples.append(contentsOf: usable)
        if regressionSamples.count > 120 {
            regressionSamples.removeFirst(regressionSamples.count - 120)
        }
    }

    private func resistanceEstimate() -> CableResistanceEstimate? {
        let samples = regressionSamples.filter { $0.current > 0 }
        guard samples.count >= 10 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .insufficient
            )
        }

        let minCurrent = samples.map(\.current).min() ?? 0
        let maxCurrent = samples.map(\.current).max() ?? 0
        guard maxCurrent - minCurrent > 200 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .unreliable
            )
        }

        let count = Double(samples.count)
        let meanCurrent = samples.reduce(0) { $0 + $1.current } / count
        let meanDrop = samples.reduce(0) { $0 + $1.voltageDrop } / count
        let sxx = samples.reduce(0) { $0 + pow($1.current - meanCurrent, 2) }
        guard sxx > 0 else {
            return CableResistanceEstimate(
                milliohms: 0,
                sampleCount: samples.count,
                rSquared: 0,
                status: .unreliable
            )
        }

        let sxy = samples.reduce(0) { $0 + (($1.current - meanCurrent) * ($1.voltageDrop - meanDrop)) }
        let slope = sxy / sxx
        let intercept = meanDrop - slope * meanCurrent
        let total = samples.reduce(0) { $0 + pow($1.voltageDrop - meanDrop, 2) }
        let residual = samples.reduce(0) {
            let predicted = slope * $1.current + intercept
            return $0 + pow($1.voltageDrop - predicted, 2)
        }
        let rSquared = total > 0 ? max(0, 1 - residual / total) : 0
        let status: CableResistanceEstimate.Status
        if samples.count < 30 {
            status = .converging
        } else if rSquared >= 0.7 {
            status = .stable
        } else {
            status = .unreliable
        }

        return CableResistanceEstimate(
            milliohms: max(0, slope * 1000),
            sampleCount: samples.count,
            rSquared: rSquared,
            status: status
        )
    }

    private static func portPowerSamples(from value: Any?, portKeys: [String]) -> [PortPowerSample] {
        wcArray(value).enumerated().compactMap { offset, item in
            let dict = wcDictionary(item)
            guard !dict.isEmpty else { return nil }
            let rawPortIndex = wcInt(dict["PortIndex"])
            let effectiveIndex = rawPortIndex > 0 ? rawPortIndex : offset + 1
            // PowerOutDetails entries carry their own PortIndex. Match
            // against the number component of portKeys (the part after "/")
            // rather than using the array offset, because PowerOutDetails
            // order doesn't match HPM traversal order.
            // PowerOutDetails only contains USB-C ports, so default to "2/".
            let key: String
            if rawPortIndex > 0,
               let match = portKeys.first(where: { $0.hasSuffix("/\(rawPortIndex)") && !$0.hasPrefix("17/") }) {
                key = match
            } else if rawPortIndex > 0 {
                key = "2/\(rawPortIndex)"
            } else {
                key = "2/\(offset + 1)"
            }
            return PortPowerSample(
                portIndex: effectiveIndex,
                portKey: key,
                current: wcInt(dict["Current"]),
                watts: wcInt(dict["Watts"]),
                configuredVoltage: wcInt(dict["ConfiguredVoltage"]),
                configuredCurrent: wcInt(dict["ConfiguredCurrent"]),
                adapterVoltage: wcInt(dict["AdapterVoltage"]),
                vconnCurrent: wcInt(dict["VConnCurrent"]),
                vconnPower: wcInt(dict["VConnPower"]),
                filteredPower: wcInt(dict["FilteredPower"]),
                pdPowerMW: wcInt(dict["PDPowermW"]),
                vconnMaxCurrent: wcInt(dict["VConnMaxCurrent"]),
                accumulatedPower: wcInt(dict["AccumulatedPower"]),
                accumulatorCount: wcInt(dict["AccumulatorCount"]),
                accumulatorErrorCount: wcInt(dict["AccumulatorErrorCount"]),
                vconnAccumulatedPower: wcInt(dict["VConnAccumulatedPower"]),
                vconnAccumulatorCount: wcInt(dict["VConnAccumulatorCount"]),
                vconnAccumulatorErrorCount: wcInt(dict["VConnAccumulatorErrorCount"]),
                numLDCMCollisions: wcInt(dict["NumLDCMCollisions"]),
                usbSleepPoolPowerMW: wcInt(dict["USBSleepPoolPowermW"]),
                usbWakePoolPowerMW: wcInt(dict["USBWakePoolPowermW"]),
                powerState: wcInt(dict["PowerState"]),
                portType: wcInt(dict["PortType"])
            )
        }
    }

    nonisolated static func portPowerSamplesFromControllerInfo(_ value: Any?, portKeys: [String]) -> [PortPowerSample] {
        wcArray(value).enumerated().compactMap { offset, item in
            let dict = wcDictionary(item)
            guard !dict.isEmpty else { return nil }
            let maxPower = wcInt(dict["PortControllerMaxPower"])
            let rdo = UInt32(bitPattern: Int32(truncatingIfNeeded: wcInt(dict["PortControllerActiveContractRdo"])))
            let operatingCurrent = Int((rdo >> 10) & 0x3FF) * 10
            let pdoPosition = Int((rdo >> 28) & 0x7)
            guard maxPower > 0 || pdoPosition > 0 else { return nil }
            // Voltage is not recoverable from PortControllerInfo. The old code
            // synthesized one from maxPower/current and showed it as a live
            // reading, which also defeated the honest "negotiated max" card.
            // Leave configuredVoltage at 0 and flag this as a contracted
            // fallback so the UI is honest about what it does and doesn't have.
            let key = offset < portKeys.count ? portKeys[offset] : "2/\(offset + 1)"
            return PortPowerSample(
                portIndex: offset + 1,
                portKey: key,
                current: operatingCurrent,
                watts: maxPower,
                configuredVoltage: 0,
                configuredCurrent: operatingCurrent,
                adapterVoltage: 0,
                vconnCurrent: 0,
                vconnPower: 0,
                isContractedFallback: true
            )
        }
    }

    // Walks HPM port-controller services in IOKit registry order and returns
    // a portKey ("portType/portNumber") for each. The order matches the
    // PortControllerInfo array in AppleSmartBattery because both are populated
    // from the same HPM controllers in the same traversal order.
    public nonisolated static func hpmPortKeys() -> [String] {
        let classes = [
            "AppleHPMInterfaceType10",
            "AppleHPMInterfaceType11",
            "AppleHPMInterfaceType12",
            "AppleHPMInterfaceType18",
            "AppleTCControllerType10",
            "AppleTCControllerType11",
        ]
        var keys: [String] = []
        for cls in classes {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iter) }
            while case let service = IOIteratorNext(iter), service != 0 {
                defer { IOObjectRelease(service) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any] else {
                    continue
                }
                let portType = dict["PortTypeDescription"] as? String
                let isRealPort = (portType == "USB-C" || portType?.hasPrefix("MagSafe") == true)
                guard isRealPort else { continue }
                let portNumber = wcPortIndex(from: dict, service: service)
                guard portNumber != 0 else { continue }
                let rawType: Int
                if portType?.hasPrefix("MagSafe") == true {
                    rawType = 0x11
                } else {
                    rawType = (dict["PortType"] as? Int) ?? 0x2
                }
                let key = "\(rawType)/\(portNumber)"
                if !keys.contains(key) {
                    keys.append(key)
                }
            }
        }
        return keys
    }

    public nonisolated static func appleSmartBatteryProperties() -> [String: Any]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            return dict
        }
        return nil
    }
}
