import Foundation

/// Procedural "soft swirl" poop geometry: a tube swept along a tapering conical helix,
/// plus a filler pad so the center never looks hollow. Pure math (no SceneKit) so it is unit-testable;
/// the 3D layer wraps the arrays into SCNGeometry. Units: roughly 1.0 tall.
public struct PoopShape: Hashable, Sendable {
    public var turns: Double = 2.45
    public var height: Double = 1.05
    public var baseRadius: Double = 0.46
    public var tubeRadius: Double = 0.25
    /// 0...1 how much the tip curls over.
    public var tipCurl: Double = 0.6
    /// Radial ridges like a piping-bag nozzle (0 = smooth).
    public var ridges: Int = 0
    public var ridgeDepth: Double = 0
    public var pathSegments: Int = 240
    public var ringSegments: Int = 30

    public init() {}

    public static let classic = PoopShape()

    public static var softServe: PoopShape {
        var s = PoopShape()
        s.turns = 3.0
        s.height = 1.1
        s.baseRadius = 0.40
        s.tubeRadius = 0.22
        s.tipCurl = 0.8
        s.ridges = 8
        s.ridgeDepth = 0.12
        return s
    }

    /// Lower-poly version for small renders and particles.
    public var lowPoly: PoopShape {
        var s = self
        s.pathSegments = 90
        s.ringSegments = 14
        return s
    }
}

public struct MeshData: Sendable {
    public var positions: [Float] = []
    public var normals: [Float] = []
    public var uvs: [Float] = []
    public var indices: [UInt32] = []

    public init() {}

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    public var bounds: (min: (Float, Float, Float), max: (Float, Float, Float)) {
        var mn: (Float, Float, Float) = (.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var mx: (Float, Float, Float) = (-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var i = 0
        while i + 2 < positions.count {
            mn = (min(mn.0, positions[i]), min(mn.1, positions[i + 1]), min(mn.2, positions[i + 2]))
            mx = (max(mx.0, positions[i]), max(mx.1, positions[i + 1]), max(mx.2, positions[i + 2]))
            i += 3
        }
        return (mn, mx)
    }

    mutating func append(_ other: MeshData) {
        let offset = UInt32(vertexCount)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        indices += other.indices.map { $0 + offset }
    }

    /// Area-weighted smooth normals from triangles.
    mutating func recomputeNormals() {
        var n = [Double](repeating: 0, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]) * 3, b = Int(indices[t + 1]) * 3, c = Int(indices[t + 2]) * 3
            let ux = Double(positions[b] - positions[a]), uy = Double(positions[b + 1] - positions[a + 1]), uz = Double(positions[b + 2] - positions[a + 2])
            let vx = Double(positions[c] - positions[a]), vy = Double(positions[c + 1] - positions[a + 1]), vz = Double(positions[c + 2] - positions[a + 2])
            let cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx
            for k in [a, b, c] {
                n[k] += cx
                n[k + 1] += cy
                n[k + 2] += cz
            }
            t += 3
        }
        normals = [Float](repeating: 0, count: positions.count)
        var i = 0
        while i + 2 < n.count {
            let len = (n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]).squareRoot()
            if len > 1e-12 {
                normals[i] = Float(n[i] / len)
                normals[i + 1] = Float(n[i + 1] / len)
                normals[i + 2] = Float(n[i + 2] / len)
            } else {
                normals[i + 1] = 1
            }
            i += 3
        }
    }
}

/// Surface-measured placement for the cartoon face.
public struct FaceLayout: Hashable, Sendable {
    public var eyeY: Double
    /// Surface z at the eye positions (eye centers sit slightly behind this so they bulge out).
    public var eyeZ: Double
    public var eyeSpacing: Double
    public var eyeRadius: Double
    public var mouthY: Double
    /// Surface z straight below the eyes at mouth height.
    public var mouthZ: Double
    public var mouthWidth: Double
    public var top: Double
}

public enum PoopMesh {
    struct V3 {
        var x: Double, y: Double, z: Double
        static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func - (a: V3, b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        static func * (a: V3, s: Double) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
        var length: Double { (x * x + y * y + z * z).squareRoot() }
        var normalized: V3 { let l = length; return l > 1e-12 ? self * (1 / l) : V3(x: 0, y: 1, z: 0) }
        func dot(_ o: V3) -> Double { x * o.x + y * o.y + z * o.z }
        func cross(_ o: V3) -> V3 { V3(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x) }
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Centerline of the swirl at parameter t in [0, 1]. The start is tucked into the center
    /// (hidden by the pad), the helix shrinks as it rises, and the tip pulls in and curls up.
    static func path(_ t: Double, _ s: PoopShape) -> V3 {
        let theta = s.turns * 2 * Double.pi * t
        let shrink = pow(1 - t, 0.75)
        var radius = s.baseRadius * shrink * (0.15 + 0.85 * smoothstep(0, 0.10, t)) + 0.015
        let curl = smoothstep(0.8, 1.0, t)
        radius *= (1 - 0.95 * curl * s.tipCurl)
        let rise = 0.16 * s.tipCurl
        let y = s.tubeRadius * 0.9 + (s.height - s.tubeRadius * 0.9 - rise) * pow(t, 1.05) + rise * curl
        return V3(x: radius * cos(theta), y: y, z: radius * sin(theta))
    }

    /// Tube radius along the swirl: quick swell at the start, gentle taper, pointy tip.
    static func tube(_ t: Double, _ s: PoopShape) -> Double {
        if t > 0.997 { return 0 }
        let start = smoothstep(0.0, 0.03, t).squareRoot()
        let taper = 1 - 0.55 * t
        let tip = pow(max(0, 1 - smoothstep(0.78, 1.0, t)), 0.7)
        return s.tubeRadius * start * taper * (0.12 + 0.88 * tip)
    }

    public static func make(_ s: PoopShape = .classic) -> MeshData {
        var mesh = swirl(s)
        mesh.append(pad(s))
        mesh.recomputeNormals()
        // Sit on y = 0
        let b = mesh.bounds
        var i = 1
        while i < mesh.positions.count {
            mesh.positions[i] -= b.min.1
            i += 3
        }
        return mesh
    }

    static func swirl(_ s: PoopShape) -> MeshData {
        var m = MeshData()
        let n = max(8, s.pathSegments)
        let ring = max(6, s.ringSegments)
        var tangentPrev = (path(0.001, s) - path(0, s)).normalized
        var normal = V3(x: 0, y: 1, z: 0).cross(tangentPrev).normalized
        if normal.length < 0.5 { normal = V3(x: 1, y: 0, z: 0) }

        for i in 0...n {
            let t = Double(i) / Double(n)
            let dt = 1.0 / Double(n)
            let a = path(max(0, t - dt), s)
            let b = path(min(1, t + dt), s)
            let tangent = (b - a).normalized
            // Parallel transport the frame.
            let axis = tangentPrev.cross(tangent)
            if axis.length > 1e-9 {
                let ax = axis.normalized
                let angle = acos(max(-1, min(1, tangentPrev.dot(tangent))))
                normal = rotate(normal, around: ax, by: angle)
            }
            normal = (normal - tangent * normal.dot(tangent)).normalized
            let binormal = tangent.cross(normal).normalized
            tangentPrev = tangent

            let center = path(t, s)
            let r = tube(t, s)
            for j in 0...ring {
                let phi = Double(j) / Double(ring) * 2 * Double.pi
                var rr = r
                if s.ridges > 0 { rr *= 1 + s.ridgeDepth * cos(Double(s.ridges) * phi) }
                let dir = normal * cos(phi) + binormal * sin(phi)
                let p = center + dir * rr
                m.positions += [Float(p.x), Float(p.y), Float(p.z)]
                m.normals += [Float(dir.x), Float(dir.y), Float(dir.z)]
                m.uvs += [Float(Double(j) / Double(ring)), Float(t)]
            }
        }
        let stride = UInt32(ring + 1)
        for i in 0..<UInt32(n) {
            for j in 0..<UInt32(ring) {
                let a = i * stride + j
                let b = a + stride
                m.indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return m
    }

    /// Squashed ellipsoid filling the base so the center reads solid from any angle.
    static func pad(_ s: PoopShape) -> MeshData {
        var m = MeshData()
        let rings = 14, segs = 28
        let rx = s.baseRadius * 0.9, ry = s.tubeRadius * 0.9, rz = s.baseRadius * 0.9
        let cy = s.tubeRadius * 0.9
        for i in 0...rings {
            let v = Double(i) / Double(rings)
            let theta = v * Double.pi
            for j in 0...segs {
                let u = Double(j) / Double(segs)
                let phi = u * 2 * Double.pi
                let x = rx * sin(theta) * cos(phi)
                let y = cy + ry * cos(theta)
                let z = rz * sin(theta) * sin(phi)
                m.positions += [Float(x), Float(y), Float(z)]
                m.normals += [0, 1, 0]
                m.uvs += [Float(u), Float(v * 0.1)]
            }
        }
        let stride = UInt32(segs + 1)
        for i in 0..<UInt32(rings) {
            for j in 0..<UInt32(segs) {
                let a = i * stride + j
                let b = a + stride
                m.indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return m
    }

    static func rotate(_ v: V3, around k: V3, by angle: Double) -> V3 {
        // Rodrigues' rotation formula
        let c = cos(angle), s = sin(angle)
        return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))
    }

    /// Where the face goes. Measured on the actual surface so the eyes sit on the coil and the
    /// mouth lands on the bulge of the coil below them (never buried, never floating).
    public static func faceLayout(_ s: PoopShape = .classic) -> FaceLayout {
        let mesh = make(s.lowPoly)
        let b = mesh.bounds
        let height = Double(b.max.1 - b.min.1)
        /// Max z of the surface near (x, y).
        func frontZ(x: Double, y: Double, dx: Double = 0.04, dy: Double = 0.025) -> Double? {
            var best: Double?
            var i = 0
            while i + 2 < mesh.positions.count {
                let px = Double(mesh.positions[i]), py = Double(mesh.positions[i + 1]), pz = Double(mesh.positions[i + 2])
                if abs(px - x) <= dx && abs(py - y) <= dy { best = max(best ?? -.infinity, pz) }
                i += 3
            }
            return best
        }
        let spacing = s.baseRadius * 0.36
        let eyeRadius = s.tubeRadius * 0.34
        let eyeY = height * 0.52
        let eyeZ = min(frontZ(x: -spacing, y: eyeY) ?? Double(b.max.2), frontZ(x: spacing, y: eyeY) ?? Double(b.max.2))
        // Mouth: the most forward point straight below the eyes, i.e. the equator of that coil.
        var mouthY = eyeY - eyeRadius * 2.2
        var mouthZ = frontZ(x: 0, y: mouthY) ?? eyeZ
        var y = eyeY - eyeRadius * 1.6
        while y >= max(0.08, eyeY - 0.42) {
            if let z = frontZ(x: 0, y: y), z > mouthZ + 0.004 {
                mouthZ = z
                mouthY = y
            }
            y -= 0.01
        }
        return FaceLayout(eyeY: eyeY, eyeZ: eyeZ, eyeSpacing: spacing, eyeRadius: eyeRadius, mouthY: mouthY, mouthZ: mouthZ, mouthWidth: spacing * 1.6, top: height)
    }
}
