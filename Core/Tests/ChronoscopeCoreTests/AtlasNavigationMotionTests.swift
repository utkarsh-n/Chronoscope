import Foundation
import XCTest
@testable import ChronoscopeCore

final class AtlasNavigationMotionTests: XCTestCase {
    func testTouchdownHoldAndDragStrengthAreGentleAndMonotonic() {
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 0), 0.2)
        var previousHold = 0.0
        for seconds in [0.0, 0.05, 0.2, 0.6, 1, 3, 10, 100] {
            let value = AtlasNavigationInput.strength(heldSeconds: seconds, dragDistance: 0)
            XCTAssertGreaterThanOrEqual(value, previousHold)
            XCTAssertLessThanOrEqual(value, 0.28)
            previousHold = value
        }
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 4), 0.2)
        var previousDrag = 0.0
        for distance in 0...64 {
            let value = AtlasNavigationInput.strength(heldSeconds: 0.2, dragDistance: Double(distance))
            XCTAssertGreaterThanOrEqual(value, previousDrag)
            XCTAssertLessThanOrEqual(value, 1)
            previousDrag = value
        }
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 48), 1)
        XCTAssertLessThan(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 26), 0.6)
    }

    func testPressureIsOptionalClampedAndNeverInferredFromInvalidValues() {
        let ordinary = AtlasNavigationInput.strength(heldSeconds: 0.3, dragDistance: 12)
        XCTAssertEqual(ordinary, AtlasNavigationInput.strength(heldSeconds: 0.3, dragDistance: 12, normalizedForce: nil))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(ordinary, AtlasNavigationInput.strength(heldSeconds: 0.3, dragDistance: 12, normalizedForce: invalid))
        }
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 0, normalizedForce: -1), 0.2)
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 0, normalizedForce: 2), 1)
        var previous = 0.0
        for index in 0...10 {
            let value = AtlasNavigationInput.strength(heldSeconds: 0, dragDistance: 0, normalizedForce: Double(index) / 10)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testNonfiniteStrengthInputsAlwaysReturnFiniteBoundedStrength() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            let value = AtlasNavigationInput.strength(heldSeconds: invalid, dragDistance: invalid)
            XCTAssertEqual(value, 0.2)
        }
        XCTAssertEqual(AtlasNavigationInput.strength(heldSeconds: -100, dragDistance: -100), 0.2)
        let huge = AtlasNavigationInput.strength(heldSeconds: .greatestFiniteMagnitude, dragDistance: .greatestFiniteMagnitude)
        XCTAssertEqual(huge, 1)
    }

    func testAnalyticDisplacementAgreesAcross30_60And120HzIncludingRelease() {
        func journey(hz: Int) -> AtlasNavigationDelta {
            var motion = AtlasNavigationMotion()
            var total = AtlasNavigationDelta.zero
            let stages: [([AtlasNavigationDirection: Double], Double)] = [
                ([.forward: 0.28, .right: 0.4, .zoomIn: 0.5], 1),
                ([.backward: 0.8, .rise: 0.6, .zoomOut: 0.4], 1),
                ([:], 1)
            ]
            for (inputs, seconds) in stages {
                for _ in 0..<Int(seconds * Double(hz)) {
                    let delta = motion.step(inputs: inputs, deltaTime: 1 / Double(hz))
                    total = add(total, delta)
                }
            }
            XCTAssertFalse(motion.isMoving)
            return total
        }
        let thirty = journey(hz: 30), sixty = journey(hz: 60), oneTwenty = journey(hz: 120)
        assertEqual(thirty, sixty, accuracy: 1e-9)
        assertEqual(sixty, oneTwenty, accuracy: 1e-9)
    }

    func testFrameSubdivisionIntegratesAccelerationAndVelocityExactly() {
        var whole = AtlasNavigationMotion(), split = AtlasNavigationMotion()
        let inputs: [AtlasNavigationDirection: Double] = [.forward: 0.8, .left: 0.3, .zoomIn: 0.7]
        let a = whole.step(inputs: inputs, deltaTime: 0.04)
        let b = add(split.step(inputs: inputs, deltaTime: 0.02), split.step(inputs: inputs, deltaTime: 0.02))
        assertEqual(a, b, accuracy: 1e-12)
        assertEqual(whole.step(inputs: inputs, deltaTime: 0.02), split.step(inputs: inputs, deltaTime: 0.02), accuracy: 1e-12)
    }

    func testCombinedTranslationAndZoomRemainCappedDuringDirectionChanges() {
        var motion = AtlasNavigationMotion()
        let stages: [[AtlasNavigationDirection: Double]] = [
            [.forward: 1], [.forward: 1, .right: 1, .rise: 1], [.left: 1, .descend: 1], [.backward: 1, .zoomOut: 100]
        ]
        for inputs in stages {
            for _ in 0..<120 {
                let dt = 1.0 / 120
                let delta = motion.step(inputs: inputs, deltaTime: dt)
                XCTAssertLessThanOrEqual(hypot(hypot(delta.forward, delta.sideways), delta.vertical) / dt, 12 + 1e-10)
                XCTAssertLessThanOrEqual(abs(delta.logZoom) / dt, 0.85 + 1e-10)
            }
        }
    }

    func testOppositeDirectionsCancelAndVerticalSpeedHasIntentionalFactor() {
        var motion = AtlasNavigationMotion()
        let opposed: [AtlasNavigationDirection: Double] = [.forward: 1, .backward: 1, .left: 1, .right: 1, .rise: 1, .descend: 1, .zoomIn: 1, .zoomOut: 1]
        XCTAssertEqual(motion.step(inputs: opposed, deltaTime: 0.05), .zero)
        XCTAssertFalse(motion.isMoving)
        let reduced = motion.step(inputs: [.rise: 1], deltaTime: 0.05, reduceMotion: true)
        XCTAssertEqual(reduced.vertical, 12 * 0.6 * 0.05, accuracy: 1e-12)
        XCTAssertEqual(reduced.forward, 0)
        let diagonal = motion.step(inputs: [.forward: 1, .right: 1], deltaTime: 0.05, reduceMotion: true)
        XCTAssertEqual(hypot(diagonal.forward, diagonal.sideways) / 0.05, 12, accuracy: 1e-12)
        XCTAssertEqual(diagonal.forward, diagonal.sideways)
    }

    func testReleaseDecaysQuicklyAndStopsWithNoResidualMovement() {
        var motion = AtlasNavigationMotion()
        for _ in 0..<120 { _ = motion.step(inputs: [.forward: 1, .zoomIn: 1], deltaTime: 1.0 / 120) }
        let first = motion.step(inputs: [:], deltaTime: 0.05)
        let second = motion.step(inputs: [:], deltaTime: 0.05)
        XCTAssertGreaterThan(first.forward, second.forward)
        XCTAssertGreaterThan(first.logZoom, second.logZoom)
        XCTAssertGreaterThan(second.forward, 0)
        for _ in 0..<120 { _ = motion.step(inputs: [:], deltaTime: 1.0 / 120) }
        XCTAssertFalse(motion.isMoving)
        XCTAssertEqual(motion.step(inputs: [:], deltaTime: 0.05), .zero)
    }

    func testReduceMotionIsDirectAndReleaseClearsExistingInertia() {
        var motion = AtlasNavigationMotion()
        let held = motion.step(inputs: [.forward: 0.25, .zoomIn: 1], deltaTime: 0.02, reduceMotion: true)
        XCTAssertEqual(held.forward / 0.02, 3, accuracy: 1e-12)
        XCTAssertEqual(held.logZoom / 0.02, 0.85, accuracy: 1e-12)
        XCTAssertTrue(motion.isMoving)
        XCTAssertEqual(motion.step(inputs: [:], deltaTime: 0.02, reduceMotion: true), .zero)
        XCTAssertFalse(motion.isMoving)
        _ = motion.step(inputs: [.right: 1], deltaTime: 0.05)
        XCTAssertTrue(motion.isMoving)
        XCTAssertEqual(motion.step(inputs: [:], deltaTime: 0.02, reduceMotion: true), .zero)
        XCTAssertFalse(motion.isMoving)
    }

    func testInvalidFramesDoNotAdvanceOrPoisonVelocityAndInputsAreClamped() {
        var motion = AtlasNavigationMotion(), control = AtlasNavigationMotion()
        let inputs: [AtlasNavigationDirection: Double] = [.forward: 1]
        _ = motion.step(inputs: inputs, deltaTime: 0.02)
        _ = control.step(inputs: inputs, deltaTime: 0.02)
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(motion.step(inputs: [.backward: 1], deltaTime: invalid), .zero)
        }
        assertEqual(motion.step(inputs: inputs, deltaTime: 0.02), control.step(inputs: inputs, deltaTime: 0.02), accuracy: 1e-12)
        motion.reset()
        XCTAssertEqual(motion.step(inputs: [.forward: .nan, .right: .infinity, .rise: -1, .zoomOut: -.infinity], deltaTime: 0.05), .zero)
        let clamped = motion.step(inputs: [.forward: .greatestFiniteMagnitude, .zoomIn: 2], deltaTime: 0.05, reduceMotion: true)
        XCTAssertEqual(clamped.forward, 12 * 0.05, accuracy: 1e-12)
        XCTAssertEqual(clamped.logZoom, 0.85 * 0.05, accuracy: 1e-12)
    }

    func testDelayedFrameIsCappedAndResetRemovesResumeInertia() {
        var delayed = AtlasNavigationMotion(), ordinary = AtlasNavigationMotion()
        let inputs: [AtlasNavigationDirection: Double] = [.forward: 1, .zoomIn: 1]
        for _ in 0..<60 {
            _ = delayed.step(inputs: inputs, deltaTime: 1.0 / 60)
            _ = ordinary.step(inputs: inputs, deltaTime: 1.0 / 60)
        }
        assertEqual(delayed.step(inputs: inputs, deltaTime: 10), ordinary.step(inputs: inputs, deltaTime: 0.05), accuracy: 1e-12)
        delayed.reset()
        XCTAssertFalse(delayed.isMoving)
        XCTAssertEqual(delayed.step(inputs: [:], deltaTime: 10), .zero)
        var fresh = AtlasNavigationMotion()
        assertEqual(delayed.step(inputs: inputs, deltaTime: 0.02), fresh.step(inputs: inputs, deltaTime: 0.02), accuracy: 1e-12)
    }

    private func add(_ a: AtlasNavigationDelta, _ b: AtlasNavigationDelta) -> AtlasNavigationDelta {
        AtlasNavigationDelta(forward: a.forward + b.forward, sideways: a.sideways + b.sideways,
                             vertical: a.vertical + b.vertical, logZoom: a.logZoom + b.logZoom)
    }

    private func assertEqual(_ a: AtlasNavigationDelta, _ b: AtlasNavigationDelta, accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.forward, b.forward, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.sideways, b.sideways, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.vertical, b.vertical, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.logZoom, b.logZoom, accuracy: accuracy, file: file, line: line)
    }
}
