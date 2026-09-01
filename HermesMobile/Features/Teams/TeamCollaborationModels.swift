import Combine
import Foundation

/// The destinations supported by the local Teams prototype. The enum is deliberately
/// backend-neutral so the coordinator can later map these routes to authenticated
/// Hermes/A2A tasks without changing the mobile UI contract.
enum TeamRecipient: String, CaseIterable, Hashable, Identifiable, Sendable {
    case humans
    case chabby
    case goku
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .humans:
            "Humans only"
        case .chabby:
            "Chabby"
        case .goku:
            "Goku"
        case .both:
            "Both agents"
        }
    }

    var systemImage: String {
        switch self {
        case .humans:
            "person.2"
        case .chabby, .goku:
            "sparkles"
        case .both:
            "person.2.wave.2"
        }
    }

    var subtitle: String {
        switch self {
        case .humans:
            "Keep this conversation human-only"
        case .chabby:
            "Dispatch one parent task to Chabby"
        case .goku:
            "Dispatch one parent task to Goku"
        case .both:
            "Run both agents, then reconcile one answer"
        }
    }

    var targets: [TeamAgent] {
        switch self {
        case .humans:
            []
        case .chabby:
            [.chabby]
        case .goku:
            [.goku]
        case .both:
            [.chabby, .goku]
        }
    }
}

enum TeamAgent: String, CaseIterable, Hashable, Identifiable, Sendable {
    case chabby
    case goku

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chabby:
            "Chabby"
        case .goku:
            "Goku"
        }
    }
}

enum TeamRoutingPhase: String, CaseIterable, Hashable, Sendable {
    case dispatched
    case independentWork
    case reconciling
    case completed
}

struct TeamRoutingPlan: Equatable, Sendable {
    let recipient: TeamRecipient
    let targets: [TeamAgent]
    let phases: [TeamRoutingPhase]

    init(recipient: TeamRecipient) {
        self.recipient = recipient
        self.targets = recipient.targets
        self.phases = recipient.targets.isEmpty
            ? [.dispatched, .completed]
            : recipient == .both
                ? [.dispatched, .independentWork, .reconciling, .completed]
                : [.dispatched, .independentWork, .completed]
    }
}

enum TeamParticipantKind: Hashable, Sendable {
    case human
    case agent
}

enum TeamPresence: Hashable, Sendable {
    case online
    case mockReady
    case offline

    var title: String {
        switch self {
        case .online:
            "Online"
        case .mockReady:
            "Mock-ready"
        case .offline:
            "Offline"
        }
    }
}

struct TeamParticipant: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let kind: TeamParticipantKind
    let presence: TeamPresence
    let systemImage: String

    static let demo: [TeamParticipant] = [
        TeamParticipant(
            id: "maurice",
            name: "Maurice",
            detail: "Owner",
            kind: .human,
            presence: .online,
            systemImage: "person.crop.circle"
        ),
        TeamParticipant(
            id: "jacob",
            name: "Jacob",
            detail: "Teammate",
            kind: .human,
            presence: .online,
            systemImage: "person.crop.circle"
        ),
        TeamParticipant(
            id: "chabby",
            name: "Chabby",
            detail: "Hermes agent",
            kind: .agent,
            presence: .mockReady,
            systemImage: "sparkles"
        ),
        TeamParticipant(
            id: "goku",
            name: "Goku",
            detail: "Hermes agent",
            kind: .agent,
            presence: .mockReady,
            systemImage: "sparkles"
        )
    ]
}

enum TeamMessageKind: Hashable, Sendable {
    case human
    case agent
    case system
}

struct TeamRoomMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let sender: String
    let body: String
    let kind: TeamMessageKind
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sender: String,
        body: String,
        kind: TeamMessageKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
    }
}

struct TeamActivityItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let systemImage: String
    let isTerminal: Bool

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        systemImage: String,
        isTerminal: Bool
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isTerminal = isTerminal
    }
}

/// A server-free coordinator used for the first UI slice. It exercises the same
/// parent-task phases the real coordinator will expose, while making it impossible
/// for local development to accidentally send work to either Hermes agent.
@MainActor
final class LocalTeamsCoordinator: ObservableObject {
    @Published var recipient: TeamRecipient = .both
    @Published var draft = ""
    @Published private(set) var messages: [TeamRoomMessage] = [
        TeamRoomMessage(
            sender: "Teams",
            body: "Local prototype only. Messages stay on this device until a coordinator is connected.",
            kind: .system
        )
    ]
    @Published private(set) var activity: [TeamActivityItem] = []
    @Published private(set) var isDispatching = false

    private var activeRunID: UUID?
    private var pendingAgents = Set<TeamAgent>()
    private var scheduledTasks: [Task<Void, Never>] = []

    deinit {
        scheduledTasks.forEach { $0.cancel() }
    }

    func send(as sender: String = "Maurice") {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isDispatching else { return }

        let plan = TeamRoutingPlan(recipient: recipient)
        let runID = UUID()
        activeRunID = runID
        draft = ""
        messages.append(TeamRoomMessage(sender: sender, body: body, kind: .human))
        activity.insert(
            TeamActivityItem(
                title: "Dispatched",
                detail: plan.recipient.title,
                systemImage: "arrow.up.right.circle",
                isTerminal: plan.targets.isEmpty
            ),
            at: 0
        )

        guard !plan.targets.isEmpty else {
            activity.insert(
                TeamActivityItem(
                    title: "Human-only message",
                    detail: "No agent task was created",
                    systemImage: "person.2",
                    isTerminal: true
                ),
                at: 0
            )
            activeRunID = nil
            return
        }

        isDispatching = true
        pendingAgents = Set(plan.targets)
        for (index, agent) in plan.targets.enumerated() {
            activity.insert(
                TeamActivityItem(
                    title: "Working · \(agent.displayName)",
                    detail: "Local mock agent",
                    systemImage: "sparkles",
                    isTerminal: false
                ),
                at: 0
            )

            let task = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(350 + (index * 150)) * 1_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.completeAgent(agent, runID: runID)
            }
            scheduledTasks.append(task)
        }
    }

    private func completeAgent(_ agent: TeamAgent, runID: UUID) {
        guard activeRunID == runID else { return }

        messages.append(
            TeamRoomMessage(
                sender: agent.displayName,
                body: "Local mock response from \(agent.displayName). Replace this adapter with the authenticated Hermes task stream.",
                kind: .agent
            )
        )
        pendingAgents.remove(agent)
        guard pendingAgents.isEmpty else { return }

        if recipient == .both {
            activity.insert(
                TeamActivityItem(
                    title: "Reconciling",
                    detail: "Combining both mock agent results",
                    systemImage: "arrow.triangle.merge",
                    isTerminal: false
                ),
                at: 0
            )
        }

        let delay: UInt64 = recipient == .both ? 250_000_000 : 50_000_000
        let completionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.completeRun(runID: runID)
        }
        scheduledTasks.append(completionTask)
    }

    private func completeRun(runID: UUID) {
        guard activeRunID == runID else { return }

        if recipient == .both {
            messages.append(
                TeamRoomMessage(
                    sender: "Team coordinator",
                    body: "Local mock reconciliation complete. The real coordinator will publish one joint answer here.",
                    kind: .system
                )
            )
        }
        activity.insert(
            TeamActivityItem(
                title: "Completed",
                detail: "Local mock run finished",
                systemImage: "checkmark.circle.fill",
                isTerminal: true
            ),
            at: 0
        )
        pendingAgents.removeAll()
        activeRunID = nil
        isDispatching = false
    }
}
