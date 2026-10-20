import Foundation

/// Bundled raster layers are pre-rendered original 3D art, never downloaded
/// scenes or screenshots of UI. Catalog basenames cannot address arbitrary files.
public struct PluginSeasonalArtAsset: Codable, Equatable, Sendable {
    public struct Files: Codable, Equatable, Sendable { public var light:String; public var dark:String }
    public struct Anchor: Codable, Equatable, Sendable {
        public var x:Double; public var y:Double; public var radius:Double
        public var kind:String; public var color:String
    }
    public var id:String
    public var files:Files
    public var width:Int
    public var height:Int
    public var aspectRatio:Double
    public var contentRect:PluginSeasonalRectangle
    public var baselineY:Double
    public var centerX:Double
    public var fit:String
    public var overlayAnchors:[Anchor]
    public func validate() throws {
        guard id.range(of:"^[a-z][a-z0-9-]{0,63}$",options:.regularExpression) != nil,
              files.light == "seasonal-\(id)-light.png", files.dark == "seasonal-\(id)-dark.png",
              (16...2048).contains(width), (16...2048).contains(height), aspectRatio.isFinite,
              abs(aspectRatio-Double(width)/Double(height)) < 0.001,
              baselineY.isFinite,(0...1).contains(baselineY),centerX.isFinite,(0...1).contains(centerX),
              fit == "contain",overlayAnchors.count <= 64,
              overlayAnchors.allSatisfy({ a in [a.x,a.y,a.radius].allSatisfy(\.isFinite) && (0...1).contains(a.x) && (0...1).contains(a.y) && (0.0001...0.1).contains(a.radius) && ["light","window","candle"].contains(a.kind) && a.color.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil })
        else { throw ModuleProblem("Invalid bundled seasonal artwork.") }
        try contentRect.validate()
    }
    public func fitted(in frame:PluginSeasonalRectangle, viewportAspect:Double) -> PluginSeasonalRectangle {
        guard viewportAspect.isFinite,viewportAspect > 0 else { return frame }
        let frameAspect=frame.width*viewportAspect/frame.height
        if frameAspect > aspectRatio {
            let width=frame.height*aspectRatio/viewportAspect
            return .init(x:frame.x+(frame.width-width)/2,y:frame.y,width:width,height:frame.height)
        }
        let height=frame.width*viewportAspect/aspectRatio
        return .init(x:frame.x,y:frame.y+frame.height-height,width:frame.width,height:height)
    }
}
public struct PluginSeasonalArtCatalog: Codable, Equatable, Sendable {
    public var version:Int
    public var assets:[PluginSeasonalArtAsset]
    public func validate() throws {
        guard version == 1,assets.count <= 64,Set(assets.map(\.id)).count == assets.count else { throw ModuleProblem("Unsupported seasonal artwork catalog.") }
        try assets.forEach { try $0.validate() }
    }
    public static let bundled:Self? = {
        guard let url=Bundle.module.url(forResource:"seasonal-art-catalog-v1",withExtension:"json"),
              let data=try? Data(contentsOf:url),data.count <= 256*1024,
              let catalog=try? JSONDecoder().decode(Self.self,from:data),
              (try? catalog.validate()) != nil else { return nil }
        return catalog
    }()
    public func asset(_ id:String) -> PluginSeasonalArtAsset? { assets.first { $0.id == id } }
    public static func url(path:String) -> URL? {
        guard path.hasPrefix("/__nook_sdk__/"),let catalog=bundled,
              let entry=catalog.assets.first(where:{ path == "/__nook_sdk__/"+$0.files.light || path == "/__nook_sdk__/"+$0.files.dark }) else { return nil }
        let name=path.hasSuffix(entry.files.dark) ? entry.files.dark : entry.files.light
        return Bundle.module.url(forResource:String(name.dropLast(4)),withExtension:"png")
    }
}

public struct PluginSeasonalArtLayer: Codable, Equatable, Sendable, Identifiable {
    public var id:String
    public var asset:String
    public var frame:PluginSeasonalRectangle
    public var firstDay:Int
    public var depth:Double
    public var mirrored:Bool
}
public enum PluginSeasonalOverlay: String, Codable, Sendable { case snow, sparks, petals, leaves, none }
public struct PluginSeasonalArtPlan: Codable, Equatable, Sendable {
    public var version=1
    public var scene:PluginSeasonalScene
    public var layout:PluginSeasonalSurfaceLayout
    public var layers:[PluginSeasonalArtLayer]
    public var overlay:PluginSeasonalOverlay
    public var animationSeconds:Double { scene.intensity == .off || scene.holiday.isReflective ? 0 : scene.intensity == .low ? 12 : 24 }
    public func validate(catalog:PluginSeasonalArtCatalog) throws {
        try scene.validate();try layout.validate();try catalog.validate()
        guard version == 1,layers.count <= 48,Set(layers.map(\.id)).count == layers.count,
              !scene.holiday.isReflective || overlay == .none else { throw ModuleProblem("Unsupported seasonal layer plan.") }
        for layer in layers {
            guard layer.id.range(of:"^[a-z][a-z0-9.-]{0,95}$",options:.regularExpression) != nil,
                  catalog.asset(layer.asset) != nil,(1...scene.totalDays).contains(layer.firstDay),
                  layer.firstDay <= scene.day,layer.depth.isFinite,(-1...1).contains(layer.depth),
                  layer.depth < 0 || !layer.frame.intersects(layout.avatar) else { throw ModuleProblem("Invalid seasonal layer instance.") }
            try layer.frame.validate()
        }
    }
    /// Positions refer to the actual live avatar, not a screenshot. Important
    /// text/control masks belong to each plugin's local layout adapter.
    public static func make(scene:PluginSeasonalScene?,layout:PluginSeasonalSurfaceLayout = .voice,catalog:PluginSeasonalArtCatalog? = .bundled) -> Self? {
        guard let scene,let catalog,(try? scene.validate()) != nil,(try? layout.validate()) != nil else { return nil }
        var layers:[PluginSeasonalArtLayer]=[]
        let floor=min(0.68,max(0.24,layout.avatar.y+layout.avatar.height)),cx=layout.avatar.x+layout.avatar.width/2
        func add(_ id:String,_ asset:String,_ day:Int,_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ depth:Double = -0.2,_ mirror:Bool = false) {
            guard scene.day >= day,catalog.asset(asset) != nil else { return }
            let width=min(1,max(0.01,w)),height=min(1,max(0.01,h))
            let frame=PluginSeasonalRectangle(x:min(1-width,max(0,x)),y:min(1-height,max(0,y)),width:width,height:height)
            layers.append(.init(id:id,asset:asset,frame:frame,firstDay:day,depth:depth,mirrored:mirror))
        }
        var overlay:PluginSeasonalOverlay = .sparks
        if scene.holiday == .christmas, let original=try? PluginSeasonalComposition.christmas(day:scene.day,year:scene.year,intensity:scene.intensity) {
            let central:Set<String>=["tree.original","tree.center","tree.right","gift.left","gift.right","gift.front-left","gift.front-right","lights.trees"]
            let scale=min(1,max(0.48,(floor-0.035)/0.465))
            for d in original.decorations {
                let f=d.frame,isCentral=central.contains(d.id)
                let asset=d.asset == .candyCane ? "candy-cane" : d.asset.rawValue
                add(d.id,asset,d.firstDay,isCentral ? cx+(f.x-0.5)*scale:f.x,isCentral ? floor+(f.y-0.5)*scale:f.y,isCentral ? f.width*scale:f.width,isCentral ? f.height*scale:f.height,d.depth < 0 ? d.depth:-0.05,d.variant%2 == 1 && [.garland,.stocking].contains(d.asset))
            }
            overlay = .snow
        } else {
            let heroes:[String],accents:[String]
            switch scene.holiday {
            case .newYear: heroes=["new-year"];accents=["star","bauble"];overlay = .sparks
            case .valentines: heroes=["rose-bouquet","heart"];accents=["heart"];overlay = .petals
            case .presidents: heroes=["civic-ribbon","laurel"];accents=["star"];overlay = .none
            case .stPatricks: heroes=["clover"];accents=["bauble","clover"];overlay = .sparks
            case .easter: heroes=["spring-eggs","spring-flowers"];accents=["spring-flowers"];overlay = .petals
            case .mothersDay: heroes=["rose-bouquet","heart"];accents=["spring-flowers"];overlay = .petals
            case .fathersDay: heroes=["blue-bouquet","star"];accents=["star"];overlay = .sparks
            case .memorial,.veterans: heroes=["memorial-candle","laurel"];accents=["laurel"];overlay = .none
            case .juneteenth: heroes=["juneteenth-ribbon","star"];accents=["star"];overlay = .sparks
            case .independence: heroes=["civic-ribbon","star"];accents=["star","bauble"];overlay = .sparks
            case .labor: heroes=["gear","laurel"];accents=["spring-flowers"];overlay = .none
            case .columbus: heroes=["compass","laurel"];accents=["star"];overlay = .none
            case .halloween: heroes=["pumpkin","lantern"];accents=["autumn-harvest","pumpkin"];overlay = .leaves
            case .thanksgiving: heroes=["turkey","autumn-harvest"];accents=["pumpkin","autumn-harvest"];overlay = .leaves
            case .christmas: heroes=[];accents=[]
            }
            let first=heroes.first ?? "star",second=heroes.dropFirst().first ?? first
            add("hero.left",first,1,cx-0.27,floor-0.27,0.18,0.27)
            add("hero.right",second,min(2,scene.totalDays),cx+0.09,floor-0.23,0.18,0.23,-0.15,true)
            for (index,asset) in accents.enumerated() {
                add("accent.left.\(index)",asset,min(3+index,scene.totalDays),0.025+Double(index)*0.08,0.20+Double(index)*0.13,0.14,0.20)
                add("accent.right.\(index)",asset,min(3+index,scene.totalDays),0.835-Double(index)*0.08,0.20+Double(index)*0.13,0.14,0.20,-0.15,true)
            }
            if scene.day == scene.totalDays {
                add("final.left",first,scene.totalDays,0.005,0.40,0.15,0.20)
                add("final.right",second,scene.totalDays,0.845,0.40,0.15,0.20,-0.15,true)
            }
        }
        let plan=Self(scene:scene,layout:layout,layers:layers,overlay:overlay)
        guard !layers.isEmpty,(try? plan.validate(catalog:catalog)) != nil else { return nil }
        return plan
    }
}
