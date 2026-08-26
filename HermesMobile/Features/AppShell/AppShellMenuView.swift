import SwiftUI
import SwiftData

@MainActor
struct AppShellMenuView: View {
    @Bindable var authManager: AuthManager
    let server: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: SessionListViewModel
    @State private var selectedDestination: SessionListUtilityDestination?
    @State private var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @State private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @State private var selectedProjectID: String?
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var isPresentingProjectCreation = false

    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    private var persistedProfilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var persistedProjectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey)
    private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey)
    private var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey)
    private var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey)
    private var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey)
    private var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey)
    private var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey)
    private var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey)
    private var showsProjectsSection = true
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool

    init(authManager: AuthManager, server: URL) {
        self.authManager = authManager
        self.server = server
        _viewModel = State(initialValue: SessionListViewModel(server: server))
        _showsCliSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsCliSessions(for: server),
            SessionRowDisplaySettings.showCliSessionsKey(for: server)
        )
        _showsClaudeCodeSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsClaudeCodeSessions(for: server),
            SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                menuHeader
                    .listRowBackground(Color.clear)

                SessionSidebarUtilityRows(
                    viewModel: viewModel,
                    topPadding: 8,
                    automatedVisibility: automatedVisibility,
                    sectionVisibility: sidebarSectionVisibility,
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: { destination in
                        selectedDestination = destination
                    },
                    switchActiveProfile: { profile in
                        Task {
                            let didSwitch = await viewModel.switchActiveProfile(profile)
                            if !didSwitch, let error = viewModel.lastError {
                                authManager.handleAPIError(error)
                            }
                        }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )

                Section("Session history") {
                    Button {
                        selectedDestination = .archived
                    } label: {
                        Label("Archived Sessions", systemImage: "archivebox")
                    }
                }

                Section("Connection") {
                    Button {
                        selectedDestination = .settings(nil)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Button {
                        selectedDestination = .settings(.servers)
                    } label: {
                        Label("Manage Servers", systemImage: "server.rack")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SemrehBackdrop().ignoresSafeArea())
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(item: $selectedDestination) { destination in
                utilityDestination(destination)
            }
            .task {
                profilesAreExpanded = persistedProfilesAreExpanded
                projectsAreExpanded = persistedProjectsAreExpanded
                await loadSidebarData()
            }
        }
        .sheet(isPresented: $isPresentingProjectCreation) {
            ProjectCreationSheet(
                existingProjectCount: viewModel.projects.count,
                isSaving: viewModel.isCreatingProject,
                onCancel: { isPresentingProjectCreation = false },
                onSave: { name, color in
                    Task {
                        _ = await viewModel.createEmptyProject(
                            named: name,
                            color: color,
                            modelContext: modelContext
                        )
                        isPresentingProjectCreation = false
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .adaptiveFormPresentation()
        }
        .sheet(item: $projectPendingRename) { project in
            ProjectRenameSheet(
                project: project,
                isSaving: viewModel.isRenamingProject,
                onCancel: { projectPendingRename = nil },
                onSave: { name, color in
                    Task {
                        _ = await viewModel.rename(project, named: name, color: color)
                        projectPendingRename = nil
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .adaptiveFormPresentation()
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task {
                    _ = await viewModel.delete(project, modelContext: modelContext)
                }
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("Sessions in this project will remain available without a project.")
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }

    private var menuHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemrehVisualTheme.energy())
                .frame(width: 42, height: 42)
                .background(SemrehVisualTheme.energy().opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Semreh menu")
                    .font(.headline)
                Text(serverDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var sidebarSectionVisibility: SidebarSectionVisibility {
        SidebarSectionVisibility(
            tasks: showsTasksSection,
            kanban: showsKanbanSection,
            skills: showsSkillsSection,
            memory: showsMemorySection,
            insights: showsInsightsSection,
            activeProfile: showsActiveProfileSection,
            projects: showsProjectsSection
        )
    }

    private var automatedVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    @ViewBuilder
    private func utilityDestination(_ destination: SessionListUtilityDestination) -> some View {
        switch destination {
        case .settings(let scrollTo):
            SettingsView(authManager: authManager, server: server, initialScrollTarget: scrollTo)
        case .tasks:
            TasksView(server: server, onAPIError: authManager.handleAPIError)
        case .kanban:
            KanbanView(server: server, onAPIError: authManager.handleAPIError)
        case .skills:
            SkillsView(server: server, onAPIError: authManager.handleAPIError)
        case .memory:
            MemoryView(server: server, onAPIError: authManager.handleAPIError)
        case .insights:
            InsightsView(server: server, onAPIError: authManager.handleAPIError)
        case .archived:
            ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
        case .scheduled:
            ScheduledSessionsView(
                viewModel: viewModel,
                showsCronSessions: showsCronSessions,
                showsMessageCount: true,
                showsWorkspace: true,
                selectedSessionID: nil,
                actions: menuRowActions
            )
        }
    }

    private var menuRowActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { _ = await viewModel.load(modelContext: modelContext) } },
            open: { _ in },
            togglePinned: { _ in },
            archive: { _ in },
            delete: { _ in },
            rename: { _ in },
            duplicate: { _ in },
            move: { _, _ in },
            createProject: { _ in },
            refreshProjects: { Task { await viewModel.loadProjects() } },
            export: { _, _ in }
        )
    }

    private func loadSidebarData() async {
        async let sessions: Bool = viewModel.load(modelContext: modelContext)
        async let profile: Void = viewModel.loadActiveProfile()
        async let projects: Void = viewModel.loadProjects()
        _ = await (sessions, profile, projects)
    }

    private var serverDisplayName: String {
        if let host = server.host, !host.isEmpty {
            return host
        }

        return server.absoluteString
    }
}

#Preview {
    AppShellMenuView(
        authManager: AuthManager(),
        server: URL(staticString: "https://hermes.example.test")
    )
}
