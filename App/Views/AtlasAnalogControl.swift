import SwiftUI
import ChronoscopeCore
#if canImport(UIKit)
import UIKit
#endif

/// A fixed-direction touch face. Hold or slide the same finger to change speed;
/// assistive activation remains a single, modest navigation step.
@MainActor
struct AtlasAnalogControl: View {
    let title: String
    let symbol: String
    let direction: AtlasNavigationDirection
    let accent: Color
    let cancellationToken: Int
    let onInput: @MainActor (Double) -> Void
    let onAccessibilityStep: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var strength = 0.0
    #if canImport(UIKit)
    @State private var touchSession = AtlasAnalogTouchSession()
    @State private var switchControlEnabled = UIAccessibility.isSwitchControlRunning
    #else
    @State private var mouseHeldSince: Double?
    @State private var mouseDistance = 0.0
    @State private var mouseCancelled = false
    @GestureState private var mouseTracking = false
    #endif

    init(title: String, symbol: String, direction: AtlasNavigationDirection, accent: Color,
         cancellationToken: Int = 0,
         onInput: @escaping @MainActor (Double) -> Void,
         onAccessibilityStep: @escaping @MainActor () -> Void) {
        self.title = title
        self.symbol = symbol
        self.direction = direction
        self.accent = accent
        self.cancellationToken = cancellationToken
        self.onInput = onInput
        self.onAccessibilityStep = onAccessibilityStep
    }

    var body: some View {
        ZStack {
            face.accessibilityHidden(true)
            // This native button stays in the accessibility tree under the
            // transparent touch receiver, without duplicating button traits.
            Button(action: onAccessibilityStep) { Color.clear }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(title)
                .accessibilityHint("Hold to glide. Slide farther to move faster. Activate to move one step.")
                .accessibilityIdentifier("atlas.navigation." + direction.rawValue)
            touchReceiver.accessibilityHidden(true)
        }
        .frame(width: 44, height: 44)
        .help(title + ". Hold to glide; slide farther to move faster.")
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancel() }
        }
        .onChange(of: voiceOverEnabled) { _, _ in cancel() }
        .onChange(of: cancellationToken) { _, _ in cancel() }
        .onDisappear { cancel() }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in
            switchControlEnabled = UIAccessibility.isSwitchControlRunning
            cancel()
        }
        #else
        .onChange(of: mouseTracking) { _, tracking in
            // GestureState also resets when SwiftUI cancels a drag, for which
            // the normal onEnded callback is not guaranteed.
            if !tracking { cancel() }
        }
        .task(id: mouseHeldSince) {
            guard mouseHeldSince != nil else { return }
            while !Task.isCancelled, let started = mouseHeldSince {
                publish(AtlasNavigationInput.strength(
                    heldSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
                    dragDistance: mouseDistance, normalizedForce: nil))
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        #endif
    }

    @ViewBuilder
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let content = Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(strength > 0 ? accent : Color.white.opacity(0.92))
            .offset(displacement)
            .frame(width: 44, height: 44)
            .overlay {
                shape.inset(by: 2.5)
                    .trim(from: 0, to: strength)
                    .stroke(accent.opacity(strength > 0 ? 0.7 : 0), lineWidth: 1.2)
                    .rotationEffect(.degrees(-90))
            }
            .contentShape(shape)
        if reduceTransparency {
            content
                .background(strength > 0 ? Color(red: 0.16, green: 0.20, blue: 0.25) : Color(red: 0.09, green: 0.12, blue: 0.16), in: shape)
                .overlay(shape.stroke(strength > 0 ? accent.opacity(0.55) : Color.white.opacity(0.24), lineWidth: 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(strength > 0 ? .regular.tint(accent.opacity(0.24)).interactive() : .regular.interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(strength > 0 ? accent.opacity(0.4) : Color.white.opacity(0.15), lineWidth: 1))
        }
    }

    private var displacement: CGSize {
        guard !reduceMotion else { return .zero }
        let amount = min(3, max(0, strength * 3))
        switch direction {
        case .forward, .rise, .zoomIn: return CGSize(width: 0, height: -amount)
        case .backward, .descend, .zoomOut: return CGSize(width: 0, height: amount)
        case .left: return CGSize(width: -amount, height: 0)
        case .right: return CGSize(width: amount, height: 0)
        }
    }

    @ViewBuilder
    private var touchReceiver: some View {
        #if canImport(UIKit)
        AtlasAnalogTouchReceiver(
            session: touchSession,
            enabled: scenePhase == .active && !voiceOverEnabled && !switchControlEnabled,
            hapticsEnabled: !reduceMotion && !voiceOverEnabled && !switchControlEnabled,
            onInput: publish)
            .allowsHitTesting(!voiceOverEnabled && !switchControlEnabled)
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($mouseTracking) { _, tracking, _ in tracking = true }
                .onChanged { value in
                    guard !mouseCancelled, scenePhase == .active else { return }
                    let distance = hypot(value.translation.width, value.translation.height)
                    let safetyBounds = CGRect(x: -64, y: -64, width: 172, height: 172)
                    guard distance <= 130, safetyBounds.contains(value.location) else {
                        cancel()
                        mouseCancelled = true
                        return
                    }
                    if mouseHeldSince == nil { mouseHeldSince = ProcessInfo.processInfo.systemUptime }
                    mouseDistance = distance
                    publish(AtlasNavigationInput.strength(
                        heldSeconds: max(0, ProcessInfo.processInfo.systemUptime - (mouseHeldSince ?? 0)),
                        dragDistance: mouseDistance, normalizedForce: nil))
                }
                .onEnded { _ in
                    cancel()
                    mouseCancelled = false
                })
            .allowsHitTesting(!voiceOverEnabled)
        #endif
    }

    private func publish(_ value: Double) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        // The input callback remains continuous. Avoid redundant visual updates
        // once a finger is holding at an unchanged speed.
        if abs(strength - next) > 0.002 || next == 0 { strength = next }
        onInput(next)
    }

    private func cancel() {
        #if canImport(UIKit)
        touchSession.cancel()
        #else
        mouseHeldSince = nil
        mouseDistance = 0
        mouseCancelled = mouseTracking
        #endif
        publish(0)
    }
}

#if canImport(UIKit)
@MainActor
private final class AtlasAnalogTouchSession {
    weak var view: AtlasAnalogTouchView?
    func cancel() { view?.cancelTracking() }
}

private struct AtlasAnalogTouchReceiver: UIViewRepresentable {
    let session: AtlasAnalogTouchSession
    let enabled: Bool
    let hapticsEnabled: Bool
    let onInput: @MainActor (Double) -> Void

    func makeCoordinator() -> AtlasAnalogTouchSession { session }

    func makeUIView(context: Context) -> AtlasAnalogTouchView {
        let view = AtlasAnalogTouchView()
        session.view = view
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: AtlasAnalogTouchView, context: Context) {
        // SwiftUI may replace these closures while a finger stays down.
        // Every frame reads the current callbacks rather than a captured view.
        view.enabled = enabled
        view.hapticsEnabled = hapticsEnabled
        view.onInput = onInput
    }

    static func dismantleUIView(_ view: AtlasAnalogTouchView, coordinator: AtlasAnalogTouchSession) {
        view.cancelTracking()
        if coordinator.view === view { coordinator.view = nil }
    }
}

@MainActor
private final class AtlasAnalogTouchView: UIView {
    var enabled = true
    var hapticsEnabled = true
    var onInput: @MainActor (Double) -> Void = { _ in }
    private var touch: UITouch?
    private var blockedTouch: UITouch?
    private var origin = CGPoint.zero
    private var startedAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTracking() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, window != nil, UIApplication.shared.applicationState == .active,
              touch == nil, blockedTouch == nil,
              let first = touches.min(by: { $0.timestamp < $1.timestamp }) else { return }
        touch = first
        origin = first.location(in: self)
        startedAt = CACurrentMediaTime()
        if hapticsEnabled, !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning,
           !UIAccessibility.isReduceMotionEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
        }
        advance(at: startedAt)
        guard touch != nil else { return }
        let proxy = AtlasAnalogDisplayLinkProxy(view: self)
        let link = CADisplayLink(target: proxy, selector: #selector(AtlasAnalogDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        advance(at: CACurrentMediaTime())
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch, touches.contains(touch) { cancelTracking() }
        if let blockedTouch, touches.contains(blockedTouch) { self.blockedTouch = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch, touches.contains(touch) { cancelTracking() }
        if let blockedTouch, touches.contains(blockedTouch) { self.blockedTouch = nil }
    }

    func advance(at timestamp: CFTimeInterval) {
        guard let touch else { return }
        guard enabled, window != nil, UIApplication.shared.applicationState == .active else {
            cancelTracking()
            return
        }
        let point = touch.location(in: self)
        let distance = hypot(point.x - origin.x, point.y - origin.y)
        guard distance <= 130, bounds.insetBy(dx: -64, dy: -64).contains(point) else {
            blockedTouch = touch
            stopTracking()
            return
        }
        var force: Double?
        if touch.type == .direct, traitCollection.forceTouchCapability == .available, touch.maximumPossibleForce > 0 {
            let normalized = Double(touch.force / touch.maximumPossibleForce)
            if normalized.isFinite { force = min(1, max(0, normalized)) }
        }
        onInput(AtlasNavigationInput.strength(
            heldSeconds: max(0, timestamp - startedAt), dragDistance: Double(distance), normalizedForce: force))
    }

    func cancelTracking() {
        blockedTouch = nil
        stopTracking()
    }

    private func stopTracking() {
        let wasActive = touch != nil || displayLink != nil
        touch = nil
        displayLink?.invalidate()
        displayLink = nil
        if wasActive { onInput(0) }
    }

    @objc private func resignedActive() { cancelTracking() }
}

@MainActor
private final class AtlasAnalogDisplayLinkProxy: NSObject {
    weak var view: AtlasAnalogTouchView?
    init(view: AtlasAnalogTouchView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.advance(at: link.timestamp)
    }
}
#endif
