import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
private typealias SeasonalRasterImage = NSImage
#else
import UIKit
private typealias SeasonalRasterImage = UIImage
#endif

@MainActor private enum PluginSeasonalRasterImages {
    static let cache:NSCache<NSString,SeasonalRasterImage> = {
        let value=NSCache<NSString,SeasonalRasterImage>();value.countLimit=16;value.totalCostLimit=32*1024*1024;return value
    }()
    static func image(_ name:String) -> Image? {
        if let value=cache.object(forKey:name as NSString) { return view(value) }
        guard let url=PluginSeasonalArtCatalog.url(path:"/__nook_sdk__/"+name) else { return nil }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let value=NSImage(contentsOf:url) else { return nil }
        #else
        guard let value=UIImage(contentsOfFile:url.path) else { return nil }
        #endif
        cache.setObject(value,forKey:name as NSString,cost:max(1,Int(value.size.width*value.size.height*4)));return view(value)
    }
    static func view(_ image:SeasonalRasterImage) -> Image {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Image(nsImage:image)
        #else
        return Image(uiImage:image)
        #endif
    }
}

/// Detailed scenery is rendered once offline, then composited as cached local
/// image layers. A separate finite overlay supplies light/snow motion; it never
/// changes avatar speech, gaze, input focus, accounts or action authority.
public struct PluginHolidaySurface<Content:View>: View {
    public var scene:PluginSeasonalScene?
    public var layout:PluginSeasonalSurfaceLayout
    private let content:Content
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.accessibilityReduceTransparency) private var reducedTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var visible=false
    public init(scene:PluginSeasonalScene?,layout:PluginSeasonalSurfaceLayout = .voice,@ViewBuilder content:()->Content) {
        self.scene=scene;self.layout=layout;self.content=content()
    }
    public var body:some View {
        let plan=PluginSeasonalArtPlan.make(scene:scene,layout:layout)
        let quiet=appearance.increasedContrast || contrast == .increased
        ZStack {
            if let plan,!quiet,let catalog=PluginSeasonalArtCatalog.bundled {
                PluginSeasonalRasterLayer(plan:plan,catalog:catalog,dark:appearance.scheme == .dark)
                PluginSeasonalRasterOverlay(plan:plan,catalog:catalog,enabled:visible && !reducedMotion && !appearance.reduceMotion && !reducedTransparency && !appearance.reduceTransparency)
                    .mask(PluginHolidayMask(regions:(try? layout.decorationRegions(protectAvatar:false)) ?? []))
            }
            content
        }.environment(\.pluginHasSeasonalSurface,plan != nil)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .background(PluginHolidayVisibility(visible:$visible))
        #else
        .onAppear { visible=true }.onDisappear { visible=false }
        #endif
    }
}

private struct PluginHolidayMask: Shape {
    let regions:[PluginSeasonalRectangle]
    func path(in rect:CGRect)->Path {
        var path=Path()
        for r in regions { path.addRect(CGRect(x:r.x*rect.width,y:r.y*rect.height,width:r.width*rect.width,height:r.height*rect.height)) }
        return path
    }
}
private struct PluginSeasonalRasterLayer:View {
    let plan:PluginSeasonalArtPlan
    let catalog:PluginSeasonalArtCatalog
    let dark:Bool
    var body:some View {
        Canvas { context,size in
            for layer in plan.layers.sorted(by:{$0.depth < $1.depth}) {
                guard let asset=catalog.asset(layer.asset),let image=PluginSeasonalRasterImages.image(dark ? asset.files.dark:asset.files.light) else { continue }
                let frame=asset.fitted(in:layer.frame,viewportAspect:size.width/max(1,size.height))
                let rect=CGRect(x:frame.x*size.width,y:frame.y*size.height,width:frame.width*size.width,height:frame.height*size.height)
                var local=context
                if layer.mirrored { local.translateBy(x:rect.midX*2,y:0);local.scaleBy(x:-1,y:1) }
                local.draw(image,in:rect)
            }
        }.mask(PluginHolidayMask(regions:(try? plan.layout.decorationRegions(protectAvatar:false)) ?? []))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct PluginSeasonalRasterOverlay:View {
    let plan:PluginSeasonalArtPlan
    let catalog:PluginSeasonalArtCatalog
    let enabled:Bool
    @State private var running=false
    @State private var start=Date()
    @State private var epoch=UUID()
    @State private var presentationID=""
    @State private var deadline=Date.distantPast
    private var sceneID:String { plan.scene.celebrationKey+".\(plan.scene.day).\(plan.scene.intensity.rawValue)" }
    private var runID:String { sceneID+".\(enabled)" }
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/12,paused:!running)) { timeline in
            let elapsed=running ? max(0,timeline.date.timeIntervalSince(start)):0
            Canvas { context,size in
                guard running else { return }
                for layer in plan.layers {
                    guard let asset=catalog.asset(layer.asset) else { continue }
                    let frame=asset.fitted(in:layer.frame,viewportAspect:size.width/max(1,size.height))
                    for (index,anchor) in asset.overlayAnchors.enumerated() {
                        let x=frame.x+(layer.mirrored ? 1-anchor.x:anchor.x)*frame.width,y=frame.y+anchor.y*frame.height
                        let radius=max(1.4,anchor.radius*frame.height*size.height*2.8)
                        let glow=0.18+0.18*(sin(elapsed*1.6+Double(index)*1.9)+1)/2
                        let point=CGPoint(x:x*size.width,y:y*size.height)
                        let colors=[Color(pluginHex:anchor.color).opacity(glow),.clear]
                        context.fill(Path(ellipseIn:CGRect(x:point.x-radius*3,y:point.y-radius*3,width:radius*6,height:radius*6)),with:.radialGradient(Gradient(colors:colors),center:point,startRadius:0,endRadius:radius*3))
                    }
                }
                for particle in PluginSeasonalMotion.sample(scene:plan.scene,overlay:plan.overlay,elapsed:elapsed) {
                    let x=particle.x,y=particle.y
                    if plan.layout.avatar.intersects(.init(x:max(0,x-0.008),y:max(0,y-0.008),width:0.016,height:0.016)) { continue }
                    var local=context
                    local.translateBy(x:x*size.width,y:y*size.height)
                    local.rotate(by:.radians(particle.rotation))
                    local.scaleBy(x:particle.size,y:particle.size)
                    let color:Color
                    switch particle.kind {
                    case .bat: color=Color(pluginHex:"#69517d")
                    case .leaf: color=Color(pluginHex:"#c47732")
                    case .petal,.heart: color=Color(pluginHex:"#da8099")
                    case .snow: color=Color(pluginHex:"#eef6ff")
                    default: color=Color(pluginHex:"#e7bf70")
                    }
                    local.fill(PluginSeasonalParticlePath.path(kind:particle.kind,phase:particle.phase),with:.color(color.opacity(particle.opacity)))
                }

            }
        }.task(id:runID) {
            let token=UUID();epoch=token;running=false
            guard enabled,plan.animationSeconds > 0 else { return }
            if presentationID != sceneID { presentationID=sceneID;start=Date();deadline=start.addingTimeInterval(plan.animationSeconds) }
            let remaining=deadline.timeIntervalSinceNow
            guard remaining > 0 else { return };running=true
            do { try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000)) } catch { }
            guard epoch == token else { return };running=false
        }.onDisappear { epoch=UUID();running=false }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private struct PluginHolidayVisibility:NSViewRepresentable {
    @Binding var visible:Bool
    func makeNSView(context:Context)->Probe { let v=Probe();v.changed={ visible=$0 };return v }
    func updateNSView(_ view:Probe,context:Context) { view.changed={ if visible != $0 { visible=$0 } };view.report() }
    final class Probe:NSView {
        var changed:((Bool)->Void)?
        private var observations:[AnyCancellable]=[]
        override func hitTest(_ point:NSPoint)->NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();observations.removeAll()
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.publisher(for:name,object:window).receive(on:RunLoop.main).sink { [weak self] _ in self?.report() }.store(in:&observations)
            };report()
        }
        override func viewDidHide() { super.viewDidHide();report() }
        override func viewDidUnhide() { super.viewDidUnhide();report() }
        func report() {
            let value=window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor } ?? false
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }
    }
}
#endif

private enum PluginSeasonalParticlePath {
    static func path(kind:PluginSeasonalParticle.Kind,phase:Double)->Path {
        var p=Path()
        switch kind {
        case .snow: p.addEllipse(in:CGRect(x:-1,y:-1,width:2,height:2))
        case .confetti: p.addRoundedRect(in:CGRect(x:-0.5,y:-1.2,width:1,height:2.4),cornerSize:CGSize(width:0.2,height:0.2))
        case .heart:
            p.move(to:CGPoint(x:0,y:1));p.addCurve(to:CGPoint(x:0,y:-0.55),control1:CGPoint(x:-2,y:-0.25),control2:CGPoint(x:-0.8,y:-1.5));p.addCurve(to:CGPoint(x:0,y:1),control1:CGPoint(x:0.8,y:-1.5),control2:CGPoint(x:2,y:-0.25))
        case .bat:
            let wing=0.5+sin(phase)*0.4
            p.move(to:CGPoint(x:0,y:0.1));p.addLine(to:CGPoint(x:-1.6,y:-wing));p.addQuadCurve(to:CGPoint(x:-0.4,y:0.4),control:CGPoint(x:-1,y:0));p.addLine(to:CGPoint(x:0,y:0.2));p.addLine(to:CGPoint(x:0.4,y:0.4));p.addQuadCurve(to:CGPoint(x:1.6,y:-wing),control:CGPoint(x:1,y:0));p.closeSubpath()
        case .leaf,.petal:
            p.move(to:CGPoint(x:-1,y:0));p.addQuadCurve(to:CGPoint(x:1,y:0),control:CGPoint(x:0,y:-1.2));p.addQuadCurve(to:CGPoint(x:-1,y:0),control:CGPoint(x:0,y:0.8))
        case .star:
            for i in 0..<8 { let angle=Double(i)*Double.pi/4-Double.pi/2,r=i%2 == 0 ? 1.0:0.3;let v=CGPoint(x:cos(angle)*r,y:sin(angle)*r);if i == 0 { p.move(to:v) } else { p.addLine(to:v) } };p.closeSubpath()
        }
        return p
    }
}
