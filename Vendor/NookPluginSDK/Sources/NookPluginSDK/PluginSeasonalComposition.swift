import Foundation

/// Portable normalized layout; no platform view, file path or action authority.
public struct PluginSeasonalRectangle: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }
    public func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width > 0, height > 0, x+width <= 1.000000001,
              y+height <= 1.000000001 else { throw ModuleProblem("Invalid normalized scene rectangle.") }
    }
    public func intersects(_ other: Self) -> Bool {
        x < other.x+other.width && other.x < x+width && y < other.y+other.height && other.y < y+height
    }
    /// Disjoint pieces, so overlapping protected regions cannot toggle a hole
    /// back on as they would in a naive even-odd mask.
    func subtracting(_ other: Self) -> [Self] {
        guard intersects(other) else { return [self] }
        let left=max(x,other.x), right=min(x+width,other.x+other.width)
        let top=max(y,other.y), bottom=min(y+height,other.y+other.height)
        var result: [Self] = []
        if top > y { result.append(.init(x:x,y:y,width:width,height:top-y)) }
        if bottom < y+height { result.append(.init(x:x,y:bottom,width:width,height:y+height-bottom)) }
        if left > x { result.append(.init(x:x,y:top,width:left-x,height:bottom-top)) }
        if right < x+width { result.append(.init(x:right,y:top,width:x+width-right,height:bottom-top)) }
        return result
    }
}

public struct PluginSeasonalSurfaceLayout: Codable, Equatable, Sendable {
    public var version = 1
    public var avatar: PluginSeasonalRectangle
    public var protectedRegions: [PluginSeasonalRectangle]
    public init(avatar: PluginSeasonalRectangle, protectedRegions: [PluginSeasonalRectangle]) {
        self.avatar=avatar; self.protectedRegions=protectedRegions
    }
    public static var voice: Self {
        .init(avatar:.init(x:0.4625,y:0.321,width:0.075,height:0.148), protectedRegions:[
            .init(x:0,y:0,width:0.23,height:0.105),
            .init(x:0.94,y:0,width:0.06,height:0.105),
            .init(x:0.18,y:0.54,width:0.64,height:0.23),
            .init(x:0.03,y:0.82,width:0.94,height:0.18)
        ])
    }
    public func validate() throws {
        guard version == 1, protectedRegions.count <= 16 else { throw ModuleProblem("Unsupported seasonal surface layout.") }
        try avatar.validate(); try protectedRegions.forEach { try $0.validate() }
    }
    public func decorationRegions(protectAvatar: Bool = true) throws -> [PluginSeasonalRectangle] {
        try validate()
        var pieces=[PluginSeasonalRectangle(x:0,y:0,width:1,height:1)]
        for hole in (protectAvatar ? [avatar] : []) + protectedRegions {
            pieces=pieces.flatMap { $0.subtracting(hole) }
            guard pieces.count <= 512 else { throw ModuleProblem("Seasonal layout is too complex.") }
        }
        return pieces
    }
}

public enum PluginSeasonalDecorationAsset: String, Codable, CaseIterable, Sendable {
    case evergreen, gift, lights, bauble, garland, wreath, stocking, candyCane, bell, house, snow, lantern, star
}
public struct PluginSeasonalDecoration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var asset: PluginSeasonalDecorationAsset
    public var frame: PluginSeasonalRectangle
    public var firstDay: Int
    public var depth: Double
    public var variant: Int
    public init(id: String, asset: PluginSeasonalDecorationAsset, frame: PluginSeasonalRectangle, firstDay: Int, depth: Double = 0, variant: Int = 0) {
        self.id=id; self.asset=asset; self.frame=frame; self.firstDay=firstDay; self.depth=depth; self.variant=variant
    }
    public func validate() throws {
        guard id.utf8.count <= 96, id.range(of:"^[a-z][a-z0-9.-]*$",options:.regularExpression) != nil,
              (1...12).contains(firstDay), depth.isFinite, (-1...1).contains(depth), (0...7).contains(variant)
        else { throw ModuleProblem("Invalid seasonal decoration.") }
        try frame.validate()
    }
}

/// Layer data cannot load arbitrary models, URLs, code or capture media.
public struct PluginSeasonalComposition: Codable, Equatable, Sendable {
    public var version = 1
    public var scene: PluginSeasonalScene
    public var layout: PluginSeasonalSurfaceLayout
    public var decorations: [PluginSeasonalDecoration]
    public init(scene: PluginSeasonalScene, layout: PluginSeasonalSurfaceLayout, decorations: [PluginSeasonalDecoration]) {
        self.scene=scene; self.layout=layout; self.decorations=decorations
    }
    public func validate() throws {
        guard version == 1, scene.holiday == .christmas, decorations.count <= 64,
              Set(decorations.map(\.id)).count == decorations.count,
              decorations.allSatisfy({ $0.firstDay <= scene.day && ($0.depth < 0 || !$0.frame.intersects(layout.avatar)) }) else { throw ModuleProblem("Unsupported seasonal composition.") }
        try scene.validate(); try layout.validate(); try decorations.forEach { try $0.validate() }
    }
    /// Opt-in adapter for an already resolved passive appearance snapshot.
    /// Other holidays retain their existing fallback; an invalid delivery or
    /// Off selection cannot become an active rich composition here.
    public static func resolve(scene: PluginSeasonalScene?, layout: PluginSeasonalSurfaceLayout = .voice) -> Self? {
        guard let scene, scene.holiday == .christmas, scene.intensity != .off,
              (try? scene.validate()) != nil else { return nil }
        return try? christmas(day: scene.day, year: scene.year, intensity: scene.intensity, layout: layout)
    }
    public static func christmas(day: Int, year: Int = 2026, intensity: PluginSceneIntensity = .low,
                                 layout: PluginSeasonalSurfaceLayout = .voice) throws -> Self {
        let scene=PluginSeasonalScene(holiday:.christmas,year:year,day:day,totalDays:12,intensity:intensity)
        try scene.validate(); try layout.validate()
        var all: [PluginSeasonalDecoration] = []
        func add(_ id: String, _ asset: PluginSeasonalDecorationAsset, _ day: Int,
                 _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ variant: Int = 0, _ depth: Double = 0) {
            all.append(.init(id:id,asset:asset,frame:.init(x:x,y:y,width:w,height:h),firstDay:day,depth:depth,variant:variant))
        }
        add("tree.original",.evergreen,1,0.34,0.19,0.14,0.31,0,-0.2)
        add("tree.center",.evergreen,2,0.43,0.07,0.14,0.43,1,-0.3)
        add("tree.right",.evergreen,2,0.55,0.20,0.14,0.30,2,-0.2)
        add("gift.left",.gift,2,0.33,0.405,0.09,0.095)
        add("gift.right",.gift,2,0.59,0.42,0.085,0.08,1)
        add("gift.front-left",.gift,3,0.40,0.445,0.05,0.065,2)
        add("gift.front-right",.gift,3,0.555,0.45,0.05,0.06,0)
        add("lights.trees",.lights,3,0.365,0.18,0.27,0.07)
        add("bauble.left",.bauble,4,0.14,0.11,0.045,0.15)
        add("bauble.right",.bauble,4,0.82,0.09,0.045,0.16,1)
        add("garland.left",.garland,5,0.025,0.015,0.46,0.17)
        add("garland.right",.garland,6,0.50,0.015,0.475,0.17,1)
        add("wreath.right",.wreath,6,0.76,0.12,0.12,0.20)
        add("stocking.left",.stocking,7,0.14,0.22,0.065,0.18)
        add("stocking.right",.stocking,7,0.82,0.25,0.06,0.16,1)
        add("candy.left",.candyCane,7,0.235,0.14,0.035,0.18)
        add("bell.left",.bell,8,0.05,0.17,0.065,0.13)
        add("bell.right",.bell,8,0.915,0.15,0.065,0.13,1)
        add("lights.upper",.lights,8,0.24,0.015,0.52,0.055)
        add("house.left",.house,9,0.035,0.29,0.15,0.24,0,-0.1)
        add("house.right",.house,9,0.805,0.29,0.15,0.24,1,-0.1)
        add("tree.outer-left",.evergreen,10,0.005,0.205,0.125,0.34,3,-0.3)
        add("tree.outer-right",.evergreen,10,0.87,0.205,0.125,0.34,3,-0.3)
        add("snow.left",.snow,10,0,0.51,0.18,0.055)
        add("snow.right",.snow,10,0.82,0.51,0.18,0.055)
        add("lantern.left",.lantern,11,0.015,0.46,0.06,0.13)
        add("lantern.right",.lantern,11,0.925,0.46,0.06,0.13)
        add("star.upper-left",.star,11,0.30,0.17,0.04,0.07)
        add("star.upper-right",.star,11,0.68,0.18,0.04,0.07)
        add("gift.outer-left",.gift,11,0.09,0.48,0.08,0.08,2)
        add("gift.outer-right",.gift,11,0.83,0.48,0.08,0.08,1)
        add("tree.inner-left",.evergreen,12,0.19,0.285,0.09,0.23,3,-0.3)
        add("tree.inner-right",.evergreen,12,0.72,0.285,0.09,0.23,3,-0.3)
        add("gift.perimeter-left",.gift,12,0.25,0.47,0.06,0.07,1)
        add("gift.perimeter-right",.gift,12,0.69,0.47,0.06,0.07,2)
        add("bauble.upper",.bauble,12,0.625,0.04,0.04,0.13)
        let result=Self(scene:scene,layout:layout,decorations:all.filter { $0.firstDay <= day })
        try result.validate(); return result
    }
}
