import SwiftUI
@preconcurrency import SceneKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
private typealias AvatarColor = NSColor
private typealias AvatarScalar = CGFloat
#else
import UIKit
private typealias AvatarColor = UIColor
private typealias AvatarScalar = Float
#endif

/// Shared native USDZ renderer. The original morph geometry is used directly;
/// idle source animations are removed so they cannot fight the output envelope.
@MainActor final class PluginAvatarScene {
    let scene = SCNScene()
    private let model = SCNNode()
    private var mouth: SCNMorpher?
    private var flex: SCNMorpher?
    private var currentTheme = ""
    private let persona: PluginAvatarPersona
    private let style: String
    private var joints: [(SCNNode, SCNVector3)] = []
    private var eyes: [(SCNNode,SCNVector3)] = []
    private var lastGaze = PluginAvatarGaze()
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private let pointer = PluginAvatarPointerSource()
    #endif
    init(persona: PluginAvatarPersona, style: String = "elemental") {
        self.persona = persona
        self.style = PluginAvatarStyles.model(style: style, persona: persona) == nil ? "elemental" : style
        if let url = PluginAvatarStyles.model(style: style, persona: persona) ?? PluginAvatarCatalog.model(persona: persona), let source = try? SCNScene(url: url) {
            for node in source.rootNode.childNodes { node.removeFromParentNode(); model.addChildNode(node) }
            model.enumerateChildNodes { node, _ in
                node.removeAllAnimations()
                if self.style == "illustration.monoline" {
                    node.geometry?.materials.forEach { material in
                        material.lightingModel = .constant; material.emission.contents = AvatarColor.black; material.emission.intensity = 0; material.isDoubleSided = true
                        if let imageURL = PluginAvatarStyles.illustration(style: self.style, persona: persona) {
                            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                            material.diffuse.contents = NSImage(contentsOf: imageURL)
                            #else
                            material.diffuse.contents = UIImage(contentsOfFile: imageURL.path)
                            #endif
                        }
                    }
                }
                if let morph = node.morpher {
                    for i in morph.targets.indices {
                        morph.setWeight(0, forTargetAt: i)
                        if morph.targets[i].name == "Speak" { self.mouth = morph }
                        if morph.targets[i].name == "Flex" { self.flex = morph }
                    }
                }
            }
            scene.rootNode.addChildNode(model)
            model.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix("Articulation_") == true { joints.append((node, node.eulerAngles)) }
                if node.name?.contains("_Eye_") == true, node.geometry != nil, let parent=node.parent {
                    eyes.append((node,parent.convertPosition(node.position,to:model)))
                }
            }
        }
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = persona == .nero ? 1.59 : 1.825
        camera.position = SCNVector3(2, persona == .nero ? 2 : 1.7, 7.5)
        camera.look(at: SCNVector3(0, persona == .ember ? 0.27 : 0, 0))
        if self.style == "illustration.monoline" { camera.position = SCNVector3(0,0,7.5); camera.look(at: SCNVector3(0,0,0)); camera.camera?.orthographicScale = 1.05 }
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 130
        scene.rootNode.addChildNode(ambient)
        for (position, intensity) in [(SCNVector3(-3,5,4), 260.0), (SCNVector3(4,2,2), 120.0), (SCNVector3(0,3,-4), 180.0)] {
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = intensity
            light.position = position; scene.rootNode.addChildNode(light)
        }
    }
    func update(theme: String, speech: PluginAvatarSpeech, reducedMotion: Bool, opaque: Bool) {
        SCNTransaction.begin(); SCNTransaction.animationDuration = speech.speaking && !reducedMotion && speech.level > 0 ? 0.09 : 0
        if style == "elemental" && currentTheme != theme {
            currentTheme = theme
            let colors = PluginAvatarCatalog.palette(theme: theme)?.avatars[persona.rawValue] ?? [:]
            model.enumerateChildNodes { node, _ in
                for material in node.geometry?.materials ?? [] {
                    let name = (material.name ?? "").lowercased()
                    let hex = name.contains("face") ? colors["face"] : name.contains("inner") ? colors["core"] : colors["body"]
                    if persona == .ember && !name.contains("face") {
                        material.diffuse.contents = Self.gradient(colors)
                        material.emission.contents = Self.gradient(colors); material.emission.intensity = 0.18
                    } else { material.diffuse.contents = Self.color(hex ?? "#D9E8E4") }
                    material.roughness.contents = 0.48
                }
            }
        }
        if opaque { model.enumerateChildNodes { node, _ in node.geometry?.materials.forEach { $0.transparency = 1 } } }
        mouth?.setWeight(PluginAvatarSpeech.mouthWeight(speech.level, speaking: speech.speaking, reducedMotion: reducedMotion), forTargetAt: 0)
        SCNTransaction.commit()
    }
    func look(_ gaze: PluginAvatarGaze, animated: Bool = true) {
        guard gaze != lastGaze else { return }; lastGaze=gaze
        SCNTransaction.begin(); SCNTransaction.animationDuration=animated ? 0.14:0
        let radians = Double.pi / 180
        model.eulerAngles=SCNVector3(AvatarScalar(gaze.pitchDegrees*radians),AvatarScalar(gaze.yawDegrees*radians),AvatarScalar(gaze.rollDegrees*radians))
        model.position=SCNVector3(AvatarScalar(gaze.offsetX),AvatarScalar(gaze.offsetY),0)
        for (eye,base) in eyes {
            var point=SCNVector3(base.x+AvatarScalar(gaze.x*(style == "illustration.monoline" ? 0.015:0.09)),base.y+AvatarScalar(gaze.y*(style == "illustration.monoline" ? 0.01:0.06)),base.z)
            if persona == .ember && style == "elemental" {
                let radius=base.x*base.x+base.y*base.y+base.z*base.z
                point.z=sqrt(max(0,radius-point.x*point.x-point.y*point.y))
            }
            eye.position=eye.parent?.convertPosition(point,from:model) ?? base
        }
        flex?.setWeight(gaze.x, forTargetAt: 0)
        for (joint, base) in joints {
            let sign: Double = joint.name?.contains("_L_") == true ? -1 : 1
            joint.eulerAngles = SCNVector3(base.x, base.y + AvatarScalar(gaze.y * 0.12), base.z + AvatarScalar(sign * gaze.x * 0.15))
        }
        SCNTransaction.commit()
    }
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    func followPointer(in view: NSView, reducedMotion: Bool) {
        guard !reducedMotion else { pointer.stop(); look(.init(),animated:false); return }
        pointer.start(view:view) { [weak self,weak view] sample in
            guard let self,let view else { return }
            guard let sample else { self.look(.init(),animated:false); return }
            self.look(.towards(pointer:.init(x:sample.x,y:sample.y),
                               center:.init(x:view.bounds.width/2,y:view.bounds.height/2),
                               range:.init(width:sample.rangeX,height:sample.rangeY)))
        }
    }
    func stopPointer() { pointer.stop(); look(.init(),animated:false) }
    #endif
    private static func color(_ hex: String) -> AvatarColor {
        let x = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return AvatarColor(red: CGFloat((x >> 16) & 255) / 255, green: CGFloat((x >> 8) & 255) / 255, blue: CGFloat(x & 255) / 255, alpha: 1)
    }
    private static func gradient(_ colors: [String: String]) -> CGImage? {
        let entries = ["base", "body", "tip"].map { color(colors[$0] ?? "#D98B6C").cgColor }
        guard let context = CGContext(data: nil, width: 8, height: 256, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: entries as CFArray, locations: [0,0.4,1]) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0,y: 0), end: CGPoint(x: 0,y: 256), options: [])
        return context.makeImage()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
struct PluginAvatarSurface: NSViewRepresentable {
    let persona: PluginAvatarPersona; let theme: String; let speech: PluginAvatarSpeech; let reducedMotion: Bool; let opaque: Bool
    var style: String = "elemental"
    func makeCoordinator() -> PluginAvatarScene { PluginAvatarScene(persona: persona, style: style) }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(); view.scene = context.coordinator.scene; view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 24; view.isPlaying = false; view.rendersContinuously = false
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(theme: theme, speech: speech, reducedMotion: reducedMotion, opaque: opaque)
        context.coordinator.followPointer(in:view,reducedMotion:reducedMotion)
    }
    static func dismantleNSView(_ view: SCNView, coordinator: PluginAvatarScene) { coordinator.stopPointer(); view.isPlaying = false; view.scene = nil }
}
#else
struct PluginAvatarSurface: UIViewRepresentable {
    let persona: PluginAvatarPersona; let theme: String; let speech: PluginAvatarSpeech; let reducedMotion: Bool; let opaque: Bool
    var style: String = "elemental"
    func makeCoordinator() -> PluginAvatarScene { PluginAvatarScene(persona: persona, style: style) }
    func makeUIView(context: Context) -> SCNView { let view = SCNView(); view.scene = context.coordinator.scene; view.backgroundColor = .clear; view.isOpaque = false; view.isPlaying = false; return view }
    func updateUIView(_ view: SCNView, context: Context) { context.coordinator.update(theme: theme, speech: speech, reducedMotion: reducedMotion, opaque: opaque) }
    static func dismantleUIView(_ view: SCNView, coordinator: PluginAvatarScene) { view.scene = nil }
}
#endif
