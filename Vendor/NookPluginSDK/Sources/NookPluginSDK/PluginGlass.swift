import SwiftUI

/// Shared presentation only. Reading and credential cards retain opaque fills.
public struct PluginGlassSurface: View {
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public var radius: CGFloat
    public var reading: Bool
    public var atmosphere: Bool
    public init(radius: CGFloat = 20, reading: Bool = false, atmosphere: Bool = false) { self.radius=radius; self.reading=reading; self.atmosphere=atmosphere }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius:radius,style:.continuous)
        let solid = reduceTransparency || appearance.reduceTransparency || appearance.increasedContrast
        ZStack {
            if !solid && !reading { shape.fill(.ultraThinMaterial) }
            shape.fill(Color(pluginHex:appearance.palette.surface).opacity(solid || reading ? 1 : min(0.48,appearance.theme.style.shellOpacity*0.58)))
            if atmosphere && !solid && !reading { PluginParticleAtmosphere().clipShape(shape) }
            if !solid {
                shape.fill(LinearGradient(colors:[.white.opacity(appearance.scheme == .light ? 0.32:0.07),.clear,.white.opacity(0.015)],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
            // Full-window/sidebar fills are continuous glass, not bordered cards.
            // Their zero-radius edges must not draw a chamfer under the titlebar.
            if radius>0 {
            shape.strokeBorder(Color(pluginHex:appearance.palette.border).opacity(appearance.increasedContrast ? 1:0.22),lineWidth:appearance.increasedContrast ? 2:0.6 * appearance.theme.style.borderWidth)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Diffuse light lives inside the control, rather than tracing its perimeter.
public struct PluginGlassButtonStyle: ButtonStyle {
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal,14).padding(.vertical,8)
            .background {
                Capsule(style:.continuous).fill(Color(pluginHex:appearance.palette.elevated).opacity(appearance.reduceTransparency ? 1:0.65))
                    .overlay {
                        Capsule().fill(RadialGradient(colors:[Color(pluginHex:appearance.palette.accent).opacity(configuration.isPressed ? 0.2:0.08),.clear],center:.center,startRadius:0,endRadius:90))
                    }
                    .overlay(Capsule().strokeBorder(Color(pluginHex:appearance.palette.border).opacity(appearance.increasedContrast ? 1:0.24),lineWidth:appearance.increasedContrast ? 2:0.6))
            }
            .contentShape(Capsule()).opacity(enabled ? 1:0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion && !appearance.reduceMotion ? 0.98:1)
            .animation(reduceMotion || appearance.reduceMotion ? nil:.easeOut(duration:0.14),value:configuration.isPressed)
    }
}

/// A one-shot leading-edge reveal. It never changes layout, focus or hit testing.
/// Use a stable trigger for navigation; state/stream updates must not replay it.
private struct PluginReveal: ViewModifier {
    var trigger: String
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pluginAppearance) private var appearance
    @State private var shown = false
    func body(content: Content) -> some View {
        content.mask(alignment:index.isMultiple(of:2) ? .leading:.trailing) {
            GeometryReader { geometry in
                Rectangle().frame(width:geometry.size.width * (shown || reduceMotion || appearance.reduceMotion ? 1:0),height:geometry.size.height)
                    .frame(maxWidth:.infinity,alignment:index.isMultiple(of:2) ? .leading:.trailing)
            }
        }.task(id:trigger) { await reveal() }
    }
    @MainActor private func reveal() async {
        guard !reduceMotion && !appearance.reduceMotion else { shown=true;return }
        var transaction=Transaction();transaction.disablesAnimations=true
        withTransaction(transaction) { shown=false }
        if index > 0 { try? await Task.sleep(nanoseconds:UInt64(min(index,5)*45)*1_000_000) }
        else { await Task.yield() }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration:0.34)) { shown=true }
    }
}
extension View {
    public func pluginReveal(trigger:String = "entrance", index:Int = 0) -> some View { modifier(PluginReveal(trigger:trigger,index:max(0,index))) }
    public func pluginGlass(radius:CGFloat = 20, reading:Bool = false) -> some View { background(PluginGlassSurface(radius:radius,reading:reading)) }
}
