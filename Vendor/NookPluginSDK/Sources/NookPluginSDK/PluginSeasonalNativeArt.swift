import Foundation
@preconcurrency import SceneKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
private typealias SeasonalArtColor = NSColor
#else
import UIKit
private typealias SeasonalArtColor = UIColor
#endif

/// Original miniature decoration geometry. Every returned node has unit height,
/// baseline y=0, centered x/z, with its presentation face toward +Z. The live
/// avatar and all content remain separate. No texture downloads, lights, timers,
/// animation players, particle systems or HDR-dependent glow are used here.
@MainActor enum PluginSeasonalNativeArt {
    private static var templates: [String: SCNNode] = [:]

    static func make(_ asset: PluginSeasonalDecorationAsset, variant: Int) -> SCNNode {
        let variant = ((variant % 3) + 3) % 3
        let key = asset.rawValue + "." + String(variant)
        if let template = templates[key] { return template.clone() }
        let mesh = Mesh()
        switch asset {
        case .evergreen: evergreen(mesh, variant)
        case .gift: gift(mesh, variant)
        case .lights: lights(mesh, variant)
        case .bauble: bauble(mesh, variant)
        case .garland: garland(mesh, variant)
        case .wreath: wreath(mesh, variant)
        case .stocking: stocking(mesh, variant)
        case .candyCane: candyCane(mesh, variant)
        case .bell: bell(mesh, variant)
        case .house: house(mesh, variant)
        case .snow: snow(mesh, variant)
        case .lantern: lantern(mesh, variant)
        case .star: mesh.star(center: V(0, 0.5, 0), radius: 0.49, depth: 0.09)
        }
        let geometry = mesh.geometry()
        geometry.name = "seasonal.original." + key
        let content = SCNNode(geometry: geometry)
        let bounds = content.boundingBox
        let h = max(0.0001, Double(bounds.max.y - bounds.min.y))
        let scale = 1 / h
        content.scale = vector(scale, scale, scale)
        content.position = vector(-Double(bounds.max.x + bounds.min.x) * scale / 2,
                                  -Double(bounds.min.y) * scale,
                                  -Double(bounds.max.z + bounds.min.z) * scale / 2)
        let root = SCNNode()
        root.name = "seasonal." + key
        root.addChildNode(content)
        templates[key] = root
        return root.clone()
    }

    private static func vector(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
        #else
        SCNVector3(Float(x), Float(y), Float(z))
        #endif
    }

    private enum Finish: Int, CaseIterable {
        case pine, forest, tips, bark, red, wine, cream, gold, paleGold, wire, bulb, snow, brick, window, glass
    }
    private static let materials: [SCNMaterial] = Finish.allCases.map { finish in
        let colors = ["#102D23", "#1C4430", "#355D40", "#493020", "#80251F",
                      "#541D23", "#DBCCAC", "#96702F", "#B99A54", "#3C392A",
                      "#FFD68B", "#F2EEE2", "#8C4E38", "#F7BB60", "#D8B56D"]
        let hex = colors[finish.rawValue]
        let number = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let color = SeasonalArtColor(red: CGFloat((number >> 16) & 255) / 255,
                                     green: CGFloat((number >> 8) & 255) / 255,
                                     blue: CGFloat(number & 255) / 255, alpha: 1)
        let material = SCNMaterial()
        material.name = "seasonal." + String(describing: finish)
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = [Finish.gold, .paleGold].contains(finish) ? 0.43 : 0.82
        material.metalness.contents = [Finish.gold, .paleGold].contains(finish) ? 0.72 : 0.02
        if finish == .bulb || finish == .window {
            material.emission.contents = color
            material.emission.intensity = finish == .bulb ? 0.65 : 0.42
            material.roughness.contents = 0.5
        }
        if finish == .glass {
            material.transparency = 0.18
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
        }
        return material
    }

    private struct V {
        var x: Double, y: Double, z: Double
        init(_ x: Double, _ y: Double, _ z: Double) { self.x=x; self.y=y; self.z=z }
        static let zero = V(0,0,0)
        static let up = V(0,1,0)
        static let front = V(0,0,1)
        static func + (a: V, b: V) -> V { V(a.x+b.x,a.y+b.y,a.z+b.z) }
        static func - (a: V, b: V) -> V { V(a.x-b.x,a.y-b.y,a.z-b.z) }
        static prefix func - (a: V) -> V { V(-a.x,-a.y,-a.z) }
        static func * (a: V, b: Double) -> V { V(a.x*b,a.y*b,a.z*b) }
        static func / (a: V, b: Double) -> V { a * (1/b) }
        var length: Double { sqrt(x*x+y*y+z*z) }
        var unit: V { length > 0.0000001 ? self / length : .up }
        func cross(_ b: V) -> V { V(y*b.z-z*b.y,z*b.x-x*b.z,x*b.y-y*b.x) }
        func rotatedZ(_ angle: Double) -> V { V(x*cos(angle)-y*sin(angle),x*sin(angle)+y*cos(angle),z) }
        func mix(_ b: V, _ t: Double) -> V { self*(1-t)+b*t }
    }

    /// One indexed geometry with a bounded set of material elements per asset.
    /// Tiny branches/needles are merged here, not left as thousands of SCNNodes.
    @MainActor private final class Mesh {
        var positions: [Float] = []
        var normals: [Float] = []
        var groups: [[UInt32]] = Array(repeating: [], count: Finish.allCases.count)

        func triangle(_ a: V, _ b: V, _ c: V, _ finish: Finish,
                      normals supplied: (V,V,V)? = nil) {
            let normal = (b-a).cross(c-a).unit
            let ns = supplied ?? (normal,normal,normal)
            let start = UInt32(positions.count / 3)
            for point in [a,b,c] { positions += [Float(point.x),Float(point.y),Float(point.z)] }
            for n in [ns.0,ns.1,ns.2] { normals += [Float(n.x),Float(n.y),Float(n.z)] }
            groups[finish.rawValue] += [start,start+1,start+2]
        }
        func quad(_ a: V, _ b: V, _ c: V, _ d: V, _ finish: Finish) {
            triangle(a,b,c,finish); triangle(a,c,d,finish)
        }
        func geometry() -> SCNGeometry {
            let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
            let normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
            let vertex = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count/3,
                                           usesFloatComponents: true, componentsPerVector: 3,
                                           bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let normal = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: normals.count/3,
                                           usesFloatComponents: true, componentsPerVector: 3,
                                           bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            var elements: [SCNGeometryElement] = [], used: [SCNMaterial] = []
            for finish in Finish.allCases where !groups[finish.rawValue].isEmpty {
                let indices = groups[finish.rawValue]
                let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
                elements.append(SCNGeometryElement(data: data, primitiveType: .triangles,
                                                   primitiveCount: indices.count/3, bytesPerIndex: 4))
                used.append(PluginSeasonalNativeArt.materials[finish.rawValue])
            }
            let geometry = SCNGeometry(sources: [vertex,normal], elements: elements)
            geometry.materials = used
            return geometry
        }

        func sphere(_ center: V, _ radii: V, _ finish: Finish, around: Int = 10, rows: Int = 6) {
            func point(_ u: Double, _ v: Double) -> (V,V) {
                let direction = V(sin(v)*cos(u),cos(v),sin(v)*sin(u))
                let normal = V(direction.x/radii.x,direction.y/radii.y,direction.z/radii.z).unit
                return (center+V(direction.x*radii.x,direction.y*radii.y,direction.z*radii.z),normal)
            }
            for y in 0..<rows {
                for x in 0..<around {
                    let u=Double(x)*2 * .pi/Double(around), un=Double(x+1)*2 * .pi/Double(around)
                    let v=Double(y) * .pi/Double(rows), vn=Double(y+1) * .pi/Double(rows)
                    let a=point(u,v), b=point(un,v), c=point(un,vn), d=point(u,vn)
                    if y > 0 { triangle(a.0,b.0,c.0,finish,normals:(a.1,b.1,c.1)) }
                    if y < rows-1 { triangle(a.0,c.0,d.0,finish,normals:(a.1,c.1,d.1)) }
                }
            }
        }

        func box(_ center: V, _ half: V, _ finish: Finish, bevel: Double = 0, angle: Double = 0) {
            let radius = min(bevel,min(half.x,min(half.y,half.z))*0.8)
            func axis(_ h: Double) -> [Double] {
                radius > 0 ? [-h,-h+radius*0.35,-h+radius,h-radius,h-radius*0.35,h] : [-h,h]
            }
            let axes=[axis(half.x),axis(half.y),axis(half.z)]
            for side in 0..<6 {
                let face=side/2, sign=side%2 == 0 ? -1.0:1.0
                let u=(face+1)%3, v=(face+2)%3
                func point(_ a: Double, _ b: Double) -> (V,V) {
                    var q=[0.0,0.0,0.0];q[face]=[half.x,half.y,half.z][face]*sign;q[u]=a;q[v]=b
                    let p=V(q[0],q[1],q[2])
                    if radius == 0 {
                        var n=[0.0,0.0,0.0];n[face]=sign
                        return (center+p.rotatedZ(angle),V(n[0],n[1],n[2]).rotatedZ(angle))
                    }
                    let inner=V(max(-half.x+radius,min(half.x-radius,p.x)),
                                max(-half.y+radius,min(half.y-radius,p.y)),
                                max(-half.z+radius,min(half.z-radius,p.z)))
                    let normal=(p-inner).unit
                    return (center+(inner+normal*radius).rotatedZ(angle),normal.rotatedZ(angle))
                }
                for i in 0..<(axes[u].count-1) {
                    for j in 0..<(axes[v].count-1) {
                        let a=point(axes[u][i],axes[v][j]), b=point(axes[u][i+1],axes[v][j])
                        let c=point(axes[u][i+1],axes[v][j+1]), d=point(axes[u][i],axes[v][j+1])
                        if sign > 0 {
                            triangle(a.0,b.0,c.0,finish,normals:(a.1,b.1,c.1));triangle(a.0,c.0,d.0,finish,normals:(a.1,c.1,d.1))
                        } else {
                            triangle(a.0,c.0,b.0,finish,normals:(a.1,c.1,b.1));triangle(a.0,d.0,c.0,finish,normals:(a.1,d.1,c.1))
                        }
                    }
                }
            }
        }

        func stem(_ from: V, _ to: V, _ radius: Double, _ finish: Finish,
                  end: Double? = nil, sides: Int = 5) {
            let direction=(to-from).unit
            let right=direction.cross(abs(direction.y) > 0.9 ? .front:.up).unit
            let front=right.cross(direction).unit
            for i in 0..<sides {
                let a=Double(i)*2 * .pi/Double(sides), b=Double(i+1)*2 * .pi/Double(sides)
                let na=right*cos(a)+front*sin(a), nb=right*cos(b)+front*sin(b)
                let x=from+na*radius, y=from+nb*radius, z=to+nb*(end ?? radius), w=to+na*(end ?? radius)
                triangle(x,z,y,finish,normals:(na,nb,nb));triangle(x,w,z,finish,normals:(na,na,nb))
                triangle(from,x,y,finish);triangle(to,z,w,finish)
            }
        }

        /// A real four-face tapered needle, not a transparent sprite/card.
        func needle(_ from: V, _ to: V, width: Double, _ finish: Finish) {
            let axis=(to-from).unit
            let right=axis.cross(abs(axis.y)>0.9 ? .front:.up).unit*width
            let other=axis.cross(right).unit*width
            let a=from+right, b=from-right*0.5+other*0.7, c=from-right*0.5-other*0.7
            triangle(a,b,to,finish);triangle(b,c,to,finish);triangle(c,a,to,finish);triangle(a,c,b,finish)
        }

        func tube(_ points: [V], radius: Double, _ finish: Finish, sides: Int = 6, striped: Bool = false) {
            guard points.count > 1 else { return }
            for i in 0..<(points.count-1) {
                let direction=(points[min(points.count-1,i+1)]-points[max(0,i-1)]).unit
                let right=direction.cross(.front).unit
                let front=right.cross(direction).unit
                for j in 0..<sides {
                    let a=Double(j)*2 * .pi/Double(sides), b=Double(j+1)*2 * .pi/Double(sides)
                    let na=right*cos(a)+front*sin(a), nb=right*cos(b)+front*sin(b)
                    let color: Finish = striped && Int(floor(Double(i)*0.8+Double(j)*0.35))%2 == 0 ? .red:finish
                    triangle(points[i]+na*radius,points[i+1]+nb*radius,points[i]+nb*radius,color,normals:(na,nb,nb))
                    triangle(points[i]+na*radius,points[i+1]+na*radius,points[i+1]+nb*radius,color,normals:(na,na,nb))
                }
            }
        }

        func ring(_ center: V, radius: Double, thickness: Double, _ finish: Finish,
                  vertical: Bool = true, segments: Int = 24) {
            let points=(0...segments).map { i -> V in
                let a=Double(i)*2 * .pi/Double(segments)
                return center+(vertical ? V(cos(a)*radius,sin(a)*radius,0):V(cos(a)*radius,0,sin(a)*radius))
            }
            tube(points,radius:thickness,finish,sides:6)
        }

        /// A closed, folded ribbon band. Edge faces and varying width give the
        /// bow physical thickness even when viewed above or obliquely.
        func ribbon(_ points: [V], width: Double, _ finish: Finish) {
            guard points.count > 1 else { return }
            var edges: [(V,V)] = []
            for i in points.indices {
                let direction=(points[min(points.count-1,i+1)]-points[max(0,i-1)]).unit
                let wave=sin(Double(i)/Double(points.count-1) * .pi)
                let across=V(-direction.y,direction.x,0).unit*width*(0.40+0.12*wave)
                edges.append((points[i]-across,points[i]+across))
            }
            let thickness=V.front*min(0.012,width*0.14)
            for i in 0..<(points.count-1) {
                let (a,b)=edges[i], (d,c)=edges[i+1]
                quad(d,c,b,a,finish)
                quad(a-thickness,b-thickness,c-thickness,d-thickness,finish)
                quad(a,d,d-thickness,a-thickness,finish)
                quad(c,b,b-thickness,c-thickness,finish)
            }
            let first=edges[0], last=edges[edges.count-1]
            quad(first.1,first.0,first.0-thickness,first.1-thickness,finish)
            quad(last.0,last.1,last.1-thickness,last.0-thickness,finish)
        }

        func bow(_ center: V, scale: Double, _ finish: Finish) {
            for side in [-1.0,1.0] {
                // Loops turn forward at their outer fold and return behind the
                // knot, rather than tracing a flat wire ellipse.
                let points=(0...32).map { i -> V in
                    let t=Double(i)/32 * .pi*2
                    return center+V(side*(0.025+0.17*(1-cos(t))),
                                    0.045+0.135*sin(t)+0.045*(1-cos(t)),
                                    0.075*(1-cos(t))+0.035*sin(t))*scale
                }
                ribbon(points,width:0.125*scale,finish)
                let tail=(0...9).map { i -> V in
                    let t=Double(i)/9
                    return center+V(side*(0.04+0.14*t+0.035*sin(t * .pi)),
                                    -0.015-0.32*t,0.045+0.045*sin(t * .pi*1.5))*scale
                }
                ribbon(tail,width:0.12*scale,finish)
            }
            box(center+V(0,0.035,0.07)*scale,V(0.068,0.06,0.058)*scale,finish,bevel:0.028*scale,angle:0.12)
        }

        /// Dense serrated branch mass, with a raised ridge and closed underside.
        /// This supports fine needles with an irregular, volumetric silhouette;
        /// it is neither a cone nor a billboard, and costs only 48 triangles.
        func spray(_ from: V, _ to: V, width: Double, depth: Double, _ finish: Finish, normal: V = .up) {
            let direction=(to-from).unit
            let across=direction.cross(normal).unit
            let up=across.cross(direction).unit
            let widths=[0.10,0.82,0.53,0.90,0.43,0.55,0.0]
            var left: [V]=[], right: [V]=[], top: [V]=[], bottom: [V]=[]
            for i in widths.indices {
                let t=Double(i)/Double(widths.count-1)
                let p=from.mix(to,t)+up*(sin(t * .pi)*depth*0.3)
                left.append(p-across*width*widths[i])
                right.append(p+across*width*widths[i])
                top.append(p+up*depth*sin(t * .pi))
                bottom.append(p-up*depth*0.55*sin(t * .pi))
            }
            func band(_ a: V, _ b: V, _ c: V, _ d: V, _ na: V, _ nb: V) {
                triangle(a,b,c,finish,normals:(na,na,nb))
                triangle(a,c,d,finish,normals:(na,nb,nb))
            }
            let leftNormal=(-across+up*0.45).unit, rightNormal=(across+up*0.45).unit
            let lowerLeft=(-across-up*0.45).unit, lowerRight=(across-up*0.45).unit
            for i in 0..<(widths.count-1) {
                band(top[i],top[i+1],left[i+1],left[i],up,leftNormal)
                band(right[i],right[i+1],top[i+1],top[i],rightNormal,up)
                band(left[i],left[i+1],bottom[i+1],bottom[i],lowerLeft,-up)
                band(bottom[i],bottom[i+1],right[i+1],right[i],-up,lowerRight)
            }

        }

        func polygon(_ points: [V], depth: Double, _ finish: Finish, bevel: Double = 0) {
            let area = points.indices.reduce(0.0) { total, i in
                let next = points[(i+1)%points.count]
                return total + points[i].x*next.y-next.x*points[i].y
            }
            let outline = area < 0 ? Array(points.reversed()) : points
            let center=outline.reduce(.zero,+)/Double(outline.count)
            let front=outline.map { $0+V.front*depth/2 }
            let back=outline.map { $0-V.front*depth/2 }
            for i in outline.indices {
                let next=(i+1)%outline.count
                let insetA=center+(outline[i]-center)*(1-bevel)+V.front*(depth/2+bevel*0.12)
                let insetB=center+(outline[next]-center)*(1-bevel)+V.front*(depth/2+bevel*0.12)
                triangle(center+V.front*(depth/2+bevel*0.12),insetA,insetB,finish)
                quad(insetA,front[i],front[next],insetB,finish)
                triangle(center-V.front*depth/2,back[next],back[i],finish)
                quad(front[next],front[i],back[i],back[next],finish)
            }
        }

        func star(center: V, radius: Double, depth: Double) {
            let outline=(0..<10).map { i -> V in
                let angle = .pi/2+Double(i) * .pi/5
                let r = i%2 == 0 ? radius:radius*0.43
                return center+V(cos(angle)*r,sin(angle)*r,0)
            }
            polygon(outline,depth:depth,.gold,bevel:0.16)
        }
    }

    private static func evergreen(_ m: Mesh, _ variant: Int) {
        m.stem(V(0,0,0),V(0,0.96,0),0.024,.bark,end:0.004,sides:8)
        // Staggered, overlapping boughs hide the trunk. Short side sprays make
        // each tier irregular; fine needle fans carry the smaller branch detail.
        for layer in 0..<10 {
            let height=0.15+Double(layer)*0.084
            let reach=pow(1-height,0.88)*0.405
            for branch in 0..<8 {
                let angle=Double(branch)*2 * .pi/8+Double(layer)*0.43+Double(variant)*0.25
                let out=V(cos(angle),0,sin(angle)), side=V(-sin(angle),0,cos(angle))
                let origin=V(0,height+0.065,0), end=out*reach+V(0,height-0.025,0)
                m.spray(origin,end,width:reach*0.25,depth:0.043,.pine)
                for twig in 0..<2 {
                    let t=0.34+Double(twig)*0.29, sign=twig%2 == 0 ? -1.0:1.0
                    let from=origin.mix(end,t)-out*0.025
                    let tip=from+out*(reach*0.42)+side*(reach*0.32*sign)+V(0,-0.017,0)
                    for n in 0..<18 {
                        let s=Double(n+1)/19
                        let start=from.mix(tip,s)+V(0,0.022+0.01*sin(s * .pi),0)
                        let sign=n%2 == 0 ? -1.0:1.0
                        let direction=(out*0.62+side*sign+V(0,0.30*sin(Double(n)*1.7),0)).unit
                        m.needle(start,start+direction*(0.041+reach*0.05),width:0.0028,
                                 (n+twig+layer)%7 == 0 ? .tips:.forest)
                    }
                }
                for n in 0..<8 {
                    let from=origin.mix(end,Double(n+1)/9)+V(0,0.038,0)
                    let sign=n%2 == 0 ? -1.0:1.0
                    m.needle(from,from+(out*0.4+side*sign+V(0,0.2,0)).unit*0.043,
                             width:0.003, n%4 == 0 ? .tips:.pine)
                }
            }
        }
        let spiral=(0...40).map { i -> V in
            let y=0.23+Double(i)*0.016, a=Double(i)*0.42
            let r=(1-y)*0.365
            return V(cos(a)*r,y,sin(a)*r)
        }
        m.tube(spiral,radius:0.003,.gold,sides:4)
        for i in stride(from:0,to:spiral.count,by:2) {
            m.sphere(spiral[i],V(0.010,0.012,0.010),.bulb,around:6,rows:4)
        }
        for i in 0..<18 {
            let y=0.23+Double(i%5)*0.13, angle=0.25+Double(i)*2.15
            let radius=pow(1-y,0.88)*0.41
            let p=V(cos(angle)*radius,y,sin(angle)*radius)
            m.sphere(p,V(0.023,0.026,0.023),i%3 == 0 ? .gold:(variant == 1 ? .wine:.red),around:8,rows:5)
            m.stem(p+V(0,0.018,0),p+V(0,0.032,0),0.004,.gold,sides:4)
        }
        m.star(center:V(0,1.035,0),radius:0.078,depth:0.022)
    }

    private static func gift(_ m: Mesh, _ variant: Int) {
        let body: Finish = variant == 0 ? .red:variant == 1 ? .cream:.forest
        let ribbon: Finish = variant == 1 ? .red:.paleGold
        m.box(V(0,0.36,0),V(0.37,0.33,0.30),body,bevel:0.035)
        m.box(V(0,0.715,0),V(0.385,0.045,0.315),body,bevel:0.016)
        m.box(V(0,0.36,0.306),V(0.047,0.35,0.012),ribbon,bevel:0.006)
        m.box(V(0,0.36,-0.306),V(0.047,0.35,0.012),ribbon)
        m.box(V(0,0.766,0),V(0.047,0.009,0.32),ribbon)
        m.box(V(0,0.767,0),V(0.39,0.009,0.045),ribbon)
        m.bow(V(0,0.82,0.015),scale:0.63,ribbon)
        for x in [-0.27,-0.14,0.14,0.27] {
            for y in [0.18,0.33,0.49,0.61] {
                m.sphere(V(x,y,0.304),V(0.008,0.008,0.003),variant == 1 ? .gold:.paleGold,around:6,rows:3)
            }
        }
    }

    private static func lights(_ m: Mesh, _ variant: Int) {
        let points=(0...48).map { i -> V in
            let x = -1.6+Double(i)/48*3.2
            return V(x,0.18+0.18*pow(x/1.6,2),0.025*sin(x*3))
        }
        m.tube(points,radius:0.010,.wire,sides:5)
        for i in 0..<15 {
            let t=Double(i)/14, x = -1.55+t*3.1, y=0.18+0.18*pow(x/1.6,2)
            m.stem(V(x,y,0),V(x,y-0.07,0),0.008,.wire,sides:5)
            m.sphere(V(x,y-0.093,0),V(0.029,0.043,0.029),.bulb,around:8,rows:5)
        }
    }

    private static func bauble(_ m: Mesh, _ variant: Int) {
        let finish: Finish = variant == 1 ? .gold:variant == 2 ? .wine:.red
        m.sphere(V(0,0.39,0),V(0.36,0.37,0.36),finish,around:20,rows:12)
        m.ring(V(0,0.39,0),radius:0.361,thickness:0.006,.paleGold,vertical:false,segments:32)
        m.box(V(0,0.795,0),V(0.075,0.045,0.075),.gold,bevel:0.012)
        m.ring(V(0,0.91,0),radius:0.072,thickness:0.013,.gold,segments:16)
        for i in 0..<12 {
            let a=Double(i)*2 * .pi/12
            m.sphere(V(cos(a)*0.303,0.57,sin(a)*0.303),V(0.015,0.018,0.015),.paleGold,around:6,rows:3)
        }
    }

    private static func foliage(_ m: Mesh, along points: [V], length: Double, variant: Int) {
        m.tube(points,radius:0.033,.pine,sides:5)
        for (index,p) in points.enumerated() {
            let tangent=(points[min(points.count-1,index+1)]-points[max(0,index-1)]).unit
            let side=tangent.cross(.front).unit
            // Three staggered front/back sprays and short needle fans at every
            // station overlap neighbours, building a lush rope with real depth.
            for cluster in 0..<3 {
                let a=Double(cluster)*2 * .pi/3+Double(index)*0.63
                let radial=side*cos(a)+V.front*sin(a)
                let from=p-tangent*length*0.48+radial*length*0.13
                let tip=p+tangent*length*0.72+radial*length*0.66
                m.spray(from-tangent*length*0.12,tip,
                        width:length*0.26,depth:length*0.14,
                        (index+cluster+variant)%5 == 0 ? .forest:.pine,normal:.front)
                for n in 0..<12 {
                    let t=Double(n+1)/13
                    let root=from.mix(tip,t)+radial*length*0.12
                    let sign=n%2 == 0 ? -1.0:1.0
                    let toward=(radial*0.7+tangent*0.5+side*sign*0.45).unit
                    m.needle(root,root+toward*length*0.48,width:length*0.023,
                             (index+n)%6 == 0 ? .tips:.forest)
                }
            }
        }
    }

    private static func garland(_ m: Mesh, _ variant: Int) {
        let points=(0...36).map { i -> V in
            let x = -1.5+Double(i)/36*3
            return V(x,0.25+0.25*pow(x/1.5,2),0.025*sin(x*5))
        }
        foliage(m,along:points,length:0.19,variant:variant)
        m.bow(V(-1.3,0.49,0.05),scale:0.6,.red)
        m.bow(V(1.3,0.49,0.05),scale:0.6,.red)
        for i in 0..<12 {
            let x = -1.35+Double(i)/11*2.7, y=0.25+0.25*pow(x/1.5,2)
            m.sphere(V(x,y-0.045,0.08),V(0.025,0.03,0.025),i%3 == 0 ? .bulb:(i%2 == 0 ? .red:.gold),around:8,rows:4)
        }
    }

    private static func wreath(_ m: Mesh, _ variant: Int) {
        let center=V(0,0.52,0)
        let points=(0...32).map { i -> V in let a=Double(i)*2 * .pi/32;return center+V(cos(a)*0.33,sin(a)*0.33,0) }
        foliage(m,along:points,length:0.15,variant:variant)
        for i in 0..<9 {
            let a=Double(i)*2 * .pi/9
            m.sphere(center+V(cos(a)*0.32,sin(a)*0.32,0.065),V(0.035,0.037,0.03),i%2 == 0 ? .red:.gold,around:8,rows:4)
        }
        m.bow(V(0,0.23,0.10),scale:0.72,.red)
    }

    private static func stocking(_ m: Mesh, _ variant: Int) {
        let outline=[V(-0.14,0.83,0),V(0.12,0.83,0),V(0.13,0.37,0),V(0.29,0.28,0),
                     V(0.36,0.18,0),V(0.33,0.08,0),V(0.19,0.035,0),V(-0.11,0.08,0),
                     V(-0.20,0.18,0),V(-0.17,0.40,0)]
        m.polygon(outline,depth:0.13,variant == 1 ? .wine:.red,bevel:0.09)
        m.box(V(-0.01,0.84,0),V(0.18,0.085,0.095),.cream,bevel:0.035)
        m.ring(V(-0.13,0.96,0),radius:0.055,thickness:0.015,.gold,segments:14)
        m.sphere(V(0.245,0.13,0.072),V(0.095,0.06,0.015),.cream,around:10,rows:4)
        for i in 0..<7 {
            m.stem(V(-0.12+Double(i)*0.039,0.75,0.08),V(-0.11+Double(i)*0.039,0.72,0.08),0.003,.paleGold,sides:4)
        }
        m.star(center:V(-0.005,0.54,0.09),radius:0.07,depth:0.008)
    }

    private static func candyCane(_ m: Mesh, _ variant: Int) {
        var points=(0...18).map { i -> V in V(-0.13,Double(i)/18*0.70,0) }
        points += (1...20).map { i -> V in let a = .pi-Double(i)/20 * .pi;return V(cos(a)*0.13,0.70+sin(a)*0.13,0) }
        points += [V(0.13,0.65,0),V(0.13,0.60,0)]
        m.tube(points,radius:0.037,.cream,sides:10,striped:true)
        m.bow(V(-0.13,0.45,0.045),scale:0.26,.red)
    }

    private static func bell(_ m: Mesh, _ variant: Int) {
        let profile=[(0.32,0.04),(0.34,0.08),(0.30,0.13),(0.235,0.25),(0.17,0.43),(0.11,0.52),(0.045,0.55)]
        for row in 0..<(profile.count-1) {
            for i in 0..<20 {
                let a=Double(i)*2 * .pi/20, b=Double(i+1)*2 * .pi/20
                let p=profile[row], q=profile[row+1]
                m.quad(V(cos(a)*p.0,p.1,sin(a)*p.0),V(cos(a)*q.0,q.1,sin(a)*q.0),
                       V(cos(b)*q.0,q.1,sin(b)*q.0),V(cos(b)*p.0,p.1,sin(b)*p.0),.gold)
            }
        }
        m.ring(V(0,0.065,0),radius:0.325,thickness:0.023,.paleGold,vertical:false,segments:32)
        m.sphere(V(0,0.04,0),V(0.055,0.065,0.055),.gold,around:10,rows:6)
        m.stem(V(0,0.06,0),V(0,0.49,0),0.014,.gold,sides:6)
        m.ring(V(0,0.64,0),radius:0.075,thickness:0.017,.gold,segments:16)
        m.bow(V(0,0.64,0.035),scale:0.40,variant == 1 ? .wine:.red)
    }

    private static func house(_ m: Mesh, _ variant: Int) {
        let wall: Finish = variant == 1 ? .brick:.cream
        m.box(V(0,0.045,0),V(0.42,0.045,0.30),.snow,bevel:0.028)
        m.box(V(0,0.32,0),V(0.34,0.255,0.235),wall,bevel:0.008)
        m.polygon([V(-0.34,0.57,0),V(0.34,0.57,0),V(0,0.85,0)],depth:0.47,wall)
        for side in [-1.0,1.0] {
            let angle=side * -0.69
            m.box(V(side*0.205,0.70,0),V(0.275,0.035,0.30),.bark,bevel:0.012,angle:angle)
            m.box(V(side*0.205,0.738,0),V(0.28,0.022,0.308),.snow,bevel:0.015,angle:angle)
            for i in 0..<5 {
                let x=side*(0.045+Double(i)*0.078), y=0.855-abs(x)*0.82
                m.stem(V(x,y,-0.30),V(x,y,0.30),0.003,.cream,sides:4)
            }
            for z in [-0.22,-0.07,0.09,0.23] {
                m.sphere(V(side*0.41,0.59,z),V(0.028,0.025,0.032),.snow,around:8,rows:4)
            }
        }
        m.box(V(0,0.235,0.247),V(0.075,0.17,0.018),.bark,bevel:0.023)
        m.sphere(V(0.045,0.22,0.269),V(0.009,0.009,0.009),.gold,around:8,rows:4)
        for x in [-0.21,0.21] {
            m.box(V(x,0.36,0.242),V(0.074,0.092,0.008),.window,bevel:0.012)
            for side in [-1.0,1.0] {
                m.box(V(x+side*0.081,0.36,0.256),V(0.008,0.10,0.014),.bark)
                m.box(V(x,0.36+side*0.099,0.256),V(0.089,0.008,0.014),.bark)
            }
            m.box(V(x,0.36,0.26),V(0.005,0.092,0.012),.gold)
            m.box(V(x,0.36,0.26),V(0.074,0.005,0.012),.gold)
        }
        m.sphere(V(0,0.68,0.242),V(0.054,0.054,0.006),.window,around:16,rows:6)
        m.ring(V(0,0.68,0.251),radius:0.06,thickness:0.008,.bark,segments:20)
        m.box(V(0.19,0.83,-0.06),V(0.055,0.135,0.06),.brick,bevel:0.006)
        m.box(V(0.19,0.972,-0.06),V(0.068,0.014,0.07),.snow,bevel:0.012)
        for y in [0.77,0.83,0.89] { m.box(V(0.19,y,0.001),V(0.055,0.003,0.002),.cream) }
        m.box(V(0,0.07,0.31),V(0.12,0.024,0.10),.snow,bevel:0.012)
        m.ring(V(0,0.29,0.272),radius:0.038,thickness:0.012,.forest,segments:16)
        m.bow(V(0,0.26,0.287),scale:0.075,.red)
    }

    private static func snow(_ m: Mesh, _ variant: Int) {
        m.sphere(V(0,0.115,0),V(0.62,0.115,0.30),.snow,around:20,rows:8)
        m.sphere(V(-0.32,0.13,0.02),V(0.32,0.13,0.25),.snow,around:14,rows:6)
        m.sphere(V(0.36,0.085,0.08),V(0.34,0.085,0.23),.snow,around:14,rows:6)
    }

    private static func lantern(_ m: Mesh, _ variant: Int) {
        m.box(V(0,0.055,0),V(0.23,0.055,0.20),.gold,bevel:0.018)
        m.box(V(0,0.12,0),V(0.20,0.025,0.17),.paleGold,bevel:0.012)
        for x in [-0.18,0.18] {
            for z in [-0.15,0.15] { m.stem(V(x,0.13,z),V(x,0.64,z),0.016,.gold,sides:6) }
        }
        m.quad(V(-0.17,0.14,0.15),V(0.17,0.14,0.15),V(0.17,0.62,0.15),V(-0.17,0.62,0.15),.glass)
        m.quad(V(-0.17,0.14,-0.15),V(-0.17,0.62,-0.15),V(0.17,0.62,-0.15),V(0.17,0.14,-0.15),.glass)
        m.box(V(0,0.65,0),V(0.22,0.035,0.19),.gold,bevel:0.012)
        let apex=V(0,0.84,0)
        let corners=[V(-0.23,0.68,0.20),V(0.23,0.68,0.20),V(0.23,0.68,-0.20),V(-0.23,0.68,-0.20)]
        for i in 0..<4 { m.triangle(corners[i],corners[(i+1)%4],apex,.gold) }
        m.ring(V(0,0.94,0),radius:0.085,thickness:0.017,.gold,segments:20)
        m.stem(V(0,0.13,0),V(0,0.35,0),0.065,.cream,sides:12)
        m.stem(V(0,0.35,0),V(0,0.40,0),0.004,.bark,sides:5)
        m.sphere(V(0,0.435,0),V(0.035,0.071,0.025),.bulb,around:10,rows:6)
        m.sphere(V(0.012,0.474,0),V(0.014,0.043,0.012),.window,around:8,rows:5)
    }
}
