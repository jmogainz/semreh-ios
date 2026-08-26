import SwiftUI

struct YouView: View {
    @Bindable var authManager: AuthManager
    let server: URL

    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileCard
                    connectionCard
                    settingsCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 104)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(SemrehBackdrop().ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            Text(displayInitials)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(
                    HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
                )
                .frame(width: 76, height: 76)
                .background(HeaderLogoColor.color(for: headerLogoColorHex), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                Text("Your Semreh profile")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection", systemImage: "checkmark.shield")
                .font(.headline)

            HStack(spacing: 12) {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected server")
                        .font(.subheadline.weight(.semibold))
                    Text(serverDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Personalize Semreh", systemImage: "slider.horizontal.3")
                .font(.headline)
                .padding(.bottom, 8)

            NavigationLink {
                SettingsView(authManager: authManager, server: server)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Settings")
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 4)

            Text("Appearance, notifications, chat behavior, servers, and identity live here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var displayName: String {
        let trimmed = identityDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Maurice" : trimmed
    }

    private var displayInitials: String {
        let trimmed = identityInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(2)).uppercased()
        }

        let parts = displayName.split(separator: " ")
        if parts.count > 1 {
            return String(parts.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(displayName.prefix(2)).uppercased()
    }

    private var serverDisplayName: String {
        if let host = server.host, !host.isEmpty {
            return host
        }

        return server.absoluteString
    }
}

#Preview {
    YouView(
        authManager: AuthManager(),
        server: URL(staticString: "https://hermes.example.test")
    )
}
