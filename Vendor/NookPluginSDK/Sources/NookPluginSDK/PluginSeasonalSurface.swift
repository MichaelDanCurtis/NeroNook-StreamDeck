import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
@preconcurrency import SceneKit
#endif

private struct PluginSeasonalSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// A full-surface composition owns decoration; avatar marks retain lighting
    /// but suppress their small legacy seasonal scene inside this container.
    var pluginHasSeasonalSurface: Bool {
        get { self[PluginSeasonalSurfaceKey.self] }
        set { self[PluginSeasonalSurfaceKey.self] = newValue }
    }
}

/// Optional decoration behind plugin-authored content. Normalized reservations
/// always exclude the live avatar and controls. Invalid data fails closed to
/// plain content. A scene never captures input, opens windows or takes focus.
public struct PluginSeasonalSurface<Content: View>: View {
    public var composition: PluginSeasonalComposition?
    private let content: Content
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init(composition: PluginSeasonalComposition?, @ViewBuilder content: () -> Content) {
        self.composition = composition; self.content = content()
    }
    private var accepted: PluginSeasonalComposition? {
        guard let composition,
              (try? composition.validate()) != nil else { return nil }
        return composition
    }
    public var body: some View {
        ZStack {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            if let accepted {
                GeometryReader { geometry in
                    ForEach(accepted.decorations.filter { [.evergreen,.gift,.house,.lantern].contains($0.asset) }) { decoration in
                        Ellipse().fill(RadialGradient(colors: [.black.opacity(appearance.scheme == .dark ? 0.35 : 0.16),.clear], center: .center, startRadius: 0, endRadius: geometry.size.width * decoration.frame.width * 0.48))
                            .frame(width: geometry.size.width * decoration.frame.width, height: geometry.size.height * 0.022)
                            .blur(radius: 3)
                            .position(x: geometry.size.width * (decoration.frame.x + decoration.frame.width/2), y: geometry.size.height * (decoration.frame.y + decoration.frame.height))
                    }
                    PluginSeasonalNativeSurface(composition: accepted, aspect: Double(max(1, geometry.size.width) / max(1, geometry.size.height)),
                    dark: appearance.scheme == .dark,
                    animated: !reduceMotion && !appearance.reduceMotion && !reduceTransparency && !appearance.reduceTransparency && !appearance.increasedContrast)
                }
                    // Rear trees may sit behind the separate live avatar; its
                    // actual alpha silhouette occludes them naturally. Near
                    // props cannot intersect that anchor (manifest validation).
                    .mask(PluginSeasonalAllowedMask(regions: (try? accepted.layout.decorationRegions(protectAvatar: false)) ?? []))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            #endif
            content
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .environment(\.pluginHasSeasonalSurface, accepted != nil)
        #endif
    }
}

private struct PluginSeasonalAllowedMask: Shape {
    let regions: [PluginSeasonalRectangle]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for region in regions {
            path.addRect(CGRect(x: rect.minX + region.x * rect.width, y: rect.minY + region.y * rect.height,
                                width: region.width * rect.width, height: region.height * rect.height))
        }
        return path
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// Demand-rendered scene: no idle clock or continuous rendering. Only the
/// finite entrance has actions; hiding, occlusion or accessibility changes
/// settles every node immediately and does not replay on returning to a window.
@MainActor final class PluginSeasonalNativeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let art = SCNNode()
    private var settled: [(SCNNode, SCNVector3)] = []
    init(composition: PluginSeasonalComposition, aspect: Double, dark: Bool) {
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 20
        camera.camera?.wantsHDR = false
        camera.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(camera); scene.rootNode.addChildNode(art)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = dark ? 140 : 230
        ambient.light?.color = NSColor(calibratedRed: 0.84, green: 0.90, blue: 1, alpha: 1)
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = dark ? 370 : 460
        key.light?.color = NSColor(calibratedRed: 1, green: 0.88, blue: 0.71, alpha: 1)
        key.position = SCNVector3(-3, 5, 6); scene.rootNode.addChildNode(key)
        for decoration in composition.decorations {
            let node = PluginSeasonalNativeArt.make(decoration.asset, variant: decoration.variant)
            node.name = decoration.id
            // A small authored turn reveals depth without moving screen-space
            // anchors or tilting the whole scene beneath the live interface.
            if [.gift,.house,.lantern].contains(decoration.asset) {
                node.eulerAngles = SCNVector3(-0.09, decoration.variant % 2 == 0 ? -0.15 : 0.15, 0)
            }
            let (minimum, maximum) = node.boundingBox
            let width = Double(maximum.x - minimum.x), height = Double(maximum.y - minimum.y)
            guard width > 0, height > 0 else { continue }
            let scale = min(decoration.frame.width * 2 * aspect / width, decoration.frame.height * 2 / height)
            node.scale = SCNVector3(scale, scale, scale)
            let x = (decoration.frame.x + decoration.frame.width / 2 - 0.5) * 2 * aspect
            let y = 1 - 2 * (decoration.frame.y + decoration.frame.height)
            node.position = SCNVector3(x, y, decoration.depth * 0.25)
            art.addChildNode(node); settled.append((node, node.position))
        }
    }
    func enter(duration: Double) {
        guard duration > 0 else { settle(); return }
        for (index, pair) in settled.enumerated() {
            let (node, destination) = pair
            node.opacity = 0; node.position.y = destination.y - 0.025
            let delay = min(0.20, Double(index) * 0.009)
            let move = SCNAction.move(to: destination, duration: duration - delay)
            move.timingMode = .easeOut
            node.runAction(.sequence([.wait(duration: delay), .group([.fadeIn(duration: duration - delay), move])]))
        }
    }
    func settle() {
        for (node, position) in settled { node.removeAllActions(); node.opacity = 1; node.position = position }
    }
}

@MainActor private final class PluginSeasonalSCNView: SCNView {
    var onVisibility: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.notifyVisibility() }
                })
            }
        }
        notifyVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); notifyVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); notifyVisibility() }
    func notifyVisibility() {
        onVisibility?(window != nil && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true)
    }
    func dispose() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        onVisibility = nil; scene = nil; isPlaying = false
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PluginSeasonalNativeSurface: NSViewRepresentable {
    let composition: PluginSeasonalComposition
    let aspect: Double
    let dark: Bool
    let animated: Bool
    final class Coordinator {
        var configuration: PluginSeasonalComposition?
        var dark = false
        var aspect: Double = 0
        var art: PluginSeasonalNativeScene?
        var entrancePending = false
        var animated = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PluginSeasonalSCNView {
        let view = PluginSeasonalSCNView()
        view.backgroundColor = .clear; view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false; view.rendersContinuously = false
        view.isPlaying = false; view.antialiasingMode = .multisampling4X
        view.onVisibility = { [weak view, weak coordinator = context.coordinator] visible in
            guard let coordinator else { return }
            if visible && coordinator.entrancePending {
                coordinator.entrancePending = false
                coordinator.art?.enter(duration: PluginSeasonalAnimationPolicy.duration(intensity: coordinator.configuration?.scene.intensity ?? .off,
                    visible: true, reducedMotion: !coordinator.animated, reducedTransparency: false, increasedContrast: false))
            } else if !visible { coordinator.art?.settle(); coordinator.entrancePending = false }
            view?.setNeedsDisplay(view?.bounds ?? .zero)
        }
        return view
    }
    func updateNSView(_ view: PluginSeasonalSCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.animated = animated
        if coordinator.configuration != composition || coordinator.dark != dark || abs(coordinator.aspect - aspect) > 0.001 {
            coordinator.art?.settle()
            let art = PluginSeasonalNativeScene(composition: composition, aspect: aspect, dark: dark)
            coordinator.art = art; view.scene = art.scene; view.pointOfView = art.camera
            coordinator.configuration = composition; coordinator.dark = dark; coordinator.aspect = aspect
            coordinator.entrancePending = animated
            if coordinator.entrancePending { view.notifyVisibility() }
        }
        if !animated { coordinator.art?.settle(); coordinator.entrancePending = false }
        view.setNeedsDisplay(view.bounds)
    }
    static func dismantleNSView(_ view: PluginSeasonalSCNView, coordinator: Coordinator) {
        coordinator.art?.settle(); coordinator.art = nil; view.dispose()
    }
}
#endif
