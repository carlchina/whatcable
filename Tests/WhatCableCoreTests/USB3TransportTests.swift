import XCTest
@testable import WhatCableCore

/// Unit tests for the USB3Transport model and its speedLabel computed property.
final class USB3TransportTests: XCTestCase {

    // MARK: - speedLabel

    func testGen1SpeedLabel() {
        let t = USB3Transport(id: 1, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        XCTAssertEqual(t.speedLabel, "USB 3.2 Gen 1 (5 Gbps)")
    }

    func testGen2SpeedLabel() {
        let t = USB3Transport(id: 2, portKey: "2/1", signaling: 2, signalingDescription: "Gen 2", dataRole: "host")
        XCTAssertEqual(t.speedLabel, "USB 3.2 Gen 2 (10 Gbps)")
    }

    func testUnknownSignalingFallsBackToGenericLabel() {
        let t = USB3Transport(id: 3, portKey: "2/1", signaling: 5, signalingDescription: nil, dataRole: nil)
        XCTAssertEqual(t.speedLabel, "USB 3.2 Gen 5")
    }

    func testNilSignalingReturnsNil() {
        let t = USB3Transport(id: 4, portKey: "2/1", signaling: nil, signalingDescription: nil, dataRole: nil)
        XCTAssertNil(t.speedLabel)
    }

    // MARK: - Equatable / Hashable

    func testEqualTransportsAreEqual() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        XCTAssertEqual(a, b)
    }

    func testDifferentIDsAreNotEqual() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 11, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        XCTAssertNotEqual(a, b)
    }

    func testHashableUsableInSet() {
        let a = USB3Transport(id: 10, portKey: "2/1", signaling: 1, signalingDescription: "Gen 1", dataRole: "host")
        let b = USB3Transport(id: 11, portKey: "2/2", signaling: 2, signalingDescription: "Gen 2", dataRole: "device")
        let set: Set<USB3Transport> = [a, b, a]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Identifiable

    func testIdentifiableID() {
        let t = USB3Transport(id: 42, portKey: "2/3", signaling: 1, signalingDescription: nil, dataRole: nil)
        XCTAssertEqual(t.id, 42)
    }
}
