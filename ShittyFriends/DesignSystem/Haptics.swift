import UIKit

/// Haptic vocabulary. Heavy for +1, light ticks for taps, a rigid snap for criticals.
@MainActor
enum Haptics {
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notify = UINotificationFeedbackGenerator()

    static func prepare() {
        heavy.prepare()
        light.prepare()
    }

    static func play(_ kind: HapticKind) {
        switch kind {
        case .logHeavy:
            heavy.impactOccurred(intensity: 1)
            after(0.09) { rigid.impactOccurred(intensity: 0.7) }
        case .tapLight:
            light.impactOccurred(intensity: 0.75)
        case .tapCritical:
            rigid.impactOccurred(intensity: 1)
            after(0.06) { heavy.impactOccurred(intensity: 0.8) }
        case .success:
            notify.notificationOccurred(.success)
        case .warning:
            notify.notificationOccurred(.warning)
        case .reaction:
            soft.impactOccurred(intensity: 0.9)
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            body()
        }
    }

    static func tick() { light.impactOccurred(intensity: 0.5) }
    static func press() { soft.impactOccurred(intensity: 0.6) }
}
