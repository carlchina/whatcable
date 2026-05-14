import XCTest
@testable import WhatCableCore

/// Pins the user-facing headline strings produced by PortSummary so refactors
/// of the state machine can't silently change what users see in the popover.
final class PortSummaryTests: XCTestCase {

    // MARK: - Fixtures

    private func makePort(
        connected: Bool = true,
        active: [String] = [],
        supported: [String] = [],
        superSpeed: Bool? = nil,
        emarker: Bool? = nil
    ) -> USBCPort {
        USBCPort(
            id: 1,
            serviceName: "Port-USB-C@1",
            className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1",
            portTypeDescription: "USB-C",
            portNumber: 1,
            connectionActive: connected,
            activeCable: emarker,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: superSpeed,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: supported,
            transportsActive: active,
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    private func usbPD(maxW: Int, winningW: Int) -> PowerSource {
        let winning = PowerOption(
            voltageMV: 20_000,
            maxCurrentMA: winningW * 50,
            maxPowerMW: winningW * 1000
        )
        let max = PowerOption(
            voltageMV: 20_000,
            maxCurrentMA: maxW * 50,
            maxPowerMW: maxW * 1000
        )
        return PowerSource(
            id: 1, name: "USB-PD", parentPortType: 2, parentPortNumber: 1,
            options: [max], winning: winning
        )
    }

    private func brickID(maxW: Int, winningW: Int) -> PowerSource {
        let winning = PowerOption(
            voltageMV: 20_000,
            maxCurrentMA: winningW * 50,
            maxPowerMW: winningW * 1000
        )
        let max = PowerOption(
            voltageMV: 20_000,
            maxCurrentMA: maxW * 50,
            maxPowerMW: maxW * 1000
        )
        return PowerSource(
            id: 2, name: "Brick ID", parentPortType: 0x11, parentPortNumber: 1,
            options: [max], winning: winning
        )
    }

    // MARK: - Disconnected

    func testNothingConnectedHeadline() {
        let summary = PortSummary(port: makePort(connected: false))
        XCTAssertEqual(summary.status, .empty)
        XCTAssertEqual(summary.headline, "Nothing connected")
        XCTAssertTrue(summary.bullets.isEmpty)
    }

    // MARK: - Charging

    func testChargingOnlyWithoutDataHasWattageSuffix() {
        let port = makePort(connected: true, active: [], supported: ["USB2"])
        let summary = PortSummary(port: port, sources: [usbPD(maxW: 96, winningW: 60)])
        XCTAssertEqual(summary.status, .charging)
        XCTAssertEqual(summary.headline, "Charging · 96W charger")
    }

    func testChargingOnlyWithoutPDOOptionsOmitsWattage() {
        // No options means no wattage suffix; the headline just says "Charging only".
        let port = makePort(connected: true, active: [], supported: ["USB2"])
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .charging)
        XCTAssertEqual(summary.headline, "Charging only")
    }

    func testMagSafeBrickIDSourceCountsAsChargingPower() {
        let port = makePort(connected: true, active: [], supported: [])
        let summary = PortSummary(port: port, sources: [brickID(maxW: 140, winningW: 140)])
        XCTAssertEqual(summary.status, .charging)
        XCTAssertEqual(summary.headline, "Charging · 140W charger")
    }

    // MARK: - USB

    func testUSB2OnlyIsSlowDevice() {
        let port = makePort(active: ["USB2"], supported: ["USB2"])
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .dataDevice)
        XCTAssertTrue(
            summary.headline.hasPrefix("Slow USB device or charge-only cable"),
            "got: \(summary.headline)"
        )
    }

    func testUSB3IsUSBDevice() {
        let port = makePort(active: ["USB3"], supported: ["USB2", "USB3"], superSpeed: true)
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .dataDevice)
        XCTAssertTrue(summary.headline.hasPrefix("USB device"), "got: \(summary.headline)")
    }

    // MARK: - Thunderbolt and Display

    func testThunderboltLink() {
        let port = makePort(active: ["CIO", "USB3"], supported: ["CIO", "USB3"])
        let summary = PortSummary(port: port, sources: [usbPD(maxW: 96, winningW: 60)])
        XCTAssertEqual(summary.status, .thunderboltCable)
        XCTAssertEqual(summary.headline, "Thunderbolt / USB4 · 96W charger")
    }

    func testUSBCWithVideo() {
        let port = makePort(active: ["USB3", "DisplayPort"], superSpeed: true)
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .displayCable)
        XCTAssertEqual(summary.headline, "USB-C with video")
    }

    func testDisplayOnly() {
        let port = makePort(active: ["DisplayPort"])
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .displayCable)
        XCTAssertEqual(summary.headline, "Display connected")
    }

    // MARK: - Bullets

    func testEmarkerCableProducesEmarkerBullet() {
        let port = makePort(active: ["USB3"], superSpeed: true)
        let cable = PDIdentity(
            id: 99, endpoint: .sopPrime,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
        let summary = PortSummary(port: port, identities: [cable])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("e-marker") && $0.contains("advertises") }),
            "expected an e-marker bullet, got bullets: \(summary.bullets)"
        )
    }

    func testNoEmarkerCableProducesNoEmarkerBullet() {
        // PD-capable port (CC present) with no SOP'/SOP'' identity. The
        // wording deliberately doesn't claim "basic cable" — macOS may
        // simply not have run Discover Identity SOP' yet (typically only
        // happens when the link needs to negotiate above 3A).
        let port = makePort(active: ["USB2"], supported: ["CC", "USB2"], emarker: false)
        let summary = PortSummary(port: port)
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("No e-marker detected") }),
            "expected a no-e-marker bullet, got: \(summary.bullets)"
        )
    }

    func testNoPDPortDoesNotClaimBasicCable() {
        // USB-only port (no CC = no PD = no SOP' query possible). Don't blame
        // the cable for a missing e-marker the OS could never have read. This
        // is the M4 Mac Mini front-port case from issue #50.
        let port = makePort(active: ["USB3"], supported: ["USB2", "USB3"], superSpeed: true)
        let summary = PortSummary(port: port)
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("No e-marker detected") }),
            "no-PD port should not claim a missing e-marker, got: \(summary.bullets)"
        )
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("can't read cable details") }),
            "expected the 'port can't read cable details' bullet, got: \(summary.bullets)"
        )
    }

    func testMagSafePortDoesNotClaimNoPowerDelivery() {
        // Regression: a charging MagSafe port reports an empty
        // TransportsSupported (MagSafe negotiates PD over its own pins,
        // not the CC line). The previous logic tripped the "no Power
        // Delivery" branch because `pdCapable` is gated on CC. MagSafe
        // ports must not get any "can't read cable details" bullet at
        // all, since the cable is built into the brick.
        let magSafePort = USBCPort(
            id: 1,
            serviceName: "Port-MagSafe 3@1",
            className: "AppleHPMInterfaceType11",
            portDescription: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3",
            portNumber: 1,
            connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil, superSpeedActive: nil,
            usbModeType: nil, usbConnectString: nil,
            transportsSupported: [],
            transportsActive: ["CC"],
            transportsProvisioned: ["CC"],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
        let summary = PortSummary(
            port: magSafePort,
            sources: [usbPD(maxW: 100, winningW: 100)]
        )
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("no Power Delivery") }),
            "MagSafe must not claim 'no Power Delivery', got: \(summary.bullets)"
        )
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("can't read cable details") }),
            "MagSafe must not show the 'can't read cable details' bullet, got: \(summary.bullets)"
        )
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("No e-marker detected") }),
            "MagSafe must not show the missing-e-marker bullet, got: \(summary.bullets)"
        )
    }

    func testPDPortWithEmarkerStillShowsEmarker() {
        // Sanity: presence of an e-marker means PD must have fired, regardless
        // of whether the test fixture happens to set CC explicitly. We don't
        // want the new gate to suppress legitimate e-marker bullets.
        let port = makePort(
            active: ["USB3"],
            supported: ["CC", "USB2", "USB3"],
            superSpeed: true
        )
        let cable = PDIdentity(
            id: 99, endpoint: .sopPrime,
            parentPortType: 0, parentPortNumber: 0,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [], specRevision: 0
        )
        let summary = PortSummary(port: port, identities: [cable])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("e-marker") && $0.contains("advertises") }),
            "expected e-marker bullet on PD-capable port, got: \(summary.bullets)"
        )
    }

    func testNegotiatedPDOAppearsInBullets() {
        let port = makePort(active: ["USB3"], superSpeed: true)
        let summary = PortSummary(port: port, sources: [usbPD(maxW: 96, winningW: 60)])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("Currently negotiated") }),
            "expected a negotiated PDO bullet, got: \(summary.bullets)"
        )
    }

    // MARK: - Cable wattage limit suffix

    /// Helper: build an SOP' cable identity with the given current bits.
    /// Uses USB4 Gen 3 (3) as the speed baseline and a valid latency.
    /// `currentBits = 1` => 3A (60W); `currentBits = 2` => 5A (100W).
    private func cableIdentity(currentBits: Int) -> PDIdentity {
        let vdo: UInt32 = UInt32(0b011) | UInt32(currentBits << 5) | UInt32(1 << 13)
        return PDIdentity(
            id: 99, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [(3 << 27) | UInt32(0x05AC), 0, 0, vdo],
            specRevision: 3
        )
    }

    func testCableLimitSuffixAppearsWhenCableUnderAdvertised() {
        // Charger says 96W; cable rated 60W (3A * 20V).
        let port = makePort(active: ["USB3"], superSpeed: true)
        let summary = PortSummary(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            identities: [cableIdentity(currentBits: 1)]
        )
        XCTAssertEqual(summary.headline, "USB device · 96W charger · 60W cable")
    }

    func testCableLimitSuffixAbsentWhenCableMatchesCharger() {
        // Charger 96W, cable 100W (5A * 20V): cable can carry full power.
        let port = makePort(active: ["CIO"], superSpeed: true)
        let summary = PortSummary(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            identities: [cableIdentity(currentBits: 2)]
        )
        XCTAssertEqual(summary.headline, "Thunderbolt / USB4 · 96W charger")
    }

    func testCableLimitSuffixAbsentWhenNoCharger() {
        // No charger: nothing to compare against, so no cable suffix.
        let port = makePort(active: ["USB3"], superSpeed: true)
        let summary = PortSummary(port: port, identities: [cableIdentity(currentBits: 1)])
        XCTAssertEqual(summary.headline, "USB device")
    }

    func testCableLimitSuffixAbsentWhenNoCable() {
        // No e-marker: no cable wattage to surface.
        let port = makePort(active: ["USB3"], superSpeed: true)
        let summary = PortSummary(port: port, sources: [usbPD(maxW: 96, winningW: 60)])
        XCTAssertEqual(summary.headline, "USB device · 96W charger")
    }

    func testCableLimitSuffixOnChargingOnlyHeadline() {
        // The charging-only state path also gets the suffix when relevant.
        let port = makePort(connected: true, active: [], supported: ["USB2"])
        let summary = PortSummary(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            identities: [cableIdentity(currentBits: 1)]
        )
        XCTAssertEqual(summary.headline, "Charging · 96W charger · 60W cable")
    }

    // MARK: - Bullet ordering / grouping

    /// Pins the three-block grouping in the bullet list. Concrete
    /// expectation: link state and connected device come before any
    /// cable-specific lines, and cable-specific lines come before the
    /// charger-power numbers. Refactors that move bullets between these
    /// blocks should fail this test.
    func testBulletsAreGroupedLinkThenCableThenPower() {
        let port = makePort(active: ["USB3"], superSpeed: true)
        let cable = PDIdentity(
            id: 99, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [
                (3 << 27) | UInt32(0x05AC),
                0,
                0,
                UInt32(0b011) | UInt32(2 << 5) | UInt32(1 << 13) // USB4 Gen3, 5A, ~1m
            ],
            specRevision: 3
        )
        let partner = PDIdentity(
            id: 100, endpoint: .sop,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0, bcdDevice: 0,
            vdos: [(2 << 27) | UInt32(0x05AC)], // USB Peripheral
            specRevision: 3
        )
        let summary = PortSummary(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            identities: [cable, partner]
        )

        func index(_ predicate: (String) -> Bool) -> Int? {
            summary.bullets.firstIndex(where: predicate)
        }

        let speedIdx = index { $0.contains("SuperSpeed USB") }
        let deviceIdx = index { $0.contains("Connected device") }
        let cableSpeedIdx = index { $0.contains("Cable speed") }
        let cableMakerIdx = index { $0.contains("Cable made by") }
        let chargerIdx = index { $0.contains("Charger advertises") }
        let negotiatedIdx = index { $0.contains("Currently negotiated") }

        XCTAssertNotNil(speedIdx)
        XCTAssertNotNil(deviceIdx)
        XCTAssertNotNil(cableSpeedIdx)
        XCTAssertNotNil(cableMakerIdx)
        XCTAssertNotNil(chargerIdx)
        XCTAssertNotNil(negotiatedIdx)

        // A: link + connected device come first
        XCTAssertLessThan(speedIdx!, deviceIdx!, "Speed should come before connected device")
        XCTAssertLessThan(deviceIdx!, cableSpeedIdx!, "Connected device should come before cable details")

        // B: cable details (speed -> maker) come before power numbers
        XCTAssertLessThan(cableSpeedIdx!, cableMakerIdx!, "Cable speed should come before cable maker")
        XCTAssertLessThan(cableMakerIdx!, chargerIdx!, "Cable maker should come before charger numbers")

        // C: power negotiation tail
        XCTAssertLessThan(chargerIdx!, negotiatedIdx!, "Charger max should come before currently negotiated")
    }

    // MARK: - DisplayPort lane config

    func testDPBulletIncludesLaneCountWhenPinAssignmentPresent() {
        let port = USBCPort(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C",
            portNumber: 1, connectionActive: true, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "DisplayPort"],
            transportsActive: ["DisplayPort"],
            transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:],
            displayPortPinAssignment: 1,
            powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
        let summary = PortSummary(port: port)
        let dpBullet = summary.bullets.first { $0.contains("DisplayPort") }
        XCTAssertNotNil(dpBullet)
        XCTAssertTrue(dpBullet!.contains("4 DP lanes"), "Expected 4-lane info, got: \(dpBullet!)")
    }

    func testDPBulletShowsTwoLaneForAssignmentD() {
        let port = USBCPort(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C",
            portNumber: 1, connectionActive: true, activeCable: nil, opticalCable: nil,
            usbActive: nil, superSpeedActive: true, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "DisplayPort"],
            transportsActive: ["USB3", "DisplayPort"],
            transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:],
            displayPortPinAssignment: 2,
            powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil, rawProperties: [:]
        )
        let summary = PortSummary(port: port)
        let dpBullet = summary.bullets.first { $0.contains("DisplayPort") }
        XCTAssertNotNil(dpBullet)
        XCTAssertTrue(dpBullet!.contains("2 DP lanes"), "Expected 2-lane info, got: \(dpBullet!)")
    }

    func testDPBulletFallsBackWhenNoPinAssignment() {
        let port = makePort(active: ["DisplayPort"])
        let summary = PortSummary(port: port)
        let dpBullet = summary.bullets.first { $0.contains("DisplayPort") }
        XCTAssertEqual(dpBullet, "Carrying DisplayPort video")
    }

    // MARK: - Partner PD revision

    func testPartnerBulletIncludesPDRevision() {
        let port = makePort(active: ["USB3"], supported: ["CC"], superSpeed: true)
        let partner = PDIdentity(
            id: 50, endpoint: .sop,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0x1234, bcdDevice: 0,
            vdos: [0x6C00_05AC], specRevision: 3
        )
        let summary = PortSummary(port: port, identities: [partner])
        let deviceBullet = summary.bullets.first { $0.contains("Connected device") }
        XCTAssertNotNil(deviceBullet)
        XCTAssertTrue(deviceBullet!.contains("PD 3.1"), "Expected PD revision, got: \(deviceBullet!)")
    }

    func testPartnerBulletOmitsPDRevisionWhenZero() {
        let port = makePort(active: ["USB3"], supported: ["CC"], superSpeed: true)
        let partner = PDIdentity(
            id: 50, endpoint: .sop,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0x1234, bcdDevice: 0,
            vdos: [0x6C00_05AC], specRevision: 0
        )
        let summary = PortSummary(port: port, identities: [partner])
        let deviceBullet = summary.bullets.first { $0.contains("Connected device") }
        XCTAssertNotNil(deviceBullet)
        XCTAssertFalse(deviceBullet!.contains("PD"), "Should not show PD revision when unknown")
    }

    // MARK: - Unknown state enrichment

    func testUnknownWithSOPPartnerShowsEmarkerBullet() {
        // Connected, PD-capable, no transports active, no charger,
        // but a partner SOP identity exists. The e-marker explanation
        // bullet should appear because we know something is on the
        // other end.
        let port = makePort(connected: true, active: [], supported: ["CC"])
        let partner = PDIdentity(
            id: 50, endpoint: .sop,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0x05AC, productID: 0x1234, bcdDevice: 0,
            vdos: [0x6C00_05AC], specRevision: 3
        )
        let summary = PortSummary(port: port, identities: [partner])
        XCTAssertEqual(summary.status, .unknown)
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("No e-marker detected") }),
            "Expected e-marker explanation bullet in .unknown with SOP partner, got: \(summary.bullets)"
        )
    }

    func testUnknownWithChargerHitsChargingNotUnknown() {
        // A charger on the port should hit .charging, not .unknown,
        // even when no transports are active. Pin this so a future
        // refactor doesn't accidentally drop charger-only connections
        // into .unknown.
        let port = makePort(connected: true, active: [], supported: ["CC"])
        let source = usbPD(maxW: 20, winningW: 20)
        let summary = PortSummary(port: port, sources: [source])
        XCTAssertEqual(summary.status, .charging,
            "Charger present with no active transports should be .charging, not .unknown")
    }

    func testPureUnknownHasNoBullets() {
        // Connected but truly zero data: no transports, no charger,
        // no identities, no USB2 in supported. Should be .unknown
        // with empty bullets (no false "basic cable" claim).
        let port = makePort(connected: true, active: [], supported: [])
        let summary = PortSummary(port: port)
        XCTAssertEqual(summary.status, .unknown)
        XCTAssertTrue(summary.bullets.isEmpty,
            "Pure .unknown with no data should have empty bullets, got: \(summary.bullets)")
    }

    // MARK: - USB3 Transport integration

    func testUSB3Gen1ShowsPreciseSpeed() {
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 100, portKey: "2/1", signaling: 1,
            signalingDescription: "Gen 1", dataRole: "host"
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("USB 3.2 Gen 1 (5 Gbps)") }),
            "Gen 1 transport should produce precise label, got: \(summary.bullets)"
        )
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("SuperSpeed USB") }),
            "Generic SuperSpeed label should not appear when precise data is available"
        )
    }

    func testUSB3Gen2ShowsPreciseSpeed() {
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 101, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host"
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("USB 3.2 Gen 2 (10 Gbps)") }),
            "Gen 2 transport should produce precise label, got: \(summary.bullets)"
        )
    }

    func testUSB3FallbackWhenNoTransportData() {
        // When the USB3 transport service hasn't appeared yet (no device
        // connected or watcher hasn't caught up), fall back to the
        // generic "SuperSpeed USB" label.
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let summary = PortSummary(port: port, usb3Transports: [])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("SuperSpeed USB") }),
            "Should fall back to generic label without transport data, got: \(summary.bullets)"
        )
    }

    func testUSB3FallbackWhenSignalingNil() {
        // Transport exists but signaling field is nil (IOKit property absent).
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 102, portKey: "2/1", signaling: nil,
            signalingDescription: nil, dataRole: nil
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("SuperSpeed USB") }),
            "Should fall back to generic label when signaling is nil, got: \(summary.bullets)"
        )
    }

    func testUSB3UnknownSignalingShowsGenericGen() {
        // A signaling value we haven't seen before should still produce
        // a reasonable label rather than crashing or falling back to
        // the generic "SuperSpeed USB" text.
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 104, portKey: "2/1", signaling: 3,
            signalingDescription: "Gen 3", dataRole: "host"
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("USB 3.2 Gen 3") }),
            "Unknown gen should still produce a label, got: \(summary.bullets)"
        )
    }

    func testThunderboltActiveIgnoresUSB3TransportData() {
        // When Thunderbolt (CIO) is active, the USB3 bullet should not
        // appear at all. The TB label takes priority. USB3 transport
        // data should have no effect.
        let port = makePort(connected: true, active: ["CIO", "USB3"], supported: ["CIO", "USB3"])
        let transport = USB3Transport(
            id: 105, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host"
        )
        let summary = PortSummary(
            port: port,
            sources: [usbPD(maxW: 96, winningW: 60)],
            usb3Transports: [transport]
        )
        XCTAssertEqual(summary.status, .thunderboltCable)
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("USB 3.2") }),
            "USB3 transport label should not appear when Thunderbolt is active, got: \(summary.bullets)"
        )
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("Thunderbolt") || $0.contains("USB4") }),
            "Thunderbolt bullet should be present, got: \(summary.bullets)"
        )
    }

    func testUSB3TransportAloneDoesNotActivateUSB3Bullet() {
        // The port controller's transportsActive is the authority for
        // whether USB3 is active. Transport watcher data is supplementary
        // (refines the speed label). If transportsActive doesn't include
        // "USB3", the transport data should not cause a USB3 bullet to
        // appear. This prevents a split-brain state where the speed
        // bullet says "USB 3.2 Gen 2" but the headline says "Nothing
        // connected."
        let port = makePort(connected: true, active: [], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 106, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host"
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertFalse(
            summary.bullets.contains(where: { $0.contains("USB 3.2") || $0.contains("SuperSpeed") }),
            "USB3 bullet should not appear when transportsActive has no USB3, got: \(summary.bullets)"
        )
    }

    func testUSB3TransportWrongPortKeyIgnored() {
        // Transport data for a different port should not affect this port.
        let port = makePort(connected: true, active: ["USB3"], supported: ["CC", "USB3"])
        let transport = USB3Transport(
            id: 103, portKey: "2/99", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host"
        )
        let summary = PortSummary(port: port, usb3Transports: [transport])
        XCTAssertTrue(
            summary.bullets.contains(where: { $0.contains("SuperSpeed USB") }),
            "Transport for wrong port should be ignored, got: \(summary.bullets)"
        )
    }
}
