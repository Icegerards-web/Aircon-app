import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget? = nil
    @State private var showDiscovery = false

    struct EditTarget: Identifiable {
        let id = UUID()
        let config: UnitConfig?     // nil = a new aircon
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your aircons") {
                    ForEach(store.units) { unit in
                        if unit.isDemo {
                            HStack { Text(unit.name); Spacer(); Text("demo").foregroundColor(Theme.ink2) }
                        } else {
                            Button { editing = EditTarget(config: unit.config) } label: {
                                UnitRow(unit: unit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { showDiscovery = true } label: {
                        Label("Find aircons automatically", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button { editing = EditTarget(config: nil) } label: {
                        Label("Add one by hand", systemImage: "plus")
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Tip: give each aircon a fixed address in your router, so it can always be found at the same place.")
                }
                Section("Try it out") {
                    Toggle(isOn: Binding(get: { store.demo }, set: { store.setDemo($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo units")
                            Text("Pretend aircons to explore the app without touching the real ones.")
                                .font(.footnote).foregroundColor(Theme.ink2)
                        }
                    }
                }
                Section("How it connects") {
                    Label {
                        Text("Your phone talks straight to each aircon's Wi-Fi adapter on your home network. No cloud account, no login, and it keeps working when the official app doesn't.")
                            .font(.subheadline)
                    } icon: { Image(systemName: "checkmark.shield").foregroundColor(Theme.okText) }
                }
                AwayFromHomeSection()
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .sheet(item: $editing) { target in
                EditUnitView(existing: target.config).environmentObject(store)
            }
            .sheet(isPresented: $showDiscovery) { DiscoveryView().environmentObject(store) }
        }
    }
}

private struct UnitRow: View {
    @ObservedObject var unit: AirconUnit
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wind")
                .foregroundColor(Theme.blue)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xE7F0FD)))
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.ink)
                Text(unit.host).font(.system(size: 13)).foregroundColor(Theme.ink2)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(unit.online ? Theme.ok : Theme.bad).frame(width: 7, height: 7)
                Text(unit.online ? "Connected" : "Offline").font(.system(size: 13, weight: .medium))
                    .foregroundColor(unit.online ? Theme.okText : Theme.bad)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink3)
        }
    }
}

// MARK: - add / rename / change address / remove

struct EditUnitView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let existing: UnitConfig?

    @State private var name = ""
    @State private var host = ""
    @State private var away = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)? = nil
    @State private var errorText: String? = nil
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Living room", text: $name)
                }
                Section {
                    TextField("192.168.1.50", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: { Text("IP address") } footer: {
                    Text("The address of the aircon's Wi-Fi adapter, without http:// and without a port.")
                }
                Section {
                    TextField("my-address.example.com:51444", text: $away)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: { Text("Away address (optional)") } footer: {
                    Text("Only if you forward a port on your router to this aircon. This is the less safe way to reach it from outside: the adapter has no login, so anyone who finds the open port could control it. Prefer the home connection in Settings. Away, the app only uses encrypted HTTPS here.")
                }
                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if testing { Text("Trying… (can take up to 20 s)").font(.footnote).foregroundColor(Theme.ink2) }
                    if let r = testResult {
                        Label(r.ok ? "Found it ✓" : "Can't reach it: " + r.text,
                              systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(r.ok ? Theme.okText : Theme.bad)
                            .font(.subheadline)
                    }
                }
                if let e = errorText {
                    Section { Text(e).foregroundColor(Theme.bad) }
                }
                if existing != nil {
                    Section {
                        Button("Remove this aircon", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add an aircon" : "Edit aircon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .confirmationDialog("Remove \(name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
            } message: {
                Text("This only removes it from this app. The aircon itself isn't changed.")
            }
            .onAppear {
                if let e = existing { name = e.name; host = e.host; away = e.awayAddress ?? "" }
            }
        }
    }

    private func runTest() async {
        testing = true
        testResult = nil
        let r = await store.test(host: host)
        testResult = (r.ok, r.message)
        testing = false
    }

    private func save() {
        var list = store.configs
        let clean = UnitConfig(id: existing?.id ?? UUID(),
                               name: name.trimmingCharacters(in: .whitespaces),
                               host: host.trimmingCharacters(in: .whitespaces),
                               awayAddress: away.trimmingCharacters(in: .whitespaces).isEmpty ? nil : away.trimmingCharacters(in: .whitespaces))
        if let e = existing, let i = list.firstIndex(where: { $0.id == e.id }) { list[i] = clean } else { list.append(clean) }
        if let problem = store.validate(list) { errorText = problem; return }
        store.save(list)
        dismiss()
    }

    private func remove() {
        guard let e = existing else { return }
        store.save(store.configs.filter { $0.id != e.id })
        dismiss()
    }
}

// MARK: - find the adapters on the network

struct DiscoveryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = true
    @State private var result: ScanResult? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scanning {
                    Spacer()
                    ProgressView().scaleEffect(1.4)
                    Text("Searching your network…").font(.system(size: 20, weight: .semibold))
                    Text("Looking for your aircons. This takes a few seconds. If iOS asks to allow \"local network\" access, please press Allow.")
                        .font(.system(size: 14)).foregroundColor(Theme.ink2).multilineTextAlignment(.center)
                    Spacer()
                } else if let r = result {
                    if r.found.isEmpty {
                        Spacer()
                        Image(systemName: "questionmark.circle").font(.system(size: 40)).foregroundColor(Theme.ink3)
                        Text("Couldn't find any aircons").font(.system(size: 20, weight: .semibold))
                        Text(r.networks.isEmpty
                             ? "This phone doesn't seem to be on a home Wi-Fi network."
                             : "Searched \(r.scanned) addresses on \(r.networks.joined(separator: ", ")). Make sure your phone is on the same Wi-Fi as the aircons, that the adapters are powered on, and that \"Local Network\" is allowed for this app in iOS Settings.")
                            .font(.system(size: 14)).foregroundColor(Theme.ink2).multilineTextAlignment(.center)
                        Button("Search again") { Task { await run() } }.buttonStyle(PrimaryButtonStyle())
                        Spacer()
                    } else {
                        Text("Found \(r.found.count) aircon\(r.found.count > 1 ? "s" : "")")
                            .font(.system(size: 20, weight: .semibold))
                        ForEach(r.found) { f in
                            HStack {
                                Image(systemName: "wind").foregroundColor(Theme.blue)
                                Text(f.host).font(.system(size: 16, weight: .semibold))
                                Spacer()
                                if store.configs.contains(where: { $0.host == f.host }) {
                                    Text("already added").font(.system(size: 13)).foregroundColor(Theme.ink2)
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                        }
                        Text("They'll be named Aircon 1, Aircon 2… You can rename them in Settings.")
                            .font(.system(size: 13)).foregroundColor(Theme.ink2)
                        Spacer()
                        Button("Add to my aircons") { addFound(r.found) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.homeBG.ignoresSafeArea())
            .navigationTitle("Find aircons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await run() }
        }
    }

    private func run() async {
        scanning = true
        result = await Discovery.scan(operatorId: store.operatorId, deviceId: store.deviceId)
        scanning = false
    }

    private func addFound(_ found: [FoundAdapter]) {
        var list = store.configs
        for f in found where !list.contains(where: { $0.host == f.host }) {
            list.append(UnitConfig(name: "Aircon \(list.count + 1)", host: f.host))
        }
        store.save(list)
        dismiss()
    }
}

// MARK: - technical details (what the adapter said, model group, features)

struct DetailsView: View {
    @ObservedObject var unit: AirconUnit
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied ✓" : "Copy") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
            }
            .task { text = await unit.diagnosticsText() }
        }
    }
}

// MARK: - away from home (WireGuard inside the app)

private struct AwayFromHomeSection: View {
    @EnvironmentObject var store: Store
    @State private var configured = TunnelManager.shared.isConfigured
    @State private var importing = false
    @State private var pasting = false
    @State private var message: String? = nil
    @State private var messageIsError = false

    var body: some View {
        Section {
            Label {
                Text(configured
                     ? "Home connection is set up. Away from home, the app connects to your home WireGuard server by itself while it is open. No VPN icon, and the rest of your phone's internet is untouched."
                     : "To control your aircons away from home, give the app the connection file of your home WireGuard server. The app only uses it while it is open, and only for the aircons.")
                    .font(.subheadline)
            } icon: { Image(systemName: configured ? "checkmark.shield" : "house.and.flag").foregroundColor(configured ? Theme.okText : Theme.blue) }
            Button { importing = true } label: { Label("Import WireGuard file…", systemImage: "square.and.arrow.down") }
            Button { pasting = true } label: { Label("Paste WireGuard config…", systemImage: "doc.on.clipboard") }
            if configured {
                Button(role: .destructive) {
                    TunnelManager.shared.remove()
                    configured = false
                    message = "Home connection removed."
                    messageIsError = false
                } label: { Label("Remove home connection", systemImage: "trash") }
            }
            if let m = message {
                Text(m).font(.footnote).foregroundColor(messageIsError ? Theme.bad : Theme.okText)
            }
        } header: { Text("Away from home") } footer: {
            Text("You need a WireGuard server at home (see AWAY-FROM-HOME.md in the project for a step-by-step guide). Your phone must be on a different network than the aircons for the tunnel to be used.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) { apply(text) }
                else { show("Couldn't read that file.", error: true) }
            case .failure(let e):
                show(e.localizedDescription, error: true)
            }
        }
        .sheet(isPresented: $pasting) { PasteConfigView { apply($0) } }
    }

    private func apply(_ text: String) {
        if let problem = TunnelManager.shared.save(text) { show(problem, error: true) }
        else { configured = true; show("Saved. It will be used automatically when you're away from home.", error: false) }
    }

    private func show(_ text: String, error: Bool) { message = text; messageIsError = error }
}

private struct PasteConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the whole contents of the WireGuard file (it starts with [Interface]). It stays on this phone.")
                    .font(.footnote).foregroundColor(Theme.ink2)
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            .padding(16)
            .navigationTitle("WireGuard config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(text); dismiss() }.fontWeight(.semibold) }
            }
        }
    }
}
