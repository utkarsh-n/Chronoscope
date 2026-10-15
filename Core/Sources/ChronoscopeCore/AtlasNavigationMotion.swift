import Foundation

public enum AtlasNavigationDirection: String, CaseIterable, Hashable, Sendable {
    case forward, backward, left, right, rise, descend, zoomIn, zoomOut
}

/// Analog strength from deliberate dragging, a gentle hold, and optional real pressure.
/// Supply normalizedForce only for platform-reported force; touch area is not pressure.
public enum AtlasNavigationInput {
    public static let touchdownStrength = 0.2
    public static let maximumHoldStrength = 0.28
    public static let holdTimeConstant = 0.6
    public static let dragDeadzone = 4.0
    public static let fullDragDistance = 48.0

    public static func strength(heldSeconds: Double, dragDistance: Double,
                                normalizedForce: Double? = nil) -> Double {
        let held = heldSeconds.isFinite ? min(60, max(0, heldSeconds)) : 0
        let distance = dragDistance.isFinite ? min(fullDragDistance, max(0, dragDistance)) : 0
        let hold = touchdownStrength + (maximumHoldStrength - touchdownStrength)
            * -expm1(-held / holdTimeConstant)
        let drag = max(0, (distance - dragDeadzone) / (fullDragDistance - dragDeadzone))
        var intent = pow(drag, 1.6)
        if let force = normalizedForce, force.isFinite {
            intent = max(intent, pow(min(1, max(0, force)), 1.3))
        }
        return min(1, hold + (1 - hold) * intent)
    }
}

/// Displacement for one accepted frame. Positive values mean forward, right, rise,
/// and zoom in. logZoom is a logarithmic change, independent of camera conventions.
public struct AtlasNavigationDelta: Equatable, Sendable {
    public let forward: Double
    public let sideways: Double
    public let vertical: Double
    public let logZoom: Double

    public init(forward: Double = 0, sideways: Double = 0, vertical: Double = 0,
                logZoom: Double = 0) {
        self.forward = forward
        self.sideways = sideways
        self.vertical = vertical
        self.logZoom = logZoom
    }

    public static let zero = AtlasNavigationDelta()
}

/// Frame-rate-independent velocity smoothing for continuous navigation controls.
/// Opposite directions cancel before normalization. Vertical speed is deliberately
/// slower, and a delayed frame discards time beyond maximumDeltaTime.
public struct AtlasNavigationMotion: Sendable {
    public static let maximumTranslationSpeed = 12.0
    public static let verticalMultiplier = 0.6
    public static let maximumLogZoomSpeed = 0.85
    public static let accelerationTimeConstant = 0.12
    public static let releaseTimeConstant = 0.07
    public static let maximumDeltaTime = 0.05
    public static let translationStopSpeed = 0.005
    public static let zoomStopSpeed = 0.0005

    private var forwardVelocity = 0.0
    private var sidewaysVelocity = 0.0
    private var verticalVelocity = 0.0
    private var zoomVelocity = 0.0

    public init() {}

    public var isMoving: Bool {
        forwardVelocity != 0 || sidewaysVelocity != 0 || verticalVelocity != 0 || zoomVelocity != 0
    }

    public mutating func reset() {
        forwardVelocity = 0
        sidewaysVelocity = 0
        verticalVelocity = 0
        zoomVelocity = 0
    }

    public mutating func step(inputs: [AtlasNavigationDirection: Double], deltaTime: Double,
                              reduceMotion: Bool = false) -> AtlasNavigationDelta {
        // Invalid timestamps never alter velocity or poison a later valid frame.
        guard deltaTime.isFinite, deltaTime > 0 else { return .zero }
        let dt = min(Self.maximumDeltaTime, deltaTime)
        func strength(_ direction: AtlasNavigationDirection) -> Double {
            guard let value = inputs[direction], value.isFinite else { return 0 }
            return min(1, max(0, value))
        }
        var forward = strength(.forward) - strength(.backward)
        var sideways = strength(.right) - strength(.left)
        var vertical = strength(.rise) - strength(.descend)
        let magnitude = hypot(hypot(forward, sideways), vertical)
        if magnitude > 1 {
            forward /= magnitude
            sideways /= magnitude
            vertical /= magnitude
        }
        let targetForward = forward * Self.maximumTranslationSpeed
        let targetSideways = sideways * Self.maximumTranslationSpeed
        let targetVertical = vertical * Self.maximumTranslationSpeed * Self.verticalMultiplier
        let targetZoom = (strength(.zoomIn) - strength(.zoomOut)) * Self.maximumLogZoomSpeed

        if reduceMotion {
            // Direct response prevents inertia when a control is released or the preference changes.
            forwardVelocity = targetForward
            sidewaysVelocity = targetSideways
            verticalVelocity = targetVertical
            zoomVelocity = targetZoom
            return AtlasNavigationDelta(forward: targetForward * dt, sideways: targetSideways * dt,
                                        vertical: targetVertical * dt, logZoom: targetZoom * dt)
        }

        let released = targetForward == 0 && targetSideways == 0 && targetVertical == 0
        let tau = released ? Self.releaseTimeConstant : Self.accelerationTimeConstant
        let speed = hypot(hypot(forwardVelocity, sidewaysVelocity), verticalVelocity)
        let translationTime = released ? Self.releaseTime(speed: speed, threshold: Self.translationStopSpeed, dt: dt) : dt
        let stopTranslation = released && translationTime < dt
        let forwardDelta = Self.integrate(velocity: &forwardVelocity, target: targetForward, dt: translationTime, tau: tau)
        let sidewaysDelta = Self.integrate(velocity: &sidewaysVelocity, target: targetSideways, dt: translationTime, tau: tau)
        let verticalDelta = Self.integrate(velocity: &verticalVelocity, target: targetVertical, dt: translationTime, tau: tau)
        if stopTranslation {
            forwardVelocity = 0
            sidewaysVelocity = 0
            verticalVelocity = 0
        }

        let zoomReleased = targetZoom == 0
        let zoomTime = zoomReleased ? Self.releaseTime(speed: abs(zoomVelocity), threshold: Self.zoomStopSpeed, dt: dt) : dt
        let zoomDelta = Self.integrate(velocity: &zoomVelocity, target: targetZoom, dt: zoomTime,
                                       tau: zoomReleased ? Self.releaseTimeConstant : Self.accelerationTimeConstant)
        if zoomReleased && zoomTime < dt { zoomVelocity = 0 }
        return AtlasNavigationDelta(forward: forwardDelta, sideways: sidewaysDelta,
                                    vertical: verticalDelta, logZoom: zoomDelta)
    }

    private static func releaseTime(speed: Double, threshold: Double, dt: Double) -> Double {
        guard speed > threshold else { return 0 }
        // Integrate exactly to the stopping threshold, even if it falls between frames.
        return min(dt, releaseTimeConstant * log(speed / threshold))
    }

    private static func integrate(velocity: inout Double, target: Double, dt: Double, tau: Double) -> Double {
        let blend = -expm1(-dt / tau)
        let difference = velocity - target
        let displacement = target * dt + difference * tau * blend
        velocity = target + difference * (1 - blend)
        return displacement
    }
}
