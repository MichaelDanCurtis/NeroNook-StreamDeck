import Foundation

/// Deterministic, bounded overlay samples. Adapters draw local primitives only;
/// no repeating task or authority to open windows is carried in this data.
public struct PluginSeasonalParticle: Equatable, Sendable {
    public enum Kind: String, Sendable { case snow, star, petal, leaf, bat, heart, confetti }
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var size: Double
    public var rotation: Double
    public var phase: Double
    public var opacity: Double
}
public enum PluginSeasonalMotion {
    public static func sample(scene: PluginSeasonalScene, overlay: PluginSeasonalOverlay, elapsed: Double) -> [PluginSeasonalParticle] {
        let duration = scene.intensity == .low ? 12.0 : 24.0
        guard (try? scene.validate()) != nil, elapsed.isFinite, elapsed >= 0,
              elapsed < duration, scene.intensity != .off, !scene.holiday.isReflective, overlay != .none else { return [] }
        if overlay == .fireworks {
            guard scene.holiday == .independence,scene.isHoliday else{return []}
            let count=scene.intensity == .low ? 72:192
            return (0..<count).map { i in
                let burst=i/24,ray=i%24,age=(elapsed+Double(burst)*0.37).truncatingRemainder(dividingBy:3.2),radius=0.015+age*0.035
                let angle=Double(ray)*Double.pi/12,centerX=0.13+Double((burst*31)%74)/100,centerY=0.10+Double(burst%3)*0.11
                return .init(kind:.star,x:centerX+cos(angle)*radius,y:centerY+sin(angle)*radius+age*age*0.006,size:1.5,rotation:angle,phase:Double(burst),opacity:min(1,elapsed/0.6)*max(0,1-age/3.2)*0.85)
            }
        }
        return (0..<scene.particleCap).map { i in
            let kind: PluginSeasonalParticle.Kind
            switch overlay {
            case .snow: kind = .snow
            case .sparks: kind = .star
            case .petals: kind = .petal
            case .leaves: kind = .leaf
            case .bats: kind = i % 3 == 0 ? .bat : .leaf
            case .hearts: kind = .heart
            case .confetti: kind = .confetti
            case .none,.fireworks: kind = .star
            }
            let phase=elapsed * (kind == .bat ? 5.5 : 1.6) + Double(i)*1.9
            let drift=sin(elapsed*0.7+Double(i))*0.025
            let seedX=Double((i*43+13)%97)/100,seedY=Double((i*31+7)%101)/100
            let rising=kind == .heart || kind == .star
            let speed=kind == .bat ? 0.07 : kind == .snow ? 0.035 : 0.022
            let travel=(seedY+elapsed*speed).truncatingRemainder(dividingBy:1)
            let x=min(0.985,max(0.015,seedX+drift))
            let y=kind == .bat ? min(0.30,max(0.06,seedY*0.25+sin(elapsed+Double(i))*0.025)) : rising ? 1-travel : travel
            let size:Double=kind == .bat ? 10 : kind == .snow ? 1.4 : kind == .heart ? 5 : kind == .leaf ? 4.2 : 3
            let edgeFade=min(1,elapsed/0.6)*min(1,(duration-elapsed)/0.8)
            return .init(kind:kind,x:x,y:y,size:size,rotation:kind == .bat ? sin(elapsed+Double(i))*0.12 : phase*0.4,phase:phase,opacity:edgeFade*(kind == .bat ? 0.55 : 0.40))
        }
    }
}
