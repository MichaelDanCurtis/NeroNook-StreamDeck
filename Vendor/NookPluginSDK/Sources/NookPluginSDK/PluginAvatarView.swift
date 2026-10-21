import SwiftUI
@preconcurrency import SceneKit
import simd
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
private typealias AvatarColor=NSColor
private typealias AvatarScalar=CGFloat
#else
import UIKit
private typealias AvatarColor=UIColor
private typealias AvatarScalar=Float
#endif

/// Shared full-volume rig. Eye joints, face morphs and body pose are composed
/// directly; no animation clip can overwrite the other channels.
@MainActor final class PluginAvatarScene {
    let scene=SCNScene()
    private let model=SCNNode(),posture=SCNNode()
    private let persona:PluginAvatarPersona,style:String
    private var morphs:[SCNMorpher]=[]
    private var eyes:[(node:SCNNode,forward:SIMD3<Float>,scale:SIMD3<Float>)]=[]
    private var joints:[(SCNNode,simd_quatf)]=[]
    private var currentTheme="",speech=PluginAvatarSpeech(),expression=PluginExpressionPose(),gaze=PluginAvatarGaze()
    private var reduced=false,opaque=false,reactions=true,sounds=true
    private var reaction:PluginAvatarReactionPose = .init()
    private var reactionKind:PluginAvatarReaction?
    private var reactionStart:TimeInterval=0,reactionDuration:TimeInterval=0
    private let audioOwner=UUID()
    nonisolated(unsafe) private var reactionTimer:Timer?
    private var gesture=PluginAvatarGesture()
    private weak var nativeView:SCNView?
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private let pointer=PluginAvatarPointerSource()
    #endif
    init(persona:PluginAvatarPersona,style:String="elemental") {
        self.persona=persona;self.style=PluginAvatarStyles.model(style:style,persona:persona)==nil ? "elemental":style
        model.name="NookAvatarGaze";posture.name="NookAvatarExpression"
        if let url=PluginAvatarStyles.model(style:style,persona:persona) ?? PluginAvatarCatalog.model(persona:persona),let source=try? SCNScene(url:url) {
            for node in source.rootNode.childNodes {node.removeFromParentNode();model.addChildNode(node)}
            model.enumerateChildNodes { node,_ in
                node.removeAllAnimations()
                if let morph=node.morpher { for i in morph.targets.indices {morph.setWeight(0,forTargetAt:i)};self.morphs.append(morph) }
                if node.name?.hasPrefix("PupilGimbal_")==true,let iris=node.childNodes.first(where:{$0.name?.hasPrefix("Iris_")==true}) {
                    self.eyes.append((node,simd_normalize(iris.simdPosition),node.simdScale))
                }
                if node.name?.hasPrefix("Articulation_")==true {self.joints.append((node,node.simdOrientation))}
                for material in node.geometry?.materials ?? [] {
                    material.lightingModel = .physicallyBased
                    if persona == .nero && self.style == "elemental",material.name?.hasPrefix("AvatarBody")==true {material.transparent.contents=AvatarColor.white;material.transparency=0.92;material.roughness.contents=0.18;material.metalness.contents=0.25;material.transparencyMode = .singleLayer}
                }
            }
            posture.addChildNode(model);scene.rootNode.addChildNode(posture)
        }
        if let studio=Bundle.module.url(forResource:"avatar-studio",withExtension:"png") {scene.lightingEnvironment.contents=studio;scene.lightingEnvironment.intensity=0.75}
        let (lo,hi)=model.boundingBox
        let center=SCNVector3((lo.x+hi.x)/2,(lo.y+hi.y)/2,(lo.z+hi.z)/2)
        let span=max(hi.x-lo.x,hi.y-lo.y)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.usesOrthographicProjection=true
        camera.camera?.wantsHDR=true;camera.camera?.wantsExposureAdaptation=false;camera.camera?.exposureOffset = -1.0
        camera.camera?.orthographicScale=Double(max(1.2,span*0.62));camera.position=SCNVector3(center.x,center.y,center.z+8);camera.look(at:center)
        scene.rootNode.addChildNode(camera)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=100;scene.rootNode.addChildNode(ambient)
        for (position,intensity) in [(SCNVector3(-3,5,5),600.0),(SCNVector3(4,2,3),240.0),(SCNVector3(0,4,-4),450.0)] {
            let light=SCNNode();light.light=SCNLight();light.light?.type = .omni;light.light?.intensity=intensity;light.position=position;scene.rootNode.addChildNode(light)
        }
    }
    func attach(_ view:SCNView){nativeView=view}
    func update(theme:String,speech:PluginAvatarSpeech,expression:PluginExpressionPose = .init(),reducedMotion:Bool,opaque:Bool,reactions:Bool=true,sounds:Bool=true) {
        let requestedExpression=(try? expression.validate()) != nil ? expression:PluginExpressionPose()
        guard theme != currentTheme || speech != self.speech || requestedExpression != self.expression || reducedMotion != reduced || opaque != self.opaque || reactions != self.reactions || sounds != self.sounds else { return }
        self.speech=speech;self.expression=(try? expression.validate()) != nil ? expression:.init();reduced=reducedMotion;self.opaque=opaque;self.reactions=reactions;self.sounds=sounds
        if speech.speaking || !reactions || reducedMotion {stopReaction()}
        if !sounds {PluginAvatarReactionAudio.shared.stop(owner:audioOwner)}
        if style=="elemental",currentTheme != theme {
            currentTheme=theme;let colors=PluginAvatarCatalog.palette(theme:theme)?.avatars[persona.rawValue] ?? [:]
            model.enumerateChildNodes {node,_ in
                for material in node.geometry?.materials ?? [] {
                    let name=material.name ?? "";guard name.hasPrefix("Avatar") else {continue}
                    let key=name.contains("Inner") ? "core":name.contains("Trim") ? "tip":name.contains("Accent") ? "base":"body"
                    if let hex=colors[key] {
                        let tint=Self.color(hex)
                        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
                        material.diffuse.contents = persona == .nero && name == "AvatarBody" ? tint.blended(withFraction:0.48,of:Self.color("#488CAA")) ?? tint:tint
                        #else
                        material.diffuse.contents=tint
                        #endif
                    }
                }
            }
        }
        currentTheme=theme;applyPose(animated:false)
    }
    func look(_ value:PluginAvatarGaze,animated:Bool=true){guard value != gaze else{return};gaze=value;applyPose(animated:animated)}
    private func applyPose(animated:Bool) {
        SCNTransaction.begin();SCNTransaction.animationDuration=animated ? 0.08:0
        let r=reduced ? PluginAvatarReactionPose():reaction
        let p=reduced ? PluginExpressionPose():expression
        model.eulerAngles=SCNVector3(AvatarScalar((reduced ? 0:gaze.pitchDegrees * .pi/180)),AvatarScalar((reduced ? 0:gaze.yawDegrees * .pi/180)+r.turn),AvatarScalar((reduced ? 0:gaze.rollDegrees * .pi/180)+r.roll))
        model.position=SCNVector3(AvatarScalar((reduced ? 0:gaze.offsetX)+r.x),AvatarScalar((reduced ? 0:gaze.offsetY)+r.y),0)
        posture.eulerAngles=SCNVector3(AvatarScalar(p.pitch * .pi/180),0,AvatarScalar(p.roll * .pi/180));posture.position=SCNVector3(0,AvatarScalar(p.lift),0)
        let blink=r.blink
        for eye in eyes {
            if let parent=eye.node.parent {
                let desired=simd_normalize(parent.simdConvertVector(SIMD3<Float>(Float(gaze.x*0.65),Float(gaze.y*0.45),1),from:model))
                eye.node.simdOrientation=simd_quatf(from:eye.forward,to:desired)
                let up=simd_normalize(eye.node.simdConvertVector(SIMD3<Float>(0,1,0),from:model))
                var scale=eye.scale;let axis=abs(up.x)>abs(up.y) && abs(up.x)>abs(up.z) ? 0:abs(up.y)>abs(up.z) ? 1:2
                scale[axis] *= Float(1-blink*0.91);eye.node.simdScale=scale
            }
        }
        let mouth=PluginAvatarSpeech.mouthWeight(speech.level,speaking:speech.speaking,reducedMotion:reduced)
        let weights=["Speak":max(mouth,r.mouth),"Blink":blink,"Smile":r.smile,"Laugh":r.laugh,"Surprise":r.surprise]
        for morph in morphs {for (i,target) in morph.targets.enumerated(){morph.setWeight(weights[target.name ?? ""] ?? 0,forTargetAt:i)}}
        for (joint,base) in joints {
            let sign:Double=joint.name?.contains("_L_")==true ? -1:1
            let angle=sign*(r.y*0.8+gaze.x*0.05+r.wave*(joint.name?.contains("_Foot")==true ? 0.15:0.8))
            let axis=simd_normalize(joint.parent?.simdConvertVector(SIMD3<Float>(0,0,1),from:model) ?? SIMD3<Float>(0,0,1))
            joint.simdOrientation=simd_quatf(angle:Float(angle),axis:axis)*base
        }
        if opaque {model.enumerateChildNodes {node,_ in node.geometry?.materials.forEach{$0.transparency=1}}}
        SCNTransaction.commit()
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        nativeView?.needsDisplay=true
        #else
        nativeView?.setNeedsDisplay()
        #endif
    }
    var interactionAllowed:Bool {
        guard reactions,!reduced,!speech.speaking,let view=nativeView,view.bounds.width>=80,view.window != nil,!view.isHidden else{return false}
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible==true && view.window?.occlusionState.contains(.visible)==true
        #else
        return true
        #endif
    }
    func react(_ kind:PluginAvatarReaction) {
        guard interactionAllowed else{return}
        stopReaction();reactionKind=kind;reactionStart=ProcessInfo.processInfo.systemUptime
        reactionDuration=PluginAvatarReactionAudio.shared.play(kind,owner:audioOwner,enabled:sounds)
        let timer=Timer(timeInterval:1/24,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.reactionTick()} }
        timer.tolerance = 0.008;reactionTimer=timer;RunLoop.main.add(timer,forMode:.common);reactionTick()
    }
    private func reactionTick(){
        guard let kind=reactionKind else{return}
        let elapsed=ProcessInfo.processInfo.systemUptime-reactionStart
        guard elapsed<reactionDuration,let view=nativeView,view.window != nil,!view.isHidden else {stopReaction();return}
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard !view.isHiddenOrHasHiddenAncestor,view.window?.isVisible==true,view.window?.occlusionState.contains(.visible)==true else {stopReaction();return}
        #endif
        reaction = .sample(kind,elapsed:elapsed,duration:reactionDuration)
        // Settings/native previews have no speech-provider connection. Remain
        // silent instead of animating a mouth against an unrelated recording.
        if kind.hasAudio {reaction.mouth=0;reaction.laugh=0;reaction.surprise=0}
        applyPose(animated:false)
    }
    func stopReaction(){reactionTimer?.invalidate();reactionTimer=nil;reactionKind=nil;reaction = .init();PluginAvatarReactionAudio.shared.stop(owner:audioOwner);applyPose(animated:false)}
    deinit{reactionTimer?.invalidate()}
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    func followPointer(in view:NSView,reducedMotion:Bool){
        guard !reducedMotion else {pointer.stop();look(.init(),animated:false);return}
        pointer.start(view:view){ [weak self,weak view] sample in
            guard let self,let view else{return}
            guard let s=sample else {self.gesture.reset();self.look(.init(),animated:false);return}
            let center=CGPoint(x:view.bounds.width/2,y:view.bounds.height/2)
            self.look(.towards(pointer:.init(x:s.x,y:s.y),center:center,range:.init(width:max(100,view.bounds.width*1.5),height:max(90,view.bounds.height*1.5))))
            let near=hypot(s.x-center.x,s.y-center.y)<max(100,view.bounds.width*1.2)
            if self.gesture.move(point:.init(x:s.x,y:s.y),time:ProcessInfo.processInfo.systemUptime,near:near,enabled:self.reactions && !self.speech.speaking && view.bounds.width>=80){self.react(.zoom)}
        }
    }
    func stopPointer(){pointer.stop();stopReaction();look(.init(),animated:false)}
    #endif
    private static func color(_ hex:String)->AvatarColor {
        let x=UInt32(hex.dropFirst(),radix:16) ?? 0
        return AvatarColor(red:CGFloat((x>>16)&255)/255,green:CGFloat((x>>8)&255)/255,blue:CGFloat(x&255)/255,alpha:1)
    }
}
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private final class CharacterSCNView:SCNView {
    var play:((PluginAvatarReaction?)->Void)?
    var canPlay:(()->Bool)?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    override func mouseDown(with event:NSEvent){let p=convert(event.locationInWindow,from:nil);if bounds.width>=80,!hitTest(p,options:nil).isEmpty {play?(.giggle)}else{super.mouseDown(with:event)}}
    override func accessibilityPerformPress()->Bool{guard canPlay?()==true else{return false};play?(.giggle);return true}
    override func menu(for event:NSEvent)->NSMenu? {
        guard bounds.width>=80 else{return nil}
        let menu=NSMenu(title:"Play with avatar");menu.autoenablesItems=false
        for (index,kind) in PluginAvatarReaction.allCases.enumerated(){let item=NSMenuItem(title:kind.title,action:#selector(choose(_:)),keyEquivalent:"");item.target=self;item.tag=index;item.isEnabled=canPlay?()==true;menu.addItem(item)}
        menu.addItem(.separator());let stop=NSMenuItem(title:"Stop",action:#selector(choose(_:)),keyEquivalent:"");stop.target=self;stop.tag=99;menu.addItem(stop);return menu
    }
    @objc private func choose(_ item:NSMenuItem){play?(PluginAvatarReaction.allCases.indices.contains(item.tag) ? PluginAvatarReaction.allCases[item.tag]:nil)}
}

struct PluginAvatarSurface:NSViewRepresentable {
    let persona:PluginAvatarPersona;let theme:String;let speech:PluginAvatarSpeech;var expression:PluginExpressionPose = .init();let reducedMotion:Bool;let opaque:Bool
    var style:String="elemental";var reactions:Bool=true;var sounds:Bool=true
    func makeCoordinator()->PluginAvatarScene{PluginAvatarScene(persona:persona,style:style)}
    func makeNSView(context:Context)->SCNView {
        let view=CharacterSCNView();view.scene=context.coordinator.scene;view.backgroundColor = .clear;view.antialiasingMode = .multisampling4X;view.preferredFramesPerSecond=24;view.isPlaying=false;view.rendersContinuously=false
        view.play={ [weak scene=context.coordinator] kind in if let kind {scene?.react(kind)}else{scene?.stopReaction()} };view.canPlay={ [weak scene=context.coordinator] in scene?.interactionAllowed == true };view.setAccessibilityRole(.button);view.setAccessibilityLabel("Play with "+persona.rawValue.capitalized);context.coordinator.attach(view);return view
    }
    func updateNSView(_ view:SCNView,context:Context){context.coordinator.update(theme:theme,speech:speech,expression:expression,reducedMotion:reducedMotion,opaque:opaque,reactions:reactions,sounds:sounds);context.coordinator.followPointer(in:view,reducedMotion:reducedMotion)}
    static func dismantleNSView(_ view:SCNView,coordinator:PluginAvatarScene){coordinator.stopPointer();view.isPlaying=false;view.scene=nil}
}
#else
struct PluginAvatarSurface:UIViewRepresentable {
    let persona:PluginAvatarPersona;let theme:String;let speech:PluginAvatarSpeech;var expression:PluginExpressionPose = .init();let reducedMotion:Bool;let opaque:Bool
    var style:String="elemental";var reactions:Bool=true;var sounds:Bool=true
    func makeCoordinator()->PluginAvatarScene{PluginAvatarScene(persona:persona,style:style)}
    func makeUIView(context:Context)->SCNView{let view=SCNView();view.scene=context.coordinator.scene;view.backgroundColor = .clear;view.isOpaque=false;view.isPlaying=false;context.coordinator.attach(view);return view}
    func updateUIView(_ view:SCNView,context:Context){context.coordinator.update(theme:theme,speech:speech,expression:expression,reducedMotion:reducedMotion,opaque:opaque,reactions:reactions,sounds:sounds)}
    static func dismantleUIView(_ view:SCNView,coordinator:PluginAvatarScene){coordinator.stopReaction();view.scene=nil}
}
#endif
