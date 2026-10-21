import Foundation

/// Portable presentation only: no timers, capture, account or window authority.
public enum PluginSeasonalSpriteMotion:String,Codable,Sendable { case walk, fly, sway, flag, train }
public struct PluginSeasonalSpritePose:Equatable,Sendable {
    public var x=0.0; public var y=0.0; public var scaleX=1.0; public var rotation=0.0
}
public enum PluginSeasonalStoryMotion {
    public static func pose(_ motion:PluginSeasonalSpriteMotion?,elapsed:Double,seed:Int=0)->PluginSeasonalSpritePose {
        guard let motion,elapsed.isFinite,elapsed >= 0 else { return .init() }
        let t=elapsed,phase=Double(seed)*0.73
        switch motion {
        case .walk: return .init(x:sin(t*0.55+phase)*0.10,y:-abs(sin(t*5+phase))*0.004,scaleX:cos(t*0.55+phase)>=0 ? 1:-1,rotation:sin(t*5+phase)*0.018)
        case .fly: return .init(x:sin(t*0.8+phase)*0.035,y:sin(t*1.6+phase)*0.025,scaleX:0.45+abs(cos(t*7+phase))*0.55,rotation:sin(t+phase)*0.15)
        case .sway: return .init(y:sin(t+phase)*0.003,rotation:sin(t*0.7+phase)*0.02)
        case .flag: return .init(y:sin(t*1.3+phase)*0.002)
        case .train: return .init(x:0.22*(1-cos(t*0.65)),y:sin(t*0.65)*0.035,scaleX:sin(t*0.65)>=0 ? 1:-1)
        }
    }
}

extension PluginSeasonalArtPlan {
    static func story(scene:PluginSeasonalScene,layout:PluginSeasonalSurfaceLayout,catalog:PluginSeasonalArtCatalog)->Self? {
        var layers:[PluginSeasonalArtLayer]=[]
        func add(_ id:String,_ asset:String,_ day:Int,_ x:Double,_ y:Double,_ w:Double,_ h:Double,last:Int?=nil,back:Bool=false,motion:PluginSeasonalSpriteMotion?=nil) {
            guard scene.day >= day,scene.day <= (last ?? scene.totalDays),catalog.asset(asset) != nil else {return}
            let width=min(1,max(0.01,w)),height=min(1,max(0.01,h))
            layers.append(.init(id:id,asset:asset,frame:.init(x:min(1-width,max(0,x)),y:min(1-height,max(0,y)),width:width,height:height),firstDay:day,depth:back ? -0.9:-0.2,mirrored:false,lastDay:last,backdrop:back,motion:motion))
        }
        func background(_ asset:String,_ day:Int=1,last:Int?=nil) { add("background."+asset,asset,day,0,0,1,1,last:last,back:true) }
        func grass() { add("ground","grass-ground",1,0,0.56,1,0.18,back:true) }
        func flowers() { for n in 1...scene.day { add("flowers.\(n)","garden-flowers",n,0.035+Double(n-1)*0.19,0.43,0.14,0.23) } }
        var overlay:PluginSeasonalOverlay = .none
        var message:String?
        switch scene.holiday {
        case .presidents:
            background("rushmore")
            add("portrait.washington","washington",2,0.045,0.18,0.20,0.43)
            add("portrait.lincoln","lincoln",3,0.755,0.18,0.20,0.43)
            add("flag.left","american-flag",4,0.25,0.34,0.10,0.34)
            add("flag.right","american-flag",5,0.65,0.34,0.10,0.34)
        case .stPatricks:
            grass();add("clover.hero","clover",1,0.62,0.24,0.23,0.37)
            add("leprechaun.left","leprechaun",2,0.12,0.28,0.20,0.39,motion:.sway)
            add("clover.low","clover",3,0.04,0.61,0.14,0.19)
            add("leprechaun.right","leprechaun",4,0.77,0.40,0.16,0.33,motion:.sway)
            add("clover.crown","clover",5,0.40,0.02,0.20,0.15);overlay = .sparks
        case .easter:
            grass();add("eggs","spring-eggs",1,0.62,0.45,0.25,0.27)
            add("rabbit.left","rabbit",2,0.13,0.49,0.18,0.23,motion:.walk)
            add("butterfly.left","butterfly",3,0.22,0.17,0.075,0.10,motion:.fly)
            add("rabbit.right","rabbit",4,0.70,0.52,0.15,0.20,motion:.walk)
            add("flowers","garden-flowers",4,0.04,0.54,0.12,0.19)
            add("butterfly.right","butterfly",5,0.72,0.14,0.09,0.11,motion:.fly);overlay = .petals
        case .mothersDay:
            grass();add("floral.heart","flower-heart",1,0.24,0.015,0.52,0.51);flowers()
            if scene.isHoliday { message="Thank you." };overlay = .petals
        case .memorial:
            background("arlington");add("flag.left","american-flag",2,0.08,0.30,0.12,0.39)
            add("standards","service-standards",3,0.62,0.38,0.33,0.30)
            add("candle","memorial-candle",4,0.23,0.47,0.08,0.19)
            if scene.isHoliday { message="Thank you for your service." }
        case .fathersDay:
            grass();add("family.bears","bears",1,0.64,0.23,0.31,0.45)
            add("picnic","picnic",2,0.08,0.52,0.28,0.20)
            add("flowers","garden-flowers",3,0.03,0.54,0.12,0.19)
            add("gift","gift",4,0.76,0.63,0.14,0.13)
            if scene.isHoliday { message="Thanks, Dad." }
        case .independence:
            background("revolution");grass()
            for n in 1...scene.day { for side in 0...1 { add("flag.\(side).\(n)","american-flag",n,side == 0 ? 0.01+Double(n-1)*0.048 : 0.91-Double(n-1)*0.048,0.41+Double(n%2)*0.06,0.075,0.30,motion:.flag) } }
            if scene.isHoliday { overlay = .fireworks }
        case .labor:
            grass();add("workbench","workbench",1,0.05,0.37,0.27,0.32)
            add("workers","workers",2,0.65,0.23,0.31,0.45)
            add("picnic","picnic",3,0.10,0.57,0.25,0.18)
            add("flowers","garden-flowers",4,0.01,0.50,0.12,0.21)
            if scene.isHoliday { message="Made possible by people." }
        case .remembrance911:
            background("remembrance-city")
            // Beams are a native/vector layer; city artwork contains no baked beams.
            add("remembrance.candle","memorial-candle",2,0.86,0.61,0.045,0.12)
            if scene.isHoliday { message="We will never forget." }
        case .columbus:
            background(scene.isHoliday ? "columbus-shore":"ocean",last:scene.isHoliday ? nil:4)
            let progress=Double(scene.day-1)/Double(scene.totalDays-1),width=0.06+progress*0.27
            add("fleet.single","fleet",1,0.20-width/2,0.40-progress*0.16,width,0.05+progress*0.28,motion:.sway)
        case .halloween:
            grass();add("hand.emerging","zombie-hand",2,0.12,0.54,0.13,0.19)
            add("graves","grave-cluster",3,0.64,0.39,0.29,0.30)
            if scene.day >= 4 { overlay = .bats }
            add("pumpkin","pumpkin",5,0.03,0.56,0.15,0.17)
            add("monsters","monsters",6,0.015,0.08,0.97,0.53,motion:.sway)
            add("pumpkin.final","pumpkin",7,0.80,0.58,0.16,0.17)
        case .veterans:
            if scene.isHoliday {
                add("flag.full","wide-flag",scene.totalDays,0,0,1,1,back:true,motion:.flag)
                message="For the sleepless nights, the missed moments, and the willingness to serve and protect. Thank you to our veterans and the families who support them.\nRemember and honor."
            } else {
                background("veterans-salute",last:scene.totalDays-1)
                add("standards","service-standards",2,0.04,0.45,0.30,0.28,last:scene.totalDays-1)
                add("laurel","laurel",3,0.035,0.20,0.09,0.18,last:scene.totalDays-1)
                add("candle","memorial-candle",4,0.20,0.50,0.07,0.17,last:scene.totalDays-1)
            }
        case .thanksgiving:
            grass();add("harvest","autumn-harvest",1,0.02,0.50,0.25,0.25)
            add("turkey.left","live-turkey",2,0.16,0.45,0.18,0.26,last:6,motion:.walk)
            add("leaves","autumn-harvest",3,0.73,0.25,0.26,0.35)
            add("turkey.right","live-turkey",4,0.68,0.47,0.17,0.25,last:6,motion:.walk)
            add("pumpkin","pumpkin",5,0.04,0.58,0.12,0.16)
            add("lantern","lantern",6,0.88,0.46,0.07,0.20)
            add("feast","feast",7,0.15,0.45,0.70,0.34);overlay = .leaves
        default: return nil
        }
        let plan=Self(scene:scene,layout:layout,layers:layers,overlay:overlay,message:message,beams:scene.holiday == .remembrance911 ? max(0,min(2,scene.day-2)):nil,quietWelcome:scene.holiday == .thanksgiving && scene.isHoliday)
        return (try? plan.validate(catalog:catalog)) != nil ? plan:nil
    }
}
