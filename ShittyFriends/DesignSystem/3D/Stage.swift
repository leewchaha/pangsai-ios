import Metal
import SceneKit
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "3d")

/// A lit scene with a camera framing one object. Shared by live views and snapshots.
enum Stage {
    static func make(subject: SCNNode, height: Float = 1.15, cameraDistance: Float = 3.1, hdr: Bool = true) -> (scene: SCNScene, camera: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = Textures.studio
        scene.lightingEnvironment.intensity = 1.4

        let holder = SCNNode()
        holder.name = "holder"
        holder.addChildNode(subject)
        scene.rootNode.addChildNode(holder)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.color = UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1)
        key.eulerAngles = SCNVector3(-0.75, 0.55, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 500
        rim.light?.color = UIColor(red: 0.75, green: 0.85, blue: 1, alpha: 1)
        rim.eulerAngles = SCNVector3(-0.3, Float.pi * 0.85, 0)
        scene.rootNode.addChildNode(rim)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 180
        scene.rootNode.addChildNode(ambient)

        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = 30
        cam.zNear = 0.1
        cam.zFar = 50
        cam.wantsHDR = hdr
        if hdr {
            cam.bloomIntensity = 0.5
            cam.bloomThreshold = 0.85
            cam.bloomBlurRadius = 6
            cam.wantsExposureAdaptation = false
        }
        camNode.camera = cam
        camNode.position = SCNVector3(0, height * 0.62 + 0.35, cameraDistance)
        camNode.look(at: SCNVector3(0, height * 0.5, 0))
        scene.rootNode.addChildNode(camNode)
        return (scene, camNode)
    }
}

/// Renders 3D objects to images off the main thread and caches them.
/// Lists (calendar, collection, trophies, reactions) use these images; only hero views run live 3D.
@MainActor
@Observable
final class RenderCache {
    static let shared = RenderCache()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.sakara.shittyfriends.render", qos: .userInitiated)
    @ObservationIgnored private let device = MTLCreateSystemDefaultDevice()

    enum Subject: Hashable, Sendable {
        case poop(CosmeticID)
        case trophy(TrophyObject)
        case group(GroupObject)

        var key: String {
            switch self {
            case .poop(let id): return "p-" + id.rawValue
            case .trophy(let t): return "t-" + t.rawValue
            case .group(let g): return "g-" + g.rawValue
            }
        }

        func build() -> SCNNode {
            switch self {
            case .poop(let id): return PoopFactory.node(id)
            case .trophy(let t): return TrophyFactory.node(t)
            case .group(let g): return TrophyFactory.node(g)
            }
        }
    }

    /// Renders at a fixed 3x of a 160pt square; views scale it down.
    static let pixelSize = CGSize(width: 480, height: 480)

    func image(_ subject: Subject) -> UIImage? {
        let key = subject.key
        if let img = images[key] { return img }
        request(subject)
        return nil
    }

    func request(_ subject: Subject) {
        let key = subject.key
        guard images[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let device = self.device
        queue.async {
            let node = subject.build()
            node.eulerAngles.y = -0.35
            let (scene, camera) = Stage.make(subject: node)
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = camera
            renderer.autoenablesDefaultLighting = false
            let image = renderer.snapshot(atTime: 0, with: RenderCache.pixelSize, antialiasingMode: .multisampling4X)
            Task { @MainActor in
                RenderCache.shared.images[key] = image
                RenderCache.shared.inFlight.remove(key)
            }
        }
    }

    /// Warm up the most visible renders right after launch.
    func prewarm() {
        for id in CosmeticID.allCases { request(.poop(id)) }
        for t in TrophyObject.allCases { request(.trophy(t)) }
        for g in GroupObject.allCases { request(.group(g)) }
    }
}

/// SwiftUI image of a pre-rendered 3D object, with a soft placeholder while rendering.
struct Object3DImage: View {
    let subject: RenderCache.Subject
    var size: CGFloat = 64
    var locked = false

    var body: some View {
        let cache = RenderCache.shared
        Group {
            if let img = cache.image(subject) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(placeholder)
                    .font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
        .saturation(locked ? 0 : 1)
        .brightness(locked ? -0.35 : 0)
        .opacity(locked ? 0.55 : 1)
        .accessibilityHidden(true)
    }

    private var placeholder: String {
        switch subject {
        case .poop: return "💩"
        case .trophy: return "🏆"
        case .group(let g): return g.emoji
        }
    }
}
