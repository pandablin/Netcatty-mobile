import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct NetcattyWidgetsBundle: WidgetBundle {
  var body: some Widget {
    NetcattyLiveActivityWidget()
  }
}

private let connectedGreen = Color(red: 0.20, green: 0.84, blue: 0.42)
private let disconnectedOrange = Color(red: 1.0, green: 0.62, blue: 0.20)
private let tileBackground = Color(red: 0.11, green: 0.13, blue: 0.20)

/// Deep link back to the session shown in the activity. Flutter receives it
/// as the route "/session/<id>" and switches to that terminal.
private func sessionURL(_ state: NetcattyActivityAttributes.ContentState) -> URL? {
  let id = state.activeId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
  return URL(string: "netcatty:///session/\(id)")
}

private func statusColor(connected: Bool, stale: Bool) -> Color {
  if stale { return .gray }
  return connected ? connectedGreen : disconnectedOrange
}

private func countLabel(_ state: NetcattyActivityAttributes.ContentState) -> String {
  if state.lang == "en" {
    return state.count == 1 ? "1 connection" : "\(state.count) connections"
  }
  return "\(state.count) 个连接"
}

private func statusLabel(_ state: NetcattyActivityAttributes.ContentState, stale: Bool) -> String {
  let english = state.lang == "en"
  if stale { return english ? "Not updated" : "状态未更新" }
  if !state.activeConnected { return english ? "Reconnecting" : "正在重连" }
  return english ? "Connected" : "已连接"
}

struct NetcattyLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NetcattyActivityAttributes.self) { context in
      LockScreenView(state: context.state, stale: context.isStale)
        .activityBackgroundTint(Color.black.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(sessionURL(context.state))
    } dynamicIsland: { context in
      let state = context.state
      let stale = context.isStale
      let tint = statusColor(connected: state.activeConnected, stale: stale)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          DistroTile(distro: state.activeDistro, tint: tint, size: 46)
            .padding(.leading, 2)
            .padding(.top, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 3) {
            // A symbol + number never truncates the way "2 个连接" did in the
            // narrow trailing region.
            HStack(spacing: 3) {
              Image(systemName: "rectangle.stack.fill")
              Text("\(state.count)")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            Text(state.connectedSince, style: .timer)
              .font(.callout.monospacedDigit().weight(.medium))
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: 76, alignment: .trailing)
          }
          .padding(.top, 6)
          .padding(.trailing, 2)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Circle().fill(tint).frame(width: 7, height: 7)
              Text(state.activeName)
                .font(.headline)
                .lineLimit(1)
            }
            Text(state.activeAddress.isEmpty ? statusLabel(state, stale: stale) : state.activeAddress)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 10) {
            CommandLineView(state: state, tint: tint)
            if state.sessions.count > 1 {
              SessionStrip(sessions: state.sessions, stale: stale, size: 30)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
          .padding(.bottom, 4)
        }
      } compactLeading: {
        // The dot sits inside the frame: the compact region clips anything
        // drawn outside it, which cut the dot in half.
        ZStack(alignment: .bottomTrailing) {
          DistroGlyph(distro: state.activeDistro)
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .frame(width: 24, height: 24, alignment: .topLeading)
          Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
        }
        .frame(width: 24, height: 24)
        .padding(.leading, 2)
      } compactTrailing: {
        HStack(spacing: 3) {
          Text(state.activeName)
            .lineLimit(1)
            .truncationMode(.tail)
          if state.count > 1 {
            Text("\(state.count)")
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .frame(maxWidth: 78)
      } minimal: {
        DistroGlyph(distro: state.activeDistro)
          .foregroundStyle(tint)
          .frame(width: 18, height: 18)
      }
      .keylineTint(tint)
      .widgetURL(sessionURL(state))
    }
  }
}

/// Distro logo rendered as a template so it takes the status colour; falls
/// back to a generic server symbol for unknown systems.
private struct DistroGlyph: View {
  let distro: String

  var body: some View {
    let name = "distro-\(distro)"
    if UIImage(named: name) != nil {
      Image(name)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "server.rack")
        .resizable()
        .scaledToFit()
    }
  }
}

private struct DistroTile: View {
  let distro: String
  let tint: Color
  let size: CGFloat

  var body: some View {
    DistroGlyph(distro: distro)
      .foregroundStyle(tint)
      .padding(size * 0.22)
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
          .fill(tileBackground)
      )
  }
}

private struct CommandLineView: View {
  let state: NetcattyActivityAttributes.ContentState
  let tint: Color

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("❯")
        .font(.system(.callout, design: .monospaced).weight(.bold))
        .foregroundStyle(tint)
      if state.command.isEmpty {
        Text(state.lang == "en" ? "Waiting for a command…" : "等待输入命令…")
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(.secondary)
      } else {
        Text(state.command)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(2)
          .truncationMode(.tail)
      }
    }
  }
}

private struct SessionStrip: View {
  let sessions: [NetcattySessionSummary]
  let stale: Bool
  let size: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
        DistroTile(
          distro: session.distro,
          tint: statusColor(connected: session.connected, stale: stale),
          size: size
        )
      }
    }
  }
}

private struct LockScreenView: View {
  let state: NetcattyActivityAttributes.ContentState
  let stale: Bool

  var body: some View {
    let tint = statusColor(connected: state.activeConnected, stale: stale)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        DistroTile(distro: state.activeDistro, tint: tint, size: 44)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(state.activeName)
              .font(.headline)
              .lineLimit(1)
          }
          Text(state.activeAddress.isEmpty ? statusLabel(state, stale: stale) : state.activeAddress)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text(countLabel(state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(state.connectedSince, style: .timer)
            .font(.callout.monospacedDigit().weight(.medium))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 80, alignment: .trailing)
        }
      }
      CommandLineView(state: state, tint: tint)
      if state.sessions.count > 1 {
        SessionStrip(sessions: state.sessions, stale: stale, size: 28)
      }
    }
    .padding(16)
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
  }
}
