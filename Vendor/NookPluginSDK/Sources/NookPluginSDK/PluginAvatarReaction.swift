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
public enum PluginAvatarReaction:String,Sendable { case giggle,zoom }
/// The same bounded curves are used by the native and web character surfaces.
public struct PluginAvatarReactionPose:Equatable,Sendable {
    public var x:Double=0,y:Double=0,roll:Double=0
    public var mouth:Double=0,smile:Double=0,laugh:Double=0,surprise:Double=0,blink:Double=0
    public init() {}
    public static func sample(_ kind:PluginAvatarReaction,elapsed:Double,duration:Double)->Self {
        guard elapsed.isFinite,duration.isFinite,duration>0,elapsed>=0,elapsed<duration else { return .init() }
        let t=elapsed/duration,fade=min(1,t*12)*min(1,(1-t)*10)
        var p=Self()
        if kind == .giggle {
            let beat=max(0,sin(t * .pi * 6));p.y=beat*0.065*fade;p.roll=sin(t * .pi * 6)*0.055*fade
            p.smile=0.75*fade;p.laugh=beat*0.70*fade;p.mouth=beat*0.25*fade;p.blink=0.65*fade
        } else {
            p.x=sin(t * .pi * 6)*0.12*fade;p.y=abs(sin(t * .pi * 6))*0.035*fade;p.roll = -sin(t * .pi * 6)*0.14*fade
            p.surprise=0.7*fade;p.mouth=max(0,sin(t * .pi * 6))*0.45*fade
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
/// Two pre-rendered local UI sounds, not a speech provider or a microphone.
/// A single owner at a time prevents duplicate avatar sounds within a process.
@MainActor final class PluginAvatarReactionAudio {
    static let shared=PluginAvatarReactionAudio()
    private var player:AVAudioPlayer?
    private var owner:UUID?
    private var lastPlay=Date.distantPast
    func play(_ kind:PluginAvatarReaction,owner:UUID,enabled:Bool)->Double {
        guard enabled,Date().timeIntervalSince(lastPlay)>=1 else { return PluginAvatarReactionCatalog.clips[kind.rawValue]?.duration ?? 1.3 }
        stop();self.owner=owner;lastPlay=Date()
        guard let url=Bundle.module.url(forResource:"avatar-"+kind.rawValue,withExtension:"wav"),let p=try? AVAudioPlayer(contentsOf:url) else { return 1.3 }
        player=p;p.volume=0.55;p.prepareToPlay();p.play();return min(3,max(0.3,p.duration))
    }
    func stop(owner:UUID?=nil) { guard owner==nil || owner==self.owner else{return};player?.stop();player=nil;self.owner=nil }
}
#endif
