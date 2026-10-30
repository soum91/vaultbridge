import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

struct VaultHomeView: View {
    @StateObject private var vault = VaultModel()
    @State private var query = ""
    @State private var source: CredentialSource = .google
    @State private var sourceAccount = ""
    @State private var importing = false
    @State private var adding = false
    @State private var message: String?

    private var results: [VaultCredential] {
        vault.entries.filter {
            query.isEmpty || [$0.title, $0.origin, $0.username, $0.source.rawValue]
                .contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Add credentials") {
                    Picker("Import from", selection: $source) {
                        Text("Apple Passwords").tag(CredentialSource.apple)
                        Text("Google / Chrome").tag(CredentialSource.google)
                        Text("Firefox CSV (temporary)").tag(CredentialSource.firefox)
                    }
                    TextField("Account label (optional)", text: $sourceAccount)
                        .textInputAutocapitalization(.never)
                    Button("Import CSV using Files") { importing = true }
                    Button("Add password manually") { adding = true }
                }
                Section("Saved credentials (\(results.count))") {
                    if results.isEmpty { Text("No credentials saved yet").foregroundStyle(.secondary) }
                    ForEach(results) { entry in
                        NavigationLink {
                            VaultCredentialView(entry: entry) { vault.remove(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.headline)
                                Text(entry.username).font(.subheadline)
                                Text(entry.source.rawValue + (entry.sourceAccount.isEmpty ? "" : " · " + entry.sourceAccount))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Connections") {
                    Label("Firefox live Sync: integration pending", systemImage: "arrow.triangle.2.circlepath")
                    Text("Apple and Google use manual CSV imports, not automatic account sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
            .navigationTitle("VaultBridge")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                switch result {
                case .failure(let error): message = error.localizedDescription
                case .success(let url):
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let rows = try CredentialCSVImporter.parse(Data(contentsOf: url), source: source, account: sourceAccount)
                        let saved = vault.merge(rows)
                        message = "Imported \(saved) credentials from \(source.rawValue). Delete the plaintext CSV after checking the import."
                    } catch { message = error.localizedDescription }
                }
            }
            .sheet(isPresented: $adding) { AddCredentialView { vault.merge([$0]); adding = false } }
            .alert("VaultBridge", isPresented: Binding(get: { message != nil || vault.lastError != nil },
                                                      set: { if !$0 { message = nil; vault.lastError = nil } })) {
                Button("OK", role: .cancel) { message = nil; vault.lastError = nil }
            } message: { Text(message ?? vault.lastError ?? "") }
        }
    }
}

struct AddCredentialView: View {
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
