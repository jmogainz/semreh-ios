import SwiftUI

/// The three primary surfaces in the Semreh mobile shell.
enum AppShellSurface: String, CaseIterable, Hashable, Identifiable {
    case sessions
    case control
    case you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:
            "Sessions"
        case .control:
            "Control"
        case .you:
            "You"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions:
            "bubble.left.and.bubble.right.fill"
        case .control:
            "slider.horizontal.3"
        case .you:
            "person.crop.circle.fill"
        }
    }

    var showsPrimaryAction: Bool {
        switch self {
        case .sessions:
            true
        case .control, .you:
            false
        }
    }
}

@MainActor
struct AppShellView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var selectedSurface: AppShellSurface
    @Binding var pendingSharedImport: SharedImport?
    @Binding var pendingDeepLinkedSessionID: String?
    @Binding var pendingNewChatRequest: NewChatRequest?

    @State private var isSessionConversationPresented = false
    @State private var isControlDestinationPresented = false
    @State private var controlSurfaceVisitID = 0
    @State private var sessionSurfaceVisitID = 0

    var body: some View {
        surfaceContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if AppShellChromePolicy.showsTopBar(
                    surface: selectedSurface,
                    isSessionConversationPresented: isSessionConversationPresented,
                    isControlDestinationPresented: isControlDestinationPresented
                ) {
                    AppShellTopBar(
                        surface: selectedSurface,
                        onPrimaryAction: handlePrimaryAction
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if AppShellChromePolicy.showsBottomBar(
                    isConversationPresented: isSessionConversationPresented,
                    isControlDestinationPresented: isControlDestinationPresented
                ) {
                    AppShellBottomBar(selection: $selectedSurface)
                }
            }
            .onChange(of: selectedSurface) { oldValue, newValue in
                guard oldValue != newValue else { return }
                isControlDestinationPresented = false
                controlSurfaceVisitID += 1
                if newValue == .sessions {
                    sessionSurfaceVisitID += 1
                }
            }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch selectedSurface {
        case .sessions:
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest,
                usesShellChrome: true,
                shellSurfaceVisitID: sessionSurfaceVisitID,
                onConversationVisibilityChanged: { isPresented in
                    // This state owns the shell safe area. Keep it synchronous
                    // while New Chat transfers a focused composer.
                    isSessionConversationPresented = isPresented
                }
            )

        case .control:
            ControlView(
                authManager: authManager,
                server: server,
                isActive: selectedSurface == .control,
                onNestedDestinationVisibilityChanged: { isPresented in
                    isControlDestinationPresented = isPresented
                }
            )
            .id(controlSurfaceVisitID)

        case .you:
            YouView(authManager: authManager, server: server)
        }
    }

    private func handlePrimaryAction() {
        switch selectedSurface {
        case .sessions:
            pendingNewChatRequest = NewChatRequest()
        case .control, .you:
            break
        }
    }
}

enum AppShellChromePolicy {
    static func showsTopBar(
        surface: AppShellSurface,
        isSessionConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        surface != .you
            && !isSessionConversationPresented
            && !(surface == .control && isControlDestinationPresented)
    }

    static func showsBottomBar(
        isConversationPresented: Bool,
        isControlDestinationPresented: Bool
    ) -> Bool {
        !isConversationPresented && !isControlDestinationPresented
    }

    static func showsBottomBar(isConversationPresented: Bool) -> Bool {
        !isConversationPresented
    }
}

struct ControlNavigationState: Equatable {
    var destination: SessionListUtilityDestination?

    var isNestedDestinationPresented: Bool {
        destination != nil
    }

    mutating func select(_ destination: SessionListUtilityDestination) {
        self.destination = destination
    }

    mutating func resetForSurfaceDeactivation() {
        destination = nil
    }
}

private struct AppShellTopBar: View {
    let surface: AppShellSurface
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)

                if surface.showsPrimaryAction {
                    AppShellCircularButton(
                        systemImage: "plus",
                        accessibilityLabel: "New session",
                        action: onPrimaryAction
                    )
                }
            }
            .frame(minHeight: 48)

            Text(surface.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.96),
                    Color(.systemBackground).opacity(0.76),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct AppShellCircularButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(AppShellCircularButtonStyle(reduceMotion: reduceMotion))
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: reduceTransparency ? .regularMaterial : .ultraThinMaterial,
            in: Circle()
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppShellCircularButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.93 : 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

struct AppShellBottomBar: View {
    @Binding var selection: AppShellSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabSelectionNamespace

    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(AppShellSurface.allCases) { surface in
                    AppShellTabButton(
                        surface: surface,
                        isSelected: selection == surface,
                        namespace: tabSelectionNamespace,
                        reduceMotion: reduceMotion
                    ) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.04)) {
                            selection = surface
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: 390)
            .frame(height: 76)
            .adaptiveGlass(
                .regular,
                isInteractive: false,
                fallbackMaterial: .ultraThinMaterial,
                in: Capsule()
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(Color.clear)
    }
}

private struct AppShellTabButton: View {
    let surface: AppShellSurface
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: surface.systemImage)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .medium))
                    .scaleEffect(reduceMotion ? 1.0 : (isSelected ? 1.05 : 1.0))
                Text(surface.title)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.13))
                        .overlay {
                            Capsule()
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(
                            id: "selectedTabIndicator",
                            in: namespace
                        )
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(surface.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.04), value: isSelected)
    }
}

struct TeamsActionPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(SemrehVisualTheme.energy())
                    .frame(width: 84, height: 84)
                    .background(SemrehVisualTheme.energy().opacity(0.14), in: Circle())

                Text("Team setup is next")
                    .font(.title2.weight(.bold))

                Text("The Teams room is ready as a placeholder. The plus action will later add a teammate or Hermes agent.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(SemrehVisualTheme.energy())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(SemrehBackdrop().ignoresSafeArea())
            .navigationTitle("Teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AppShellBottomBar(selection: .constant(.sessions))
        .padding()
        .background(Color.black)
}
