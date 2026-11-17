import SwiftUI

/// Home: clock and date now; calendar and agent summaries land here in later phases.
struct HomeTabView: View {
    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .card()
            }

            VStack(spacing: 8) {
                MiniPlayerView()
                AgentsSummaryRow()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AgentsSummaryRow: View {
    @ObservedObject private var agents = AgentsModel.shared

    var body: some View {
        SummaryRow(icon: agents.waitingCount > 0 ? "exclamationmark.bubble.fill" : "sparkles",
                   title: "Agents", value: summary)
    }

    private var summary: String {
        let waiting = agents.waitingCount, working = agents.workingCount
        if waiting > 0, let first = agents.sessions.first(where: { $0.state == .waiting }) {
            return waiting == 1 ? "\(first.project) needs you" : "\(waiting) sessions need you"
        }
        if working > 0 { return working == 1 ? "1 session working" : "\(working) sessions working" }
        if let done = agents.sessions.first(where: { $0.state == .done }) { return "\(done.project): done" }
        return "No active sessions"
    }
}

private struct SummaryRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

struct PlaceholderTabView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}
