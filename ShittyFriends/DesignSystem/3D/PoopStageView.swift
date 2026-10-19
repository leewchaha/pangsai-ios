import SceneKit
import SwiftUI
import UIKit

/// The big live 3D poop. Taps are handled by SwiftUI on top; this view only animates:
/// every change of `pulse` squashes, stretches and wobbles the poop, harder with combo/critical.
struct PoopStageView: UIViewRepresentable {
    var cosmetic: CosmeticID
    var pulse: Int = 0
    var comboLevel: Int = 0
    var critical: Bool = false
    var idleSpin: Bool = true
    /// Live, framerate-heavy views only where it matters.
    var hdr: Bool = true

    final class Coordinator {
        var cosmetic: CosmeticID?
        var lastPulse = 0
        var holder: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isPlaying = true
        install(cosmetic, in: view, context: context)
        context.coordinator.lastPulse = pulse
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.cosmetic != cosmetic { install(cosmetic, in: view, context: context) }
        if pulse != c.lastPulse {
            c.lastPulse = pulse
            if let holder = c.holder { animateTap(holder) }
        }
    }

    private func install(_ id: CosmeticID, in view: SCNView, context: Context) {
        let poop = PoopFactory.node(id)
        let (scene, camera) = Stage.make(subject: poop, hdr: hdr)
        view.scene = scene
        view.pointOfView = camera
        let holder = scene.rootNode.childNode(withName: "holder", recursively: false)
        context.coordinator.holder = holder
        context.coordinator.cosmetic = id
        // The idle sway/bob is decoration; Reduce Motion gets a still model (taps still animate).
        if idleSpin && !UIAccessibility.isReduceMotionEnabled {
            let sway = SCNAction.sequence([
                .rotateBy(x: 0, y: 0.5, z: 0, duration: 2.2),
                .rotateBy(x: 0, y: -1.0, z: 0, duration: 4.4),
                .rotateBy(x: 0, y: 0.5, z: 0, duration: 2.2)
            ])
            sway.timingMode = .easeInEaseOut
            poop.runAction(.repeatForever(sway), forKey: "idle")
            let bob = SCNAction.sequence([.moveBy(x: 0, y: 0.03, z: 0, duration: 1.1), .moveBy(x: 0, y: -0.03, z: 0, duration: 1.1)])
            bob.timingMode = .easeInEaseOut
            poop.runAction(.repeatForever(bob), forKey: "bob")
        }
    }

    private func animateTap(_ holder: SCNNode) {
        let level = Double(min(5, max(0, comboLevel)))
        let amp = 0.16 + 0.05 * level + (critical ? 0.14 : 0)
        let squash = CAKeyframeAnimation(keyPath: "scale")
        squash.values = [
            NSValue(scnVector3: SCNVector3(1, 1, 1)),
            NSValue(scnVector3: SCNVector3(Float(1 + amp), Float(1 - amp * 1.2), Float(1 + amp))),
            NSValue(scnVector3: SCNVector3(Float(1 - amp * 0.5), Float(1 + amp * 0.9), Float(1 - amp * 0.5))),
            NSValue(scnVector3: SCNVector3(Float(1 + amp * 0.2), Float(1 - amp * 0.25), Float(1 + amp * 0.2))),
            NSValue(scnVector3: SCNVector3(1, 1, 1))
        ]
        squash.keyTimes = [0, 0.18, 0.45, 0.72, 1]
        squash.duration = 0.38
        squash.isRemovedOnCompletion = true
        holder.removeAnimation(forKey: "squash")
        holder.addAnimation(squash, forKey: "squash")

        let tilt = Double.random(in: -1...1) * (0.12 + 0.03 * level)
        let wobble = SCNAction.sequence([
            .rotateBy(x: 0, y: 0, z: CGFloat(tilt), duration: 0.06),
            .rotateBy(x: 0, y: 0, z: CGFloat(-tilt * 2), duration: 0.1),
            .rotateBy(x: 0, y: 0, z: CGFloat(tilt), duration: 0.08)
        ])
        let hop = SCNAction.sequence([
            .moveBy(x: 0, y: CGFloat(0.06 + 0.02 * level + (critical ? 0.18 : 0)), z: 0, duration: 0.09),
            .moveBy(x: 0, y: CGFloat(-(0.06 + 0.02 * level + (critical ? 0.18 : 0))), z: 0, duration: 0.16)
        ])
        hop.timingMode = .easeOut
        var group: [SCNAction] = [wobble, hop]
        if critical { group.append(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.5)) }
        holder.runAction(.group(group))
    }
}
