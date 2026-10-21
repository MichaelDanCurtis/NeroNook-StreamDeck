import Foundation

/// Ephemeral, local pointer gesture classification. No event tap or input log.
public struct PluginAvatarGesture: Sendable {
    private var previous:CGPoint?
    private var previousTime:Double=0
    private var velocity:CGPoint?
    private var turns=0
    private var firstTurn:Double=0
    private var cooldown:Double = -.infinity
    public init() {}
    public mutating func reset() { previous=nil;velocity=nil;turns=0 }
    public mutating func move(point:CGPoint,time:Double,near:Bool,enabled:Bool) -> Bool {
        guard time.isFinite,point.x.isFinite,point.y.isFinite,near,enabled else { reset();return false }
        defer { previous=point;previousTime=time }
        guard let p=previous else { return false }
        let dt=time-previousTime
        guard dt>=0.012,dt<=0.25 else { velocity=nil;turns=0;return false }
        let dx=(point.x-p.x)/dt,dy=(point.y-p.y)/dt,speed=hypot(dx,dy)
        guard speed>=900,time-cooldown>=6 else { velocity=nil;turns=0;return false }
        let v=CGPoint(x:dx/speed,y:dy/speed)
        if let old=velocity,old.x*v.x+old.y*v.y<0.4 {
            if turns==0 || time-firstTurn>0.8 {firstTurn=time;turns=0}
            turns+=1
        }
        velocity=v
        if turns>=2 {cooldown=time;turns=0;velocity=nil;return true}
        return false
    }
}
public enum PluginAvatarReaction:String,Codable,Sendable,CaseIterable {
    case giggle,zoom,wave,twirl
    public var spokenText:String {self == .giggle ? "He he, that tickles! Hehehe!" : "Zoom, zoom, zoom! Ha ha ha!"}
    public var hasAudio:Bool {self == .giggle || self == .zoom}
    public var duration:Double {PluginAvatarReactionCatalog.clips[rawValue]?.duration ?? (self == .wave ? 1.6:self == .twirl ? 1.8:3)}
    public var caption:String {switch self {case .giggle:"He he, that tickles!";case .zoom:"Zoom, zoom, zoom!";case .wave:"Hi there!";case .twirl:"Ta-da!"}}
    public var title:String {switch self {case .giggle:"Tickle";case .zoom:"Playful Zoom";case .wave:"Wave hello";case .twirl:"Happy twirl"}}
}
/// Same finite curves in native and web. Words use measured PCM; gestures never
/// fabricate speech. Wave and twirl are intentionally silent.
public struct PluginAvatarReactionPose:Equatable,Sendable {
    public var x:Double=0,y:Double=0,roll:Double=0,turn:Double=0,wave:Double=0
    public var mouth:Double=0,smile:Double=0,laugh:Double=0,surprise:Double=0,blink:Double=0
    public init() {}
    public static func sample(_ kind:PluginAvatarReaction,elapsed:Double,duration:Double)->Self {
        guard elapsed.isFinite,duration.isFinite,duration>0,elapsed>=0,elapsed<duration else {return .init()}
        let t=elapsed/duration,fade=min(1,t*12)*min(1,(1-t)*10),wave=sin(t * .pi * 6),beat=max(0,wave)
        var p=Self()
        switch kind {
        case .giggle:
            p.y=beat*0.045*fade;p.roll=wave*0.055*fade;p.smile=0.85*fade;p.laugh=beat*0.35*fade;p.blink=0.45*fade
        case .zoom:
            p.x=wave*0.14*fade;p.y=abs(wave)*0.06*fade;p.roll = -wave*0.16*fade
            p.smile=0.9*fade;p.laugh=beat*0.42*fade;p.blink=0.3*fade
        case .wave:
            p.wave=fade*(0.7+wave*0.3);p.roll=wave*0.065*fade;p.y=beat*0.025*fade;p.smile=0.7*fade;p.blink=max(0,sin(t * .pi * 2))*0.3*fade
        case .twirl:
            p.turn=2 * .pi * t*t*(3-2*t);p.y=sin(t * .pi)*0.10;p.roll=sin(t * .pi * 2)*0.08*fade;p.wave=0.5*fade;p.smile=0.85*fade
        }
        return p
    }
}

public enum PluginAvatarReactionCatalog {
    public struct Clip:Decodable,Sendable {public let duration:Double;public let step:Double;public let levels:[Double]}
    public static let clips:[String:Clip] = {
        guard let url=Bundle.module.url(forResource:"avatar-reactions-v1",withExtension:"json"),let data=try? Data(contentsOf:url),data.count<=8192,
              let values=try? JSONDecoder().decode([String:Clip].self,from:data),Set(values.keys)==Set(["giggle","zoom"]),values.values.allSatisfy({$0.duration>0 && $0.duration<=3 && $0.step==0.02 && $0.levels.count<=150 && $0.levels.allSatisfy{ $0.isFinite && (0...1).contains($0) }}) else{return [:]}
        return values
    }()
    public static func level(_ kind:PluginAvatarReaction,elapsed:Double)->Double {
        guard elapsed.isFinite,elapsed>=0,let clip=clips[kind.rawValue],elapsed<clip.duration else{return 0}
        let i=Int(elapsed/clip.step);return clip.levels.indices.contains(i) ? clip.levels[i]:0
    }
}

#if canImport(AVFoundation)
import AVFoundation
/// Native previews remain silent unless the embedding product connects its own
/// selected-voice service. Never substitute a bundled stranger's voice.
@MainActor final class PluginAvatarReactionAudio {
    static let shared=PluginAvatarReactionAudio()
    func play(_ kind:PluginAvatarReaction,owner:UUID,enabled:Bool)->Double {kind.duration}
    var isPlaying:Bool {false}
    func stop(owner:UUID?=nil) {}
}
#endif
