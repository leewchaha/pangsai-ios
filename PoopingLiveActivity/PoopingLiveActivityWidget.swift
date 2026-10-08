import ActivityKit
import SwiftUI
import WidgetKit
import UIKit

/// A lightweight snapshot of the same facial-feature-free 3D model. SceneKit and
/// GIF playback cannot run continuously in a suspended Dynamic Island extension.
/// The image is published by the app in an App Group, never fetched from network.
private struct PoopLiveIcon: View {
    var cosmeticID: String
    var size: CGFloat
    var imageReady: Bool
    var privateMode: Bool

    private var image: UIImage? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.sakara.shittyfriends") else { return nil }
        let file = directory.appendingPathComponent("pooping-live-\(cosmeticID).png")
        return UIImage(contentsOfFile: file.path)
    }

    var body: some View {
        Group {
            if privateMode {
                Image(systemName: "clock.fill")
                    .resizable().scaledToFit().foregroundStyle(.white)
                    .padding(size * 0.12)
            } else if imageReady, let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                // Faceless silhouette while the first 3D snapshot is prepared.
                ZStack {
                    Circle().fill(Color(red: 0.29, green: 0.14, blue: 0.07)).frame(width: size * 0.74, height: size * 0.45).offset(y: size * 0.16)
                    Ellipse().fill(Color(red: 0.44, green: 0.22, blue: 0.11)).frame(width: size * 0.58, height: size * 0.40).offset(y: -size * 0.02)
                    Ellipse().fill(Color(red: 0.57, green: 0.31, blue: 0.15)).frame(width: size * 0.36, height: size * 0.34).offset(y: -size * 0.20)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PoopLiveTimer: View {
    var startedAt: Date
    var body: some View {
        // Native .timer text updates without background tasks or frequent ActivityKit pushes.
        Text(startedAt, style: .timer)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct PoopingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PoopingActivityAttributes.self) { context in
            HStack(spacing: 14) {
                PoopLiveIcon(cosmeticID: context.attributes.cosmeticID, size: 74, imageReady: context.state.imageReady, privateMode: context.state.privateMode)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.state.privateMode ? "SESSION ACTIVE" : "CURRENTLY POOPING").font(.caption.weight(.heavy))
                    PoopLiveTimer(startedAt: context.attributes.startedAt)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "shittyfriends://open-session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PoopLiveIcon(cosmeticID: context.attributes.cosmeticID, size: 56, imageReady: context.state.imageReady, privateMode: context.state.privateMode)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.privateMode ? "ACTIVE" : "POOPING").font(.caption.weight(.heavy))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PoopLiveTimer(startedAt: context.attributes.startedAt)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Tap to return to your session")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                PoopLiveIcon(cosmeticID: context.attributes.cosmeticID, size: 26, imageReady: context.state.imageReady, privateMode: context.state.privateMode)
            } compactTrailing: {
                PoopLiveTimer(startedAt: context.attributes.startedAt)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: 72)
            } minimal: {
                PoopLiveIcon(cosmeticID: context.attributes.cosmeticID, size: 24, imageReady: context.state.imageReady, privateMode: context.state.privateMode)
            }
            .keylineTint(.white)
            .widgetURL(URL(string: "shittyfriends://open-session"))
        }
    }
}

@main
struct PoopingActivityBundle: WidgetBundle {
    var body: some Widget { PoopingLiveActivityWidget() }
}
