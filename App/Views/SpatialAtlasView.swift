import SwiftUI
import simd
import ChronoscopeCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Coordinates describe semantic space. Dates are filtered independently by the parent.
struct SpatialNode: Identifiable {
    let id: String
    let title: String
    let position: SIMD3<Double>
    let color: Color
    let emphasized: Bool

    init(id: String, title: String, position: SIMD3<Double>, color: Color, emphasized: Bool = false) {
        self.id = id
        self.title = title
        self.position = position
        self.color = color
        self.emphasized = emphasized
    }
}

struct SpatialLink {
    let source: String
    let target: String
    let color: Color
    let isSemantic: Bool

    init(source: String, target: String, color: Color, isSemantic: Bool = false) {
        self.source = source
        self.target = target
        self.color = color
        self.isSemantic = isSemantic
    }
}

/// A movable perspective camera, rather than a rotation of a flat graph. Walking
/// changes the observer's world position, so nearby events pass the observer.
struct SpatialAtlasView: View {
    let nodes: [SpatialNode]
    let links: [SpatialLink]
    let focusID: String?
    let spaceTitle: String
    let minimumViewportHeight: CGFloat
    var controlsBottomInset: CGFloat = 0
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var keyboardFocused: Bool
    @State private var camera = AtlasCamera()
    @State private var lastDrag = CGSize.zero
    @State private var lastMagnification = 1.0
    @State private var initialized = false
    @State private var instrumentHeight: CGFloat = 46
    @State private var regularControlHeight: CGFloat = 92
    @State private var shortControlHeight: CGFloat = 44
    @State private var navigationInputs: [AtlasNavigationDirection: Double] = [:]
    @State private var navigationMotion = AtlasNavigationMotion()
    @State private var navigationRunning = false
    @State private var navigationCancellationToken = 0
    private let accent = Color(red: 0.81, green: 0.98, blue: 0.39)

    init(nodes: [SpatialNode], links: [SpatialLink], focusID: String? = nil, spaceTitle: String = "MEANING SPACE", minimumViewportHeight: CGFloat = 250, controlsBottomInset: CGFloat = 0, onSelect: @escaping (String) -> Void) {
        self.nodes = nodes
        self.links = links
        self.focusID = focusID
        self.spaceTitle = spaceTitle
        self.minimumViewportHeight = minimumViewportHeight
        self.controlsBottomInset = controlsBottomInset
        self.onSelect = onSelect
    }

    var body: some View {
        let viewport = boundedViewport()
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            let shortLandscape = geometry.size.height < 350 && geometry.size.width >= 500
            let horizontalPadding: CGFloat = compact ? 14 : 20
            let hudPadding: CGFloat = shortLandscape ? 8 : horizontalPadding
            let hudHeight = shortLandscape ? shortControlHeight : regularControlHeight
            ZStack {
                AtlasCanvasLayer(nodes: viewport.nodes, links: viewport.links, focusID: focusID, camera: camera,
                                 controlsBottomInset: max(0, controlsBottomInset), controlHeight: hudHeight,
                                 hudPadding: hudPadding, instrumentHeight: shortLandscape ? 0 : instrumentHeight) { id in
                    keyboardFocused = true
                    onSelect(id)
                }
                .contentShape(Rectangle())
                .onTapGesture { keyboardFocused = true }
                .simultaneousGesture(lookGesture)
                .simultaneousGesture(zoomGesture)

                VStack(spacing: 0) {
                    if !shortLandscape {
                        instrumentBar(compact: compact, nodeCount: viewport.nodes.count, linkCount: viewport.links.count)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { instrumentHeight = $0 }
                    }
                    Spacer(minLength: 0)
                    navigationBar(compact: compact, shortLandscape: shortLandscape)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if shortLandscape { shortControlHeight = height }
                            else { regularControlHeight = height }
                        }
                        .padding(.bottom, max(0, controlsBottomInset))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, hudPadding)

                crosshair
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                #if DEBUG
                if ProcessInfo.processInfo.environment["CHRONOSCOPE_VERIFY_NAVIGATION"] == "1" {
                    Text(String(format: "Observer %.5f %.5f %.5f zoom %.5f active %d",
                                camera.eye.x, camera.eye.y, camera.eye.z, camera.zoom, navigationInputs.count))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 56)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("atlas.navigation.verification")
                }
                #endif
            }
            .clipped()
            .background(Color(red: 0.031, green: 0.045, blue: 0.072))
            .focusable()
            .focused($keyboardFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { key in handleKey(key) }
        }
        .frame(minHeight: minimumViewportHeight)
        .task(id: navigationRunning) {
            guard navigationRunning else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled && navigationRunning {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard !Task.isCancelled, scenePhase == .active else {
                    stopNavigation()
                    return
                }
                let now = clock.now
                let elapsed = previous.duration(to: now).components
                previous = now
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                applyNavigation(navigationMotion.step(inputs: navigationInputs, deltaTime: seconds, reduceMotion: reduceMotion))
                if navigationInputs.isEmpty && !navigationMotion.isMoving { navigationRunning = false }
            }
        }
        .onDisappear { stopNavigation() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopNavigation() }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if nodes.contains(where: { $0.id == focusID }) {
                centerOnFocus(animated: false)
            } else {
                resetCamera(animated: false)
            }
        }
        .onChange(of: focusID) { _, _ in centerOnFocus() }
        .onChange(of: nodes.first(where: { $0.id == focusID })?.position) { _, _ in centerOnFocus() }
        .onChange(of: nodes.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty && !isEmpty {
                if nodes.contains(where: { $0.id == focusID }) {
                    centerOnFocus(animated: false)
                } else {
                    resetCamera(animated: false)
                }
            }
        }
    }

    /// Imported indexes stay on disk. Protect the immediate-mode drawing surface
    /// if a caller accidentally supplies an unsampled or duplicate-heavy graph.
    private func boundedViewport() -> (nodes: [SpatialNode], links: [SpatialLink]) {
        var seen = Set<String>()
        var drawnNodes: [SpatialNode] = []
        let candidates = nodes.prefix(4096)
        if let focusID, let focus = candidates.first(where: { $0.id == focusID }), isFinite(focus.position) {
            drawnNodes.append(focus)
            seen.insert(focus.id)
        }
        for node in candidates where isFinite(node.position) {
            if seen.insert(node.id).inserted { drawnNodes.append(node) }
            if drawnNodes.count >= 512 { break }
        }
        var edgeKeys = Set<AtlasLinkKey>()
        var drawnLinks: [SpatialLink] = []
        for link in links.prefix(8192) where seen.contains(link.source) && seen.contains(link.target) {
            if edgeKeys.insert(AtlasLinkKey(source: link.source, target: link.target, semantic: link.isSemantic)).inserted {
                drawnLinks.append(link)
            }
            if drawnLinks.count >= 2048 { break }
        }
        return (drawnNodes, drawnLinks)
    }

    private func isFinite(_ position: SIMD3<Double>) -> Bool {
        position.x.isFinite && position.y.isFinite && position.z.isFinite
    }

    private var lookGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                keyboardFocused = true
                let dx = value.translation.width - lastDrag.width
                let dy = value.translation.height - lastDrag.height
                lastDrag = value.translation
                camera.yaw -= Double(dx) * 0.0045
                camera.pitch = min(1.15, max(-1.15, camera.pitch + Double(dy) * 0.0038))
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                camera.zoom = min(2.8, max(0.5, camera.zoom * value / lastMagnification))
                lastMagnification = value
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    private func instrumentBar(compact: Bool, nodeCount: Int, linkCount: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text(spaceTitle)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .tracking(1)
                }
                .foregroundStyle(accent.opacity(0.8))
                Text("\(nodeCount) events · \(linkCount) connections")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
                if !compact {
                    Text("Hold arrows to glide · Slide farther for speed")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    Text("Hold arrows to glide · Slide for speed")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.48))
                }
            }
            .allowsHitTesting(false)
            Spacer()
            HStack(spacing: 12) {
                if !compact {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("OBSERVER")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                        Text(String(format: "%+.1f  %+.1f  %+.1f", camera.eye.x, camera.eye.y, camera.eye.z))
                            .font(.system(size: 10, design: .monospaced))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.white.opacity(0.35))
                }
                compass
            }
        }
    }

    private var compass: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 1)
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).padding(8)
            Path { path in
                path.move(to: CGPoint(x: 23, y: 5))
                path.addLine(to: CGPoint(x: 18, y: 27))
                path.addLine(to: CGPoint(x: 23, y: 24))
                path.addLine(to: CGPoint(x: 28, y: 27))
                path.closeSubpath()
            }
            .fill(accent.opacity(0.7))
            .rotationEffect(.radians(camera.yaw))
            Text("N").font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
                .offset(y: -28)
        }
        .frame(width: 46, height: 46)
        .accessibilityLabel("Observer heading")
        .accessibilityValue("\(Int(camera.yaw * 180 / .pi)) degrees")
    }

    @ViewBuilder
    private func navigationBar(compact: Bool, shortLandscape: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 2) {
                navigationContents(compact: compact, shortLandscape: shortLandscape)
            }
        } else {
            navigationContents(compact: compact, shortLandscape: shortLandscape)
        }
    }

    @ViewBuilder
    private func navigationContents(compact: Bool, shortLandscape: Bool) -> some View {
        if shortLandscape { horizontalNavigationControls }
        else { navigationControls(compact: compact) }
    }

    private var horizontalNavigationControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                analogControl("Strafe left", symbol: "arrow.left", direction: .left) { move(sideways: -1) }
                analogControl("Walk forward", symbol: "arrow.up", direction: .forward) { move(forward: 1) }
                analogControl("Walk backward", symbol: "arrow.down", direction: .backward) { move(forward: -1) }
                analogControl("Strafe right", symbol: "arrow.right", direction: .right) { move(sideways: 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Walk through the map")
            HStack(spacing: 4) {
                analogControl("Rise", symbol: "chevron.up", direction: .rise) { move(vertical: 1) }
                analogControl("Descend", symbol: "chevron.down", direction: .descend) { move(vertical: -1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Observer height")
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                analogControl("Zoom in", symbol: "plus", direction: .zoomIn) { camera.zoom = min(2.8, camera.zoom * 1.18) }
                analogControl("Zoom out", symbol: "minus", direction: .zoomOut) { camera.zoom = max(0.5, camera.zoom / 1.18) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Map zoom")
            control("Reset camera", symbol: "viewfinder", prominent: true) { resetCamera(animated: true) }
                .accessibilityHint("Fits the visible events in space")
        }
    }

    private func navigationControls(compact: Bool) -> some View {
        HStack(alignment: .bottom, spacing: compact ? 4 : 10) {
            VStack(spacing: 4) {
                analogControl("Walk forward", symbol: "arrow.up", direction: .forward) { move(forward: 1) }
                HStack(spacing: 4) {
                    analogControl("Strafe left", symbol: "arrow.left", direction: .left) { move(sideways: -1) }
                    analogControl("Walk backward", symbol: "arrow.down", direction: .backward) { move(forward: -1) }
                    analogControl("Strafe right", symbol: "arrow.right", direction: .right) { move(sideways: 1) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Walk through the map")

            VStack(spacing: 4) {
                analogControl("Rise", symbol: "chevron.up", direction: .rise) { move(vertical: 1) }
                analogControl("Descend", symbol: "chevron.down", direction: .descend) { move(vertical: -1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Observer height")

            Spacer(minLength: 0)
            if !compact {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        legend("Article link", color: .white, dashed: false)
                        legend("Semantic affinity", color: accent, dashed: true)
                    }
                    Text("Drag to look · Pinch to zoom · Tap an event to explore")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .padding(.bottom, 6)
                Spacer(minLength: 0)
            }

            VStack(spacing: 4) {
                analogControl("Zoom in", symbol: "plus", direction: .zoomIn) { camera.zoom = min(2.8, camera.zoom * 1.18) }
                analogControl("Zoom out", symbol: "minus", direction: .zoomOut) { camera.zoom = max(0.5, camera.zoom / 1.18) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Map zoom")

            control("Reset camera", symbol: "viewfinder", prominent: true) { resetCamera(animated: true) }
                .accessibilityHint("Fits the visible events in space")
        }
    }

    private func control(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(prominent ? accent : Color.white.opacity(0.92))
        }
        .buttonStyle(AtlasNavigationButtonStyle(reduceTransparency: reduceTransparency, prominent: prominent, accent: accent))
        .accessibilityLabel(title)
        .help(title)
    }

    private func analogControl(_ title: String, symbol: String, direction: AtlasNavigationDirection,
                               accessibilityStep: @escaping () -> Void) -> some View {
        AtlasAnalogControl(title: title, symbol: symbol, direction: direction, accent: accent,
                           cancellationToken: navigationCancellationToken) { strength in
            setNavigationInput(strength, direction: direction)
        } onAccessibilityStep: {
            stopNavigation()
            accessibilityStep()
        }
    }

    private func setNavigationInput(_ strength: Double, direction: AtlasNavigationDirection) {
        if strength > 0 && strength.isFinite && scenePhase == .active {
            let next = min(1, strength)
            if navigationInputs[direction] == nil { keyboardFocused = true }
            if abs((navigationInputs[direction] ?? 0) - next) > 0.002 { navigationInputs[direction] = next }
            if !navigationRunning { navigationRunning = true }
        } else {
            navigationInputs.removeValue(forKey: direction)
            if reduceMotion && navigationInputs.isEmpty { stopNavigation() }
        }
    }

    private func applyNavigation(_ delta: AtlasNavigationDelta) {
        let horizontalForward = SIMD3<Double>(sin(camera.yaw), 0, cos(camera.yaw))
        let horizontalRight = SIMD3<Double>(cos(camera.yaw), 0, -sin(camera.yaw))
        camera.eye += horizontalForward * delta.forward + horizontalRight * delta.sideways + SIMD3<Double>(0, delta.vertical, 0)
        camera.zoom = min(2.8, max(0.5, camera.zoom * exp(delta.logZoom)))
    }

    private func stopNavigation() {
        if navigationRunning || !navigationInputs.isEmpty || navigationMotion.isMoving {
            navigationCancellationToken += 1
        }
        navigationInputs.removeAll()
        navigationMotion.reset()
        navigationRunning = false
    }

    private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(color.opacity(0.5))
                .frame(width: dashed ? 9 : 16, height: 1)
            Text(title).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.white.opacity(0.4))
        }
    }

    private var crosshair: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: 0.7).frame(width: 18, height: 18)
            Circle().fill(Color.white.opacity(0.3)).frame(width: 2, height: 2)
        }
    }

    private func move(forward: Double = 0, sideways: Double = 0, vertical: Double = 0) {
        let speed = 1.15
        let horizontalForward = SIMD3<Double>(sin(camera.yaw), 0, cos(camera.yaw))
        let horizontalRight = SIMD3<Double>(cos(camera.yaw), 0, -sin(camera.yaw))
        let displacement = horizontalForward * forward + horizontalRight * sideways + SIMD3<Double>(0, vertical, 0)
        camera.eye += displacement * speed
        keyboardFocused = true
    }

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        switch key.key {
        case .upArrow: move(forward: 1)
        case .downArrow: move(forward: -1)
        case .leftArrow: move(sideways: -1)
        case .rightArrow: move(sideways: 1)
        default:
            switch key.characters.lowercased() {
            case "w": move(forward: 1)
            case "s": move(forward: -1)
            case "a": move(sideways: -1)
            case "d": move(sideways: 1)
            case "q": move(vertical: 1)
            case "e": move(vertical: -1)
            case "r": resetCamera(animated: true)
            default: return .ignored
            }
        }
        return .handled
    }

    private func centerOnFocus(animated: Bool = true) {
        stopNavigation()
        guard let node = nodes.first(where: { $0.id == focusID }), isFinite(node.position) else { return }
        var next = camera
        next.eye = node.position - next.forward * 16
        updateCamera(next, animated: animated)
    }

    private func resetCamera(animated: Bool) {
        stopNavigation()
        let finiteNodes = boundedViewport().nodes
        guard !finiteNodes.isEmpty else {
            updateCamera(AtlasCamera(), animated: animated)
            return
        }
        let center = finiteNodes.reduce(SIMD3<Double>.zero) { $0 + $1.position } / Double(finiteNodes.count)
        let radius = finiteNodes.map { simd_length($0.position - center) }.max() ?? 8
        var next = AtlasCamera()
        next.eye = center - next.forward * max(20, radius * 2.35)
        updateCamera(next, animated: animated)
    }

    private func updateCamera(_ next: AtlasCamera, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.65)) { camera = next }
        } else {
            camera = next
        }
    }
}

/// Native interactive glass keeps the drawing surface visible under navigation.
/// Explicit sizing preserves 44-point targets without adding default button padding
/// to the compact directional layout.
private struct AtlasNavigationButtonStyle: ButtonStyle {
    let reduceTransparency: Bool
    let prominent: Bool
    let accent: Color

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let face = configuration.label
            .frame(width: 44, height: 44)
            .contentShape(shape)
        if reduceTransparency {
            face
                .background(configuration.isPressed ? Color(red: 0.16, green: 0.20, blue: 0.25) : Color(red: 0.09, green: 0.12, blue: 0.16), in: shape)
                .overlay(shape.stroke(prominent ? accent.opacity(0.55) : Color.white.opacity(0.24), lineWidth: 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            face
                .glassEffect(prominent ? .regular.tint(accent.opacity(0.24)).interactive() : .regular.interactive(), in: shape)
        } else {
            face
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(prominent ? accent.opacity(0.35) : Color.white.opacity(0.15), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

private struct AtlasLinkKey: Hashable {
    let source: String
    let target: String
    let semantic: Bool
}

private struct AtlasCamera {
    var eye = SIMD3<Double>(0, 2, -24)
    var yaw = 0.0
    var pitch = -0.08
    var zoom = 1.0

    var forward: SIMD3<Double> { SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) }
    var right: SIMD3<Double> { SIMD3(cos(yaw), 0, -sin(yaw)) }
    var up: SIMD3<Double> { simd_cross(forward, right) }

    func project(_ world: SIMD3<Double>, size: CGSize) -> AtlasProjection? {
        let relative = world - eye
        let depth = simd_dot(relative, forward)
        guard depth > 0.45, depth.isFinite else { return nil }
        let focal = Double(min(size.width, size.height)) * 0.9 * zoom
        let x = Double(size.width) / 2 + simd_dot(relative, right) * focal / depth
        let y = Double(size.height) / 2 - simd_dot(relative, up) * focal / depth
        guard x.isFinite, y.isFinite else { return nil }
        return AtlasProjection(point: CGPoint(x: x, y: y), depth: depth, scale: focal / depth)
    }
}

private struct AtlasProjection {
    let point: CGPoint
    let depth: Double
    let scale: Double
}

private struct AtlasPlacedNode: Identifiable {
    let node: SpatialNode
    let projection: AtlasProjection
    let rect: CGRect
    let fontSize: CGFloat
    let title: String
    var labelVisible = false
    var id: String { node.id }
    var labelPoint: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    var hitRect: CGRect {
        let width = max(44, rect.width + 8)
        let height = max(44, rect.height + 8)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// All six camera values interpolate together, including hit targets during a glide.
private struct AtlasCanvasLayer: View, Animatable {
    let nodes: [SpatialNode]
    let links: [SpatialLink]
    let focusID: String?
    var camera: AtlasCamera
    let controlsBottomInset: CGFloat
    let controlHeight: CGFloat
    let hudPadding: CGFloat
    let instrumentHeight: CGFloat
    let onSelect: (String) -> Void

    typealias CameraAnimation = AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>>
    nonisolated var animatableData: CameraAnimation {
        get { CameraAnimation(AnimatablePair(camera.eye.x, camera.eye.y), AnimatablePair(AnimatablePair(camera.eye.z, camera.yaw), AnimatablePair(camera.pitch, camera.zoom))) }
        set {
            camera.eye = SIMD3(newValue.first.first, newValue.first.second, newValue.second.first.first)
            camera.yaw = newValue.second.first.second
            camera.pitch = newValue.second.second.first
            camera.zoom = newValue.second.second.second
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let placed = place(in: geometry.size)
            ZStack {
                Canvas { context, size in draw(placed, context: context, size: size) }
                    .accessibilityHidden(true)
                    .onTapGesture { point in
                        if let node = hit(point, placed: placed, size: geometry.size) { onSelect(node.id) }
                    }
                ForEach(placed.filter(\.labelVisible)) { item in
                    Button { onSelect(item.node.id) } label: {
                        Color.clear.frame(width: item.hitRect.width, height: item.hitRect.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(item.labelPoint)
                    .accessibilityLabel(item.node.title)
                    .accessibilityHint("Move to this event and explore its connections")
                    .accessibilityAddTraits(item.node.id == focusID ? .isSelected : [])
                }
            }
        }
    }

    /// Covers the actual footer and navigation geometry, while world projection
    /// remains centered in the complete drawing surface.
    private func selectableViewport(in size: CGSize) -> CGRect {
        let top = hudPadding + instrumentHeight + 6
        let bottom = controlsBottomInset + controlHeight + hudPadding + 6
        return CGRect(x: 12, y: min(size.height, top), width: max(0, size.width - 24),
                      height: max(0, size.height - top - bottom))
    }

    private func place(in size: CGSize) -> [AtlasPlacedNode] {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
        let labelViewport = selectableViewport(in: size)
        let labelsFit = labelViewport.width >= 44 && labelViewport.height >= 44
        let maximumLabelWidth = max(1, labelViewport.width - 8)
        var placed: [AtlasPlacedNode] = []
        for node in nodes {
            guard let projection = camera.project(node.position, size: size), screen.contains(projection.point) else { continue }
            let focus = node.id == focusID
            let font: CGFloat = focus ? 13 : min(12, max(10, CGFloat(16 - projection.depth * 0.13)))
            var title = node.title.count > 39 ? String(node.title.prefix(36)) + "…" : node.title
            let padding: CGFloat = focus ? 30 : 24
            while title.count > 1 && measure(title, size: font, bold: focus) + padding > maximumLabelWidth {
                title = String(title.dropLast(2)) + "…"
            }
            let width = min(maximumLabelWidth, measure(title, size: font, bold: focus) + padding)
            let height: CGFloat = focus ? 34 : 27
            let hitWidth = max(44, width + 8)
            let hitHeight = max(44, height + 8)
            let x = labelsFit ? min(labelViewport.maxX - hitWidth / 2, max(labelViewport.minX + hitWidth / 2, projection.point.x)) : projection.point.x
            let y = labelsFit ? min(labelViewport.maxY - hitHeight / 2, max(labelViewport.minY + hitHeight / 2, projection.point.y)) : projection.point.y
            let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
            placed.append(AtlasPlacedNode(node: node, projection: projection, rect: rect, fontSize: font, title: title))
        }
        // Keep the focus and highlighted route legible before choosing nearer labels.
        let priority = placed.indices.sorted { a, b in
            let aRank = placed[a].node.id == focusID ? 2 : placed[a].node.emphasized ? 1 : 0
            let bRank = placed[b].node.id == focusID ? 2 : placed[b].node.emphasized ? 1 : 0
            return aRank == bRank ? placed[a].projection.depth < placed[b].projection.depth : aRank > bRank
        }
        var occupied: [CGRect] = []
        var count = 0
        let cap = size.width < 600 ? 13 : 22
        for index in priority {
            let item = placed[index]
            guard labelsFit, count < cap else { break }
            if !occupied.contains(where: { $0.intersects(item.hitRect.insetBy(dx: -3, dy: -3)) }) {
                placed[index].labelVisible = true
                occupied.append(item.hitRect)
                count += 1
            }
        }
        return placed.sorted { $0.projection.depth > $1.projection.depth }
    }

    private func measure(_ title: String, size: CGFloat, bold: Bool) -> CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        #else
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        #endif
        return (title as NSString).size(withAttributes: [.font: font]).width
    }

    private func hit(_ point: CGPoint, placed: [AtlasPlacedNode], size: CGSize) -> SpatialNode? {
        let viewport = selectableViewport(in: size)
        guard viewport.width >= 44, viewport.height >= 44, viewport.contains(point) else { return nil }
        for item in placed.reversed() where item.labelVisible && item.hitRect.contains(point) {
            return item.node
        }
        let dotViewport = viewport.insetBy(dx: 22, dy: 22)
        return placed.reversed().first {
            dotViewport.contains($0.projection.point) && hypot($0.projection.point.x - point.x, $0.projection.point.y - point.y) < 22
        }?.node
    }

    private func draw(_ placed: [AtlasPlacedNode], context: GraphicsContext, size: CGSize) {
        drawStars(context: context, size: size)
        drawGrid(context: context, size: size)
        let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for link in links {
            guard let a = lookup[link.source], let b = lookup[link.target],
                  let segment = projectedSegment(a.position, b.position, size: size) else { continue }
            let active = a.emphasized && b.emphasized
            let focused = link.source == focusID || link.target == focusID
            let depth = (segment.0.depth + segment.1.depth) / 2
            let fog = min(1, max(0.18, 24 / depth))
            var line = Path()
            line.move(to: segment.0.point)
            line.addLine(to: segment.1.point)
            context.stroke(line, with: .color(link.color.opacity((active ? 0.66 : focused ? 0.35 : 0.1) * fog)), style: StrokeStyle(lineWidth: active ? 1.6 : focused ? 1 : 0.6, dash: link.isSemantic ? [3, 5] : []))
            if active {
                let mid = CGPoint(x: (segment.0.point.x + segment.1.point.x) / 2, y: (segment.0.point.y + segment.1.point.y) / 2)
                context.fill(Path(ellipseIn: CGRect(x: mid.x - 1.5, y: mid.y - 1.5, width: 3, height: 3)), with: .color(link.color.opacity(0.8)))
            }
        }
        for item in placed { drawNode(item, context: context) }
    }

    private func drawNode(_ item: AtlasPlacedNode, context: GraphicsContext) {
        let focus = item.node.id == focusID
        let fog = min(1, max(0.25, 25 / item.projection.depth))
        let point = item.projection.point
        let radius = CGFloat(min(5, max(1.8, item.projection.scale * 0.12)))
        if item.node.emphasized || focus {
            let haloRadius = radius * (focus ? 5 : 3)
            context.fill(Path(ellipseIn: CGRect(x: point.x - haloRadius, y: point.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)), with: .color(item.node.color.opacity(0.055)))
        }
        if !item.labelVisible {
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(item.node.color.opacity(fog * (item.node.emphasized ? 0.9 : 0.55))))
            return
        }
        let labelPoint = item.labelPoint
        if hypot(labelPoint.x - point.x, labelPoint.y - point.y) > 4 {
            var tether = Path()
            tether.move(to: point)
            tether.addLine(to: labelPoint)
            context.stroke(tether, with: .color(item.node.color.opacity(0.22 * fog)), lineWidth: 0.7)
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(item.node.color.opacity(0.65 * fog)))
        }
        let capsule = Path(roundedRect: item.rect, cornerRadius: item.rect.height / 2)
        context.fill(capsule, with: .color(focus ? item.node.color.opacity(0.94) : Color(red: 0.055, green: 0.072, blue: 0.105).opacity(0.97)))
        context.stroke(capsule, with: .color(item.node.color.opacity((focus ? 1 : item.node.emphasized ? 0.65 : 0.35) * fog)), lineWidth: focus ? 1.2 : 0.7)
        let marker = CGRect(x: item.rect.minX + 10, y: labelPoint.y - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: marker), with: .color(focus ? Color.black.opacity(0.7) : item.node.color.opacity(fog)))
        context.draw(Text(item.title)
            .font(.system(size: item.fontSize, weight: focus ? .semibold : .medium))
            .foregroundStyle(focus ? Color(red: 0.035, green: 0.055, blue: 0.05) : Color.white.opacity(0.76 + 0.2 * fog)),
                     at: CGPoint(x: labelPoint.x + 5, y: labelPoint.y))
    }

    private func drawStars(context: GraphicsContext, size: CGSize) {
        for index in 0..<180 {
            let i = Double(index)
            let world = SIMD3<Double>(sin(i * 127.1) * 70, sin(i * 311.7) * 45, cos(i * 74.7) * 80)
            guard let point = camera.project(world, size: size), CGRect(origin: .zero, size: size).contains(point.point) else { continue }
            let radius: CGFloat = index % 9 == 0 ? 1 : 0.5
            context.fill(Path(ellipseIn: CGRect(x: point.point.x, y: point.point.y, width: radius, height: radius)), with: .color(Color.white.opacity(index % 9 == 0 ? 0.19 : 0.08)))
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let floor = -10.0
        for index in -15...15 {
            let coordinate = Double(index) * 4
            drawWorldLine(SIMD3(coordinate, floor, -60), SIMD3(coordinate, floor, 60), context: context, size: size, opacity: index == 0 ? 0.12 : 0.045)
            drawWorldLine(SIMD3(-60, floor, coordinate), SIMD3(60, floor, coordinate), context: context, size: size, opacity: index == 0 ? 0.12 : 0.045)
        }
    }

    /// Clip world lines against the near plane before projecting them. Walking
    /// through the floor grid must not produce huge reversed lines.
    private func drawWorldLine(_ start: SIMD3<Double>, _ end: SIMD3<Double>, context: GraphicsContext, size: CGSize, opacity: Double) {
        guard let segment = projectedSegment(start, end, size: size) else { return }
        var line = Path()
        line.move(to: segment.0.point)
        line.addLine(to: segment.1.point)
        context.stroke(line, with: .color(Color(red: 0.49, green: 0.63, blue: 0.67).opacity(opacity)), lineWidth: 0.7)
    }

    private func projectedSegment(_ start: SIMD3<Double>, _ end: SIMD3<Double>, size: CGSize) -> (AtlasProjection, AtlasProjection)? {
        var a = start
        var b = end
        let aDepth = simd_dot(a - camera.eye, camera.forward)
        let bDepth = simd_dot(b - camera.eye, camera.forward)
        let near = 0.5
        guard aDepth > near || bDepth > near else { return nil }
        if aDepth < near { a = start + (end - start) * ((near - aDepth) / (bDepth - aDepth)) }
        if bDepth < near { b = start + (end - start) * ((near - aDepth) / (bDepth - aDepth)) }
        guard let p = camera.project(a, size: size), let q = camera.project(b, size: size) else { return nil }
        return (p, q)
    }
}
