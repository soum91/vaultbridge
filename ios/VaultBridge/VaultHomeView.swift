import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

    let onSave: (VaultCredential) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Website URL", text: $origin)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Username", text: $username).textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                TextField("Notes", text: $note, axis: .vertical)
            }
            .navigationTitle("New credential")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(VaultCredential(id: UUID(), source: .local, sourceAccount: "",
                                               origin: origin, title: title.isEmpty ? origin : title,
                                               username: username, password: password, note: note,
                                               updatedAt: Date()))
                    }.disabled(origin.isEmpty || password.isEmpty)
                }
            }
        }
    }
}

struct VaultCredentialView: View {
    let entry: VaultCredential
    let onDelete: () -> Void
    @State private var revealed = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private func unlock(_ action: @escaping () -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Access password for \(entry.title)") { success, _ in
            DispatchQueue.main.async { if success { action() } }
        }
    }

    var body: some View {
        Form {
            LabeledContent("Website", value: entry.origin)
            LabeledContent("Username", value: entry.username)
            LabeledContent("Source", value: entry.source.rawValue)
            LabeledContent("Password") { Text(revealed ? entry.password : "••••••••") }
            Button(revealed ? "Hide password" : "Reveal with Face ID / passcode") {
                if revealed { revealed = false }
                else { unlock { revealed = true } }
            }
            Button(copied ? "Copied for 45 seconds" : "Copy password securely") {
                unlock {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": entry.password]],
                                                  options: [.localOnly: true,
                                                            .expirationDate: Date().addingTimeInterval(45)])
                    copied = true
                }
            }
            if !entry.note.isEmpty { LabeledContent("Notes", value: entry.note) }
            Button("Delete local entry", role: .destructive) { onDelete(); dismiss() }
        }
        .navigationTitle(entry.title)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }
}

// The main dashboard deliberately avoids a nested Form/List: those controls were
// being rendered at legacy, scaled dimensions on some sideloaded iPhone builds.
struct VaultHomeView: View {
    @StateObject private var vault = VaultModel()
    @StateObject private var firefox = FirefoxSyncService()
    @Environment(\.scenePhase) private var currentScenePhase
    @State private var search = ""
    @State private var chosenProvider: CredentialSource?
    @State private var selectedImportSource: CredentialSource = .apple
    @State private var accountLabel = ""
    @State private var showingImportSetup = false
    @State private var showingFiles = false
    @State private var showingAdd = false
    @State private var firefoxLogin: FirefoxLoginRequest?
    @State private var alertText: String?

    private var filtered: [VaultCredential] {
        vault.entries.filter {
            search.isEmpty || [$0.title, $0.origin, $0.username, $0.source.rawValue]
                .contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 13) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VaultBridge")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                            Text("Your passwords, one place")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        heading("Accounts", "Manage your password sources")
                        VStack(spacing: 0) {
                            sourceRow(.firefox, symbol: "globe", color: .orange,
                                      status: firefox.isRefreshing
                                        ? "Syncing passwords…"
                                        : firefox.accountEmail ?? "Sign in with Mozilla account")
                            Divider().padding(.leading, 58)
                            sourceRow(.apple, symbol: "apple.logo", color: .primary,
                                      status: "iCloud vault access restricted")
                            Divider().padding(.leading, 58)
                            sourceRow(.google, symbol: "g.circle.fill", color: .blue,
                                      status: "Google vault access restricted")
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 19))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            heading("Passwords", "\(vault.entries.count) stored on this iPhone")
                            Spacer()
                            Button { showingAdd = true } label: {
                                Image(systemName: "plus")
                                    .font(.body.bold())
                                    .frame(width: 40, height: 40)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                            }
                            .accessibilityLabel("Add a password")
                        }
                        VStack(spacing: 0) {
                            if vault.entries.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "key.horizontal")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("No passwords yet").font(.headline)
                                    Text("Connected or imported passwords will show up here.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 25)
                            } else {
                                HStack {
                                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                    TextField("Search passwords", text: $search)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                .padding(16)
                                Divider()
                                if filtered.isEmpty {
                                    Text("No matching passwords")
                                        .foregroundStyle(.secondary)
                                        .padding(18)
                                }
                                ForEach(filtered) { entry in
                                    NavigationLink {
                                        VaultCredentialView(entry: entry) { vault.remove(entry) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "key.fill")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 24)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(entry.title).font(.body.weight(.medium))
                                                Text(entry.username)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .foregroundStyle(.primary)
                                        .padding(16)
                                    }
                                    if entry.id != filtered.last?.id {
                                        Divider().padding(.leading, 52)
                                    }
                                }
                            }
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 19))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        heading("Tools", "Existing exports and backups")
                        Button { showingImportSetup = true } label: {
                            Label("Import a password file", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(17)
                        }
                        .buttonStyle(.plain)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16))
                    }

                    Label("Development preview. Firefox Sync is read-only and requires account sign-in. Windows transfer is not active. Keep your original password manager enabled.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { refreshFirefoxIfConnected() }
            .onChange(of: currentScenePhase) { _, phase in
                if phase == .active { refreshFirefoxIfConnected() }
            }
            .sheet(item: $chosenProvider) { source in
                providerDetails(source)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingImportSetup) { importOptions }
            .sheet(item: $firefoxLogin) { request in
                NavigationStack {
                    FirefoxAccountWebView(url: request.url) { envelope, reply in
                        handleFirefoxMessage(envelope, reply: reply)
                    }
                    .navigationTitle("Mozilla Account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                firefox.cancelSignIn()
                                firefoxLogin = nil
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddCredentialView {
                    vault.merge([$0])
                    showingAdd = false
                }
            }
            .fileImporter(isPresented: $showingFiles,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                switch result {
                case .failure(let error):
                    alertText = error.localizedDescription
                case .success(let url):
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let rows = try CredentialCSVImporter.parse(
                            Data(contentsOf: url), source: selectedImportSource, account: accountLabel)
                        let count = vault.merge(rows)
                        alertText = "Imported \(count) passwords. Delete the plaintext file after checking the import."
                    } catch {
                        alertText = error.localizedDescription
                    }
                }
            }
            .alert("VaultBridge", isPresented: Binding(
                get: { alertText != nil || vault.lastError != nil },
                set: { if !$0 { alertText = nil; vault.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { alertText = nil; vault.lastError = nil }
            } message: {
                Text(alertText ?? vault.lastError ?? "")
            }
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshFirefoxIfConnected() {
        guard firefox.isSignedIn, !firefox.isRefreshing else { return }
        Task {
            // Network outages should not erase a valid previously synced vault.
            _ = try? await firefox.refresh(into: vault)
        }
    }

    private func startFirefoxLogin() {
        Task {
            do {
                let url = try await firefox.beginSignIn()
                chosenProvider = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    firefoxLogin = FirefoxLoginRequest(url: url)
                }
            } catch {
                showFirefoxResult(error.localizedDescription)
            }
        }
    }

    private func syncFirefoxNow() {
        Task {
            do {
                let count = try await firefox.refresh(into: vault)
                showFirefoxResult("Downloaded \(count) Firefox passwords from your Mozilla account.")
            } catch {
                showFirefoxResult(error.localizedDescription)
            }
        }
    }

    private func showFirefoxResult(_ text: String) {
        chosenProvider = nil
        firefoxLogin = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            alertText = text
        }
    }

    private func handleFirefoxMessage(
        _ envelope: [String: Any],
        reply: @escaping ([String: Any]) -> Void
    ) {
        guard let payload = envelope["message"] as? [String: Any],
              let command = payload["command"] as? String else { return }
        let id = payload["messageId"] ?? ""
        let data = payload["data"] as? [String: Any] ?? [:]
        func respond(_ value: [String: Any]) {
            reply([
                "id": FxAConfig.webChannelID,
                "message": ["command": command, "messageId": id, "data": value]
            ])
        }
        switch command {
        case "fxaccounts:fxa_status":
            respond(firefox.webChannelStatus())
        case "fxaccounts:can_link_account":
            respond(["ok": firefox.canLink(
                email: data["email"] as? String, uid: data["uid"] as? String)])
        case "fxaccounts:oauth_login":
            guard let code = data["code"] as? String,
                  let state = data["state"] as? String else { return }
            Task {
                do {
                    try await firefox.finishSignIn(code: code, state: state)
                    let count = try await firefox.refresh(into: vault)
                    showFirefoxResult("Mozilla account connected. Downloaded \(count) Firefox passwords.")
                } catch {
                    showFirefoxResult(error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    private func sourceRow(_ source: CredentialSource, symbol: String, color: Color,
                           status: String) -> some View {
        Button { chosenProvider = source } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.rawValue).font(.body.weight(.semibold))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerDetails(_ source: CredentialSource) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: source == .firefox ? "arrow.triangle.2.circlepath" : "lock.shield")
                    .font(.largeTitle)
                    .foregroundStyle(.indigo)
                Text(source.rawValue).font(.title2.bold())
                Group {
                    if source == .firefox {
                        Text(firefox.isSignedIn
                             ? "Signed in as \(firefox.accountEmail ?? "Mozilla account"). Download Firefox passwords directly using your Mozilla Sync account."
                             : "Sign in to Mozilla once to download encrypted Firefox Sync passwords directly. You can use a different signing certificate from Reynard or Firefox. This is an experimental connection; try a test account first.")
                    } else if source == .apple {
                        Text("Apple does not expose an API that lets VaultBridge sign into iCloud Keychain and read your passwords. You can import an export from Apple Passwords.")
                    } else {
                        Text("Google sign-in does not give a third-party app access to stored Google Password Manager passwords. You can import a Chrome or Google Password Manager export.")
                    }
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                if source == .firefox {
                    if firefox.isSignedIn {
                        Button("Sync Firefox passwords now") { syncFirefoxNow() }
                            .buttonStyle(.borderedProminent)
                            .disabled(firefox.isRefreshing)
                        Button("Sign out of Mozilla") {
                            Task {
                                await firefox.signOut()
                                chosenProvider = nil
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Sign in with Mozilla") { startFirefoxLogin() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Import existing passwords") {
                        selectedImportSource = source
                        chosenProvider = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showingImportSetup = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { chosenProvider = nil }
                }
            }
        }
    }

    private var importOptions: some View {
        NavigationStack {
            Form {
                Section("Import") {
                    Picker("Password manager", selection: $selectedImportSource) {
                        Text("Apple Passwords").tag(CredentialSource.apple)
                        Text("Google / Chrome").tag(CredentialSource.google)
                        Text("Firefox").tag(CredentialSource.firefox)
                    }
                    TextField("Account label (optional)", text: $accountLabel)
                        .textInputAutocapitalization(.never)
                    Button("Choose CSV in Files") {
                        showingImportSetup = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showingFiles = true
                        }
                    }
                }
                Section {
                    Text("A CSV is an unencrypted, one-time copy. Importing does not enable live Sync. Delete the source file afterward.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import passwords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingImportSetup = false }
                }
            }
        }
    }
}
