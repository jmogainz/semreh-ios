import SwiftUI

/// A Messages-inspired session row used only by the new mobile shell. The existing
/// SessionRowView remains available for the desktop-like/sidebar presentation.
struct MessagesSessionRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let session: SessionSummary
    let isViewingCachedData: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            activeIndicator

            SessionAvatarView(session: session)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(SessionRowView.displayTitle(for: session))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Text(relativeDate)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(previewText)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 86, alignment: .center)
        .background {
            Rectangle()
                .fill(Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                        .padding(.leading, 83)
                }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var activeIndicator: some View {
        Circle()
            .fill(isActive ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
            .frame(width: 8)
            .accessibilityHidden(true)
    }

    private var isActive: Bool {
        SessionRowView.isActiveStreaming(session)
            || session.hasPendingUserMessage == true
    }

    private var previewText: String {
        if session.hasPendingUserMessage == true {
            return "Waiting for your message…"
        }

        var parts: [String] = []
        if let count = session.messageCount, count >= 0 {
            parts.append("\(count) messages")
        }

        if let workspace = normalizedWorkspace {
            parts.append(workspace)
        }

        if let profile = normalizedProfile {
            parts.append(profile)
        }

        if parts.isEmpty {
            return isViewingCachedData ? "Cached Hermes session" : "Hermes session"
        }

        return parts.joined(separator: " · ")
    }

    private var relativeDate: String {
        let timestamp = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let timestamp, timestamp > 0 else { return "—" }

        return MessagesSessionDateFormatter.shared.localizedString(
            for: Date(timeIntervalSince1970: timestamp),
            relativeTo: Date()
        )
    }

    private var normalizedWorkspace: String? {
        guard let workspace = session.workspace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else {
            return nil
        }

        let basename = (workspace as NSString).lastPathComponent
        return basename.isEmpty ? workspace : basename
    }

    private var normalizedProfile: String? {
        guard let profile = session.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty
        else {
            return nil
        }

        return profile
    }

    private var accessibilitySummary: String {
        var values = [SessionRowView.displayTitle(for: session), previewText, relativeDate]
        if isActive {
            values.append("Active")
        }
        return values.joined(separator: ", ")
    }
}

private struct SessionAvatarView: View {
    let session: SessionSummary

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            SemrehVisualTheme.energy().opacity(0.85),
                            Color.accentColor.opacity(0.42)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if session.isCliSession == true {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 58, height: 58)
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let title = SessionRowView.displayTitle(for: session)
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count > 1 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(title.prefix(2)).uppercased()
    }
}

private enum MessagesSessionDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

#Preview {
    MessagesSessionRowView(
        session: SessionSummary(
            sessionId: "preview",
            title: "Design the Semreh shell",
            workspace: "/Users/maurice/workspace/goku-ios",
            messageCount: 18,
            lastMessageAt: Date().addingTimeInterval(-86_400).timeIntervalSince1970,
            profile: "Chabby"
        ),
        isViewingCachedData: false
    )
    .padding(.horizontal)
    .background(Color.black)
}
