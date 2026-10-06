import SceneKit
import UIKit

/// Builds 3D poops: procedural swirl body (from Core's PoopMesh), cute face, cosmetic extras.
enum PoopFactory {
    private static var geometryCache: [String: SCNGeometry] = [:]
    private static var layoutCache: [String: FaceLayout] = [:]
    private static let lock = NSLock()

    static func shape(for id: CosmeticID) -> PoopShape {
        id == .softServe ? .softServe : .classic
    }

    static func geometry(_ shape: PoopShape) -> SCNGeometry {
        let key = "\(shape.hashValue)"
        lock.lock()
        if let g = geometryCache[key] { lock.unlock(); return g }
        lock.unlock()
        let mesh = PoopMesh.make(shape)
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        vertices.reserveCapacity(mesh.vertexCount)
        normals.reserveCapacity(mesh.vertexCount)
        uvs.reserveCapacity(mesh.vertexCount)
        for i in 0..<mesh.vertexCount {
            vertices.append(SCNVector3(mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]))
            normals.append(SCNVector3(mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2]))
            uvs.append(CGPoint(x: CGFloat(mesh.uvs[i * 2]), y: CGFloat(mesh.uvs[i * 2 + 1])))
        }
        let g = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)]
        )
        lock.lock()
        geometryCache[key] = g
        lock.unlock()
        return g
    }

    private static func layout(_ shape: PoopShape) -> FaceLayout {
        let key = "\(shape.hashValue)"
        lock.lock()
        if let l = layoutCache[key] { lock.unlock(); return l }
        lock.unlock()
        let l = PoopMesh.faceLayout(shape)
        lock.lock()
        layoutCache[key] = l
        lock.unlock()
        return l
    }

    /// A complete poop. The node's origin is at the bottom center; it is ~1.1 units tall.
    static func node(_ id: CosmeticID, face: Bool = true, lowPoly: Bool = false) -> SCNNode {
        var shape = shape(for: id)
        if lowPoly { shape = shape.lowPoly }
        let root = SCNNode()
        root.name = "poop"
        let geo = geometry(shape).copy() as! SCNGeometry
        geo.materials = [Materials.poop(id)]
        let body = SCNNode(geometry: geo)
        body.name = "body"
        root.addChildNode(body)
        let f = layout(shape)
        if face { root.addChildNode(faceNode(f, angry: id == .devil)) }
        addExtras(id, to: root, top: f.top)
        return root
    }

    private static func faceNode(_ f: FaceLayout, angry: Bool) -> SCNNode {
        let face = SCNNode()
        face.name = "face"
        let r = CGFloat(f.eyeRadius) * 1.25
        for side in [-1.0, 1.0] {
            let eye = SCNNode(geometry: SCNSphere(radius: r))
            eye.geometry?.materials = [Materials.eyeWhite]
            eye.position = SCNVector3(Float(side * f.eyeSpacing), Float(f.eyeY + 0.04), Float(f.eyeZ - Double(r) * 0.2))
            eye.scale = SCNVector3(1, 1.15, 0.7)
            let pupil = SCNNode(geometry: SCNSphere(radius: r * 0.55))
            pupil.geometry?.materials = [Materials.ink]
            pupil.position = SCNVector3(Float(-side * 0.012), -0.01, Float(r * 0.62))
            let glint = SCNNode(geometry: SCNSphere(radius: r * 0.17))
            glint.geometry?.materials = [Materials.emissive(.white)]
            glint.position = SCNVector3(Float(r * 0.18), Float(r * 0.22), Float(r * 0.5))
            pupil.addChildNode(glint)
            eye.addChildNode(pupil)
            if angry {
                let brow = SCNNode(geometry: SCNBox(width: r * 1.8, height: r * 0.35, length: r * 0.4, chamferRadius: r * 0.15))
                brow.geometry?.materials = [Materials.ink]
                brow.position = SCNVector3(0, Float(r * 1.05), Float(r * 0.45))
                brow.eulerAngles.z = Float(side * 0.45)
                eye.addChildNode(brow)
            }
            face.addChildNode(eye)
        }
        // Smile: a crescent extruded from a bezier path, sitting on the coil below the eyes.
        let w = CGFloat(f.mouthWidth)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -w / 2, y: 0))
        path.addQuadCurve(to: CGPoint(x: w / 2, y: 0), controlPoint: CGPoint(x: 0, y: -w * 0.75))
        path.addQuadCurve(to: CGPoint(x: -w / 2, y: 0), controlPoint: CGPoint(x: 0, y: -w * 0.32))
        path.close()
        path.flatness = 0.002
        let mouthShape = SCNShape(path: path, extrusionDepth: 0.04)
        mouthShape.materials = [Materials.ink]
        let mouth = SCNNode(geometry: mouthShape)
        // SCNShape extrudes symmetrically around z = 0, so its front face sits 0.02 in front of the node.
        mouth.position = SCNVector3(0, Float(f.mouthY + Double(w) * 0.25), Float(f.mouthZ - 0.002))
        face.addChildNode(mouth)
        return face
    }

    private static func addExtras(_ id: CosmeticID, to root: SCNNode, top: Double) {
        let topY = Float(top)
        switch id {
        case .angel:
            let halo = SCNNode(geometry: SCNTorus(ringRadius: 0.2, pipeRadius: 0.028))
            halo.geometry?.materials = [Materials.emissive(UIColor(hex: 0xFFE27A), intensity: 1.4)]
            halo.position = SCNVector3(0, topY + 0.14, 0)
            halo.eulerAngles.x = 0.25
            halo.name = "halo"
            root.addChildNode(halo)
            for side in [-1.0, 1.0] {
                let wing = SCNNode(geometry: SCNSphere(radius: 0.22))
                wing.geometry?.materials = [Materials.pbr(.white, rough: 0.35, coat: 0.6)]
                wing.scale = SCNVector3(0.35, 1.0, 0.75)
                wing.position = SCNVector3(Float(side * 0.55), 0.55, -0.12)
                wing.eulerAngles.z = Float(side * -0.5)
                root.addChildNode(wing)
            }
        case .devil:
            for side in [-1.0, 1.0] {
                let horn = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.07, height: 0.24))
                horn.geometry?.materials = [Materials.pbr(UIColor(hex: 0x2B0A0A), rough: 0.2, coat: 1)]
                horn.position = SCNVector3(Float(side * 0.17), topY - 0.12, 0.02)
                horn.eulerAngles.z = Float(side * -0.45)
                root.addChildNode(horn)
            }
        case .royal, .legendary:
            let crown = TrophyFactory.crown(scale: 0.42)
            crown.position = SCNVector3(0, topY - 0.06, 0)
            crown.eulerAngles.x = 0.12
            root.addChildNode(crown)
        default:
            break
        }
        if id == .radioactive || id == .legendary || id == .holographic || id == .disco {
            // Slow color/emission pulse for the animated tier.
            let emission = root.childNode(withName: "body", recursively: false)?.geometry?.firstMaterial?.emission
            let pulse = CABasicAnimation(keyPath: "intensity")
            pulse.fromValue = id == .radioactive ? 0.6 : 0.2
            pulse.toValue = id == .radioactive ? 1.6 : 0.8
            pulse.duration = id == .disco ? 0.5 : 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            emission?.addAnimation(pulse, forKey: "pulse")
        }
    }
}
