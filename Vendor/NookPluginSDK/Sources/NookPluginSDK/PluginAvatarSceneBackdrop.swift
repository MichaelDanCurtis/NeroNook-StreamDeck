import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
#endif

/// Bounded original vector scene. No timer, display link, particle emitter or
/// hidden animation loop. Each update paints at most 24 static particles and
/// twelve stages in one Canvas; accessibility removes decorative detail.
public struct PluginAvatarSceneBackdrop: View {
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var entrance = 1.0
    @State private var animatedStage: String?
    @State private var entranceTask: Task<Void, Never>?
    public var scene: PluginSeasonalScene?
    public init(scene: PluginSeasonalScene? = nil) { self.scene = scene }
    public var body: some View {
        GeometryReader { geometry in
            let quiet = appearance.reduceTransparency || appearance.increasedContrast || systemReduceTransparency || systemContrast == .increased
            let dark = appearance.scheme == .dark
            ZStack {
                Ellipse().fill(Color(pluginHex: appearance.palette.text).opacity(quiet ? 0.12 : dark ? 0.06 : 0.12))
                    .frame(width: geometry.size.width * 0.72, height: geometry.size.height * 0.15)
                    .blur(radius: quiet ? 0 : 10).offset(y: geometry.size.height * 0.32)
                if !quiet {
                    Ellipse().fill(RadialGradient(colors: [Color(pluginHex: appearance.palette.accent).opacity(dark ? 0.14 : 0.09), .clear], center: .center, startRadius: 0, endRadius: geometry.size.width * 0.5))
                }
                if let scene, !quiet {
                    Canvas { context, size in
                        func symbol(_ text: String, _ x: Double, _ y: Double, _ scale: Double) {
                            context.draw(Text(text).font(.system(size: size.width * scale)), at: CGPoint(x: size.width * x, y: size.height * y))
                        }
                        // Original vector tree, gift, star and ornaments; all
                        // stages use deterministic positions rather than timers.
                        if scene.holiday == .christmas {
                            let tree = Path { p in for (i, point) in [(0.18,0.34),(0.09,0.56),(0.13,0.56),(0.06,0.70),(0.10,0.70),(0.04,0.82),(0.32,0.82),(0.26,0.70),(0.30,0.70),(0.23,0.56),(0.27,0.56)].enumerated() {
                                let pnt = CGPoint(x:size.width * point.0,y:size.height * point.1)
                                if i == 0 { p.move(to:pnt) } else { p.addLine(to:pnt) }
                            }; p.closeSubpath() }
                            context.fill(tree, with: .color(Color(pluginHex: dark ? "#679781" : "#3D6D54")))
                            if scene.day >= 2 { symbol("🎁", 0.82, 0.81, 0.16) }
                            if scene.day >= 3 { symbol("✦", 0.18, 0.29, 0.11) }
                            if scene.day >= 4 {
                                for i in 0..<min(9, scene.day) {
                                    let x = 0.12 + Double(i % 3) * 0.055, y = 0.56 + Double(i / 3) * 0.08
                                    context.fill(Path(ellipseIn: CGRect(x: size.width * x, y: size.height * y, width: 3, height: 3)), with: .color(.yellow.opacity(0.75)))
                                }
                            }
                            if scene.day >= 5 { symbol("⌁", 0.16, 0.64, 0.16) }
                            if scene.day >= 6 { symbol("🎁", 0.69, 0.87, 0.11) }
                            if scene.day >= 7 { symbol("●", 0.21, 0.69, 0.06) }
                            if scene.day >= 8 { symbol("❄", 0.74, 0.22, 0.09) }
                            if scene.day >= 9 { symbol("❦", 0.84, 0.36, 0.12) }
                            if scene.day >= 10 { symbol("✧", 0.8, 0.57, 0.12) }
                            if scene.day >= 11 { symbol("✧", 0.38, 0.21, 0.08) }
                            if scene.day >= 12 { symbol("✦", 0.6, 0.09, 0.12) }
                        } else if scene.holiday == .halloween {
                            symbol("🎃", 0.18, 0.8, 0.2)
                            if scene.day >= 3 { symbol("☾", 0.8, 0.28, 0.15) }
                            if scene.day >= 4 { symbol("🎃", 0.83, 0.84, 0.13) }
                        } else {
                            symbol("🍂", 0.15, 0.72, 0.19)
                            if scene.day >= 2 { symbol("🍁", 0.84, 0.8, 0.15) }
                            if scene.day >= 3 { symbol("🦃", 0.82, 0.57, 0.2) }
                        }
                        if scene.intensity != .off && !appearance.reduceMotion && !systemReduceMotion {
                            for i in 0..<scene.particleCap {
                                let x: Double = Double((i * 37 + 11) % 97) / 100.0
                                let baseY: Double = Double((i * 23 + 7) % 89) / 100.0
                                let y: Double = baseY + (1.0 - entrance) * 0.07
                                context.fill(Path(ellipseIn: CGRect(x: size.width * x, y: size.height * y, width: 2, height: 2)), with: .color(Color(pluginHex: appearance.palette.text).opacity(0.3 * entrance)))
                            }
                        }
                    }.opacity(entrance).scaleEffect(0.985 + 0.015 * entrance)
                }
            }
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .background(PluginAvatarSceneVisibilityProbe(visible: $visible))
        #else
        .onAppear { visible = true; startEntrance() }
        #endif
        .onChange(of: visible) { _ in startEntrance() }
        .onChange(of: scene) { _ in startEntrance() }
        .onChange(of: appearance.reduceMotion) { _ in startEntrance() }
        .onChange(of: systemReduceMotion) { _ in startEntrance() }
        .onChange(of: appearance.reduceTransparency) { _ in startEntrance() }
        .onChange(of: appearance.increasedContrast) { _ in startEntrance() }
        .onChange(of: systemReduceTransparency) { _ in startEntrance() }
        .onChange(of: systemContrast) { _ in startEntrance() }
        .onChange(of: scenePhase) { phase in
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            // AppKit window visibility is authoritative; inactive applications
            // can still have a fully visible review or Nook window.
            #else
            visible = phase == .active; startEntrance()
            #endif
        }
        .onDisappear { entranceTask?.cancel(); visible = false; withTransaction(Transaction(animation: nil)) { entrance = 1 } }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func startEntrance() {
        entranceTask?.cancel(); entranceTask = nil
        let duration = PluginSeasonalAnimationPolicy.duration(intensity: scene?.intensity ?? .off, visible: visible, reducedMotion: appearance.reduceMotion || systemReduceMotion, reducedTransparency: appearance.reduceTransparency || systemReduceTransparency, increasedContrast: appearance.increasedContrast || systemContrast == .increased)
        guard let scene, duration > 0 else { withTransaction(Transaction(animation: nil)) { entrance = 1 }; return }
        let key = scene.celebrationKey + "." + String(scene.day)
        guard animatedStage != key else { withTransaction(Transaction(animation: nil)) { entrance = 1 }; return }
        animatedStage = key
        withTransaction(Transaction(animation: nil)) { entrance = 0.2 }
        entranceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: duration)) { entrance = 1 }
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// Window visibility metadata only, with event-driven observation and no timer.
private struct PluginAvatarSceneVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.changed = { value in if visible != value { visible = value } }; return probe }
    func updateNSView(_ view: Probe, context: Context) { view.changed = { value in if visible != value { visible = value } }; view.report() }
    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observations: [AnyCancellable] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); observations.removeAll()
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.publisher(for: name, object: window).receive(on: RunLoop.main).sink { [weak self] _ in self?.report() }.store(in: &observations)
            }
            report()
        }
        func report() {
            let value = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor } ?? false
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }
    }
}
#endif
