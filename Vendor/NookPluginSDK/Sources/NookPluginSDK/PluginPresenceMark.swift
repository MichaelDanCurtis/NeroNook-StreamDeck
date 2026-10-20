import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor private enum PluginPresenceImages {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static let presence = PluginVisualAssets.url(path:"/__nook_sdk__/presence.png").flatMap { NSImage(contentsOf:$0) }
    static let particles = PluginVisualAssets.url(path:"/__nook_sdk__/particles.png").flatMap { NSImage(contentsOf:$0) }
    static func image(particle:Bool = false) -> Image { Image(nsImage:(particle ? particles:presence) ?? NSImage()) }
    #else
    static let presence = PluginVisualAssets.data(path:"/__nook_sdk__/presence.png").flatMap(UIImage.init(data:))
    static let particles = PluginVisualAssets.data(path:"/__nook_sdk__/particles.png").flatMap(UIImage.init(data:))
    static func image(particle:Bool = false) -> Image { Image(uiImage:(particle ? particles:presence) ?? UIImage()) }
    #endif
}


/// Approved elemental identity, rendered once by the shared native USDZ surface.
public struct PluginPresenceMark: View {
    public var size: CGFloat
    public var activity: Double
    public var persona: PluginAvatarPersona
    public var speech: PluginAvatarSpeech
    public var expression: PluginExpressionPose?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.pluginHasSeasonalSurface) private var hasSeasonalSurface
    @State private var floating = false
    public init(size: CGFloat = 64, activity: Double = 0, persona: PluginAvatarPersona = .nero, speech: PluginAvatarSpeech = .init(), expression: PluginExpressionPose? = nil) {
        self.size=size; self.activity=activity; self.persona=persona; self.speech=speech; self.expression=expression
    }
    public var body: some View {
        let motion = !reduceMotion && !appearance.reduceMotion
        ZStack {
            PluginAvatarSceneBackdrop(scene: size >= 80 && !hasSeasonalSurface ? appearance.seasonalScene : nil)
            PluginAvatarSurface(persona: persona, theme: appearance.avatars?.palette(persona, fallback: appearance.theme.id) ?? appearance.theme.id, speech: speech, expression: expression ?? speech.expression ?? .init(), reducedMotion: !motion, opaque: appearance.reduceTransparency || appearance.increasedContrast, style: appearance.avatars?.style(persona) ?? "elemental")
        }
            .id(persona.rawValue + (appearance.avatars?.style(persona) ?? "elemental"))
            .frame(width:size,height:size)
            .offset(y:motion ? (floating ? -size*0.025:size*0.025):0)
            .rotationEffect(.degrees(motion ? (floating ? 1.5:-1.5):0))
            .scaleEffect(motion ? 1+min(1,max(0,activity))*0.04:1)
            .animation(motion ? .easeInOut(duration:0.45):nil,value:floating)
            .animation(motion ? .easeOut(duration:0.16):nil,value:activity)
            .onAppear { floating=true }.onDisappear { floating=false }
            .accessibilityHidden(true)
    }
}

/// Two composited layers give a dense particle substrate slow parallax without
/// millions of per-frame drawing calls. Attach once per decorative window.
public struct PluginParticleAtmosphere: View {
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false
    public init() {}
    public var body: some View {
        let motion = !reduceMotion && !appearance.reduceMotion
        GeometryReader { geometry in
            if !reduceTransparency && !appearance.reduceTransparency && !appearance.increasedContrast {
                ZStack {
                    ForEach(0..<2) { layer in
                        PluginPresenceImages.image(particle:true).resizable().scaledToFill()
                            .frame(width:geometry.size.width*1.18,height:geometry.size.height*1.18)
                            .rotationEffect(.degrees(layer == 0 ? -12:163))
                            .offset(x:motion && drift ? 15:-15,y:motion && drift ? -8:8)
                            .scaleEffect(motion && drift ? 1.03:1)
                            .opacity((appearance.scheme == .dark ? 0.23:0.14) * (layer == 0 ? 1:0.45))
                    }
                }.frame(width:geometry.size.width,height:geometry.size.height).clipped()
            }
        }.animation(motion ? .easeInOut(duration:18).repeatForever(autoreverses:true):nil,value:drift)
            .onAppear { drift=true }.onDisappear { drift=false }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
