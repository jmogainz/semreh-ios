import SwiftUI

struct TeamsView: View {
    @StateObject private var coordinator = LocalTeamsCoordinator()
    var usesShellChrome = false

    var body: some View {
        if usesShellChrome {
            teamContent
        } else {
            NavigationStack {
                teamContent
                    .navigationTitle("Teams")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Label("Local mock", systemImage: "wrench.and.screwdriver")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleOnly)
                        }
                    }
            }
        }
    }

    private var teamContent: some View {
        ZStack {
            SemrehBackdrop()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    teamHeader
                    participantGrid
                    dispatchCard
                    activityCard
                    transcriptCard
                    composerCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var teamHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SemrehVisualTheme.energyForeground())
                    .frame(width: 48, height: 48)
                    .background(SemrehVisualTheme.energy(), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Maurice + Jacob")
                        .font(.title3.weight(.bold))
                    Text("A shared room for people and Hermes agents")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TeamStatusPill(title: "4 participants", systemImage: "person.3")
                TeamStatusPill(title: "No network", systemImage: "iphone")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var participantGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Participants")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(TeamParticipant.demo) { participant in
                    TeamParticipantCard(participant: participant)
                }
            }
        }
    }

    private var dispatchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Message routing", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                if coordinator.isDispatching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Menu {
                ForEach(TeamRecipient.allCases) { option in
                    Button {
                        coordinator.recipient = option
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: coordinator.recipient.systemImage)
                        .frame(width: 22)
                        .foregroundStyle(SemrehVisualTheme.energy())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.recipient.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(coordinator.recipient.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isDispatching)

            Text("Both agents share one parent task. Their work is shown separately, then the coordinator publishes one joint result.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Activity", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("parent task")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if coordinator.activity.isEmpty {
                Text("Send a message to see dispatch, agent work, and reconciliation states.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.activity) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(item.isTerminal ? .green : SemrehVisualTheme.energy())
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shared transcript", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)

            ForEach(coordinator.messages) { message in
                TeamMessageRow(message: message)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Message your team…", text: $coordinator.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(13)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Team message")

            HStack {
                Text("Sending to \(coordinator.recipient.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    coordinator.send()
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(SemrehVisualTheme.energy())
                .disabled(coordinator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isDispatching)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct TeamStatusPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct TeamParticipantCard: View {
    let participant: TeamParticipant

    private var presenceColor: Color {
        switch participant.presence {
        case .online:
            .green
        case .mockReady:
            .orange
        case .offline:
            .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: participant.systemImage)
                .font(.title3)
                .foregroundStyle(participant.kind == .agent ? SemrehVisualTheme.energy() : .secondary)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.name)
                    .font(.subheadline.weight(.semibold))
                Text(participant.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(participant.presence.title, systemImage: "circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(presenceColor)
                    .labelStyle(.titleOnly)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(participant.name), \(participant.presence.title)")
    }
}

private struct TeamMessageRow: View {
    let message: TeamRoomMessage

    private var accent: Color {
        switch message.kind {
        case .human:
            SemrehVisualTheme.energy()
        case .agent:
            .blue
        case .system:
            .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind == .agent ? "sparkles" : "person.crop.circle")
                .foregroundStyle(accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(message.sender)
                        .font(.subheadline.weight(.semibold))
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(message.kind == .system ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))
    }
}

#Preview {
    TeamsView()
}
