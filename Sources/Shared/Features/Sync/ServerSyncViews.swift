import SwiftUI

/// Settings → Sync Server: sign in / pair, then status, devices and account management.
struct ServerSyncView: View {
    private var sync: ServerSync { .shared }

    var body: some View {
        Group {
            if sync.isSignedIn {
                ServerSyncAccountView()
            } else {
                ServerSyncSignInView()
            }
        }
        .navigationTitle("Sync Server")
    }
}

// MARK: - Sign in

struct ServerSyncSignInView: View {
    enum Method: Hashable { case pair, password }

    private var sync: ServerSync { .shared }
    @State private var method: Method = { () -> Method in
        #if os(tvOS)
        return .pair
        #else
        return .password
        #endif
    }()
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let reason = sync.signOutReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.gold)
                }
            }
            Section {
                TextField("Address, e.g. http://192.168.1.10:8484", text: $url)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            } header: {
                Text("Server")
            } footer: {
                Text("Your self-hosted StreamForge sync server. Plain http:// works on your home network; use https:// when it's reachable from the internet.")
            }
            #if os(tvOS)
            Section {
                Picker("Sign in with", selection: $method) {
                    Text("Pairing code").tag(Method.pair)
                    Text("Username & password").tag(Method.password)
                }
            }
            #endif
            switch method {
            case .pair: pairSection
            case .password: passwordSection
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            url = sync.serverURL
            username = sync.username ?? ""
        }
        .onDisappear { sync.cancelPairing() }
        .onChange(of: method) { _, newValue in
            if newValue == .password { sync.cancelPairing() }
            error = nil
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        Section {
            TextField("Username", text: $username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                #endif
            SecureField("Password", text: $password)
                #if os(iOS)
                .textContentType(.password)
                #endif
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Label("Sign In", systemImage: "person.badge.key")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || url.trimmed.isEmpty || username.trimmed.isEmpty || password.isEmpty)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.live)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Everything on this device is uploaded when you sign in, so nothing is lost; for anything already on the server, the newest version wins. iCloud sync pauses while you use your own server.")
        }
    }

    @ViewBuilder
    private var pairSection: some View {
        if let pairing = sync.pairing {
            Section {
                VStack(spacing: 18) {
                    if pairing.expired {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.gold)
                        Text("That code expired").font(.title3.weight(.bold))
                    } else {
                        Text("Approve this code on your phone or in the server's web page")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(pairing.code)
                            .font(.system(size: Self.codeSize, weight: .heavy, design: .rounded).monospaced())
                            .foregroundStyle(Theme.accentGradient)
                            .kerning(6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(pairing.serverURL)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Waiting for approval…").foregroundStyle(Theme.secondaryText)
                        }
                        Text("On iPhone or iPad: StreamForge → Settings → Sync Server → Approve a TV Code. Or open \(pairing.serverURL) in a browser, sign in and approve it there.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 700)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            Section {
                if pairing.expired {
                    Button { Task { await startPairing() } } label: {
                        Label("Get a New Code", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .cancel) { sync.cancelPairing() } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
        } else {
            Section {
                Button {
                    Task { await startPairing() }
                } label: {
                    HStack {
                        Label("Show Pairing Code", systemImage: "number.square")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || url.trimmed.isEmpty)
            } footer: {
                Text("No typing a password on the TV: a code appears here, you approve it from StreamForge on your phone (or the server's web page), and this device signs in.")
            }
        }
        if let message = error ?? sync.pairingError {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.live)
            }
        }
    }

    private static var codeSize: CGFloat {
        #if os(tvOS)
        return 120
        #else
        return 60
        #endif
    }

    private func signIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await sync.signIn(serverURL: url, username: username, password: password)
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startPairing() async {
        busy = true
        error = nil
        defer { busy = false }
        await sync.startPairing(serverURL: url)
    }
}

// MARK: - Signed in

struct ServerSyncAccountView: View {
    private var sync: ServerSync { .shared }
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                LabeledContent("Server", value: sync.serverName.map { "\($0) · \(sync.serverHost)" } ?? sync.serverHost)
                LabeledContent("Account", value: (sync.username ?? "—") + (sync.userRole == "admin" ? " (admin)" : ""))
                LabeledContent("This device", value: sync.deviceName ?? SyncService.deviceName)
                LabeledContent("Permissions", value: ServerSyncFormat.scopes(sync.scopes))
            } header: {
                Text("Account")
            }
            Section {
                LabeledContent("Status") {
                    Text(sync.statusText)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(statusColor)
                }
                if let last = sync.lastSync {
                    LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if sync.isSyncingNow { ProgressView() }
                    }
                }
                .disabled(sync.isSyncingNow)
            } header: {
                Text("Sync")
            } footer: {
                Text("Watch progress, favorites, favorite channels, addons, Dispatcharr servers, profiles and settings stay the same on every device signed in to this account. iCloud sync is paused while you use your own server.")
            }
            if !sync.dismissedItems.isEmpty {
                Section {
                    ForEach(sync.dismissedItems) { item in
                        Button { sync.restoreDismissed(item) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                    Text(ServerSyncFormat.managedKind(item.collection))
                                        .font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                Text("Restore").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                } header: {
                    Text("Removed from this account")
                } footer: {
                    Text("Set up for you by your server admin. You chose to continue without them on all your devices; restore one to get it back everywhere.")
                }
            }
            Section {
                NavigationLink { ServerDevicesView() } label: {
                    Label("Devices", systemImage: "laptopcomputer.and.iphone")
                }
                #if os(iOS)
                NavigationLink { ApproveTVCodeView() } label: {
                    Label("Approve a TV Code", systemImage: "appletv")
                }
                #endif
                NavigationLink { ChangeServerPasswordView() } label: {
                    Label("Change Password", systemImage: "key")
                }
            }
            Section {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Theme.live)
                }
            } footer: {
                Text("Signing out keeps everything on this device.")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .confirmationDialog("Sign out of \(sync.serverHost)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your data stays on this device. iCloud sync resumes if it's turned on.")
        }
    }

    private var statusColor: Color {
        switch sync.phase {
        case .offline, .error: return Theme.gold
        case .signedOut, .idle, .syncing: return Theme.secondaryText
        }
    }
}

enum ServerSyncFormat {
    static func managedKind(_ collection: String) -> String {
        switch collection {
        case "servers": return "Dispatcharr server"
        case "addons": return "Addon"
        case "settings": return "Setting"
        default: return collection
        }
    }

    static func scopes(_ scopes: [String]) -> String {
        guard !scopes.isEmpty else { return "Full access" }
        let names: [String] = scopes.map {
            switch $0 {
            case "read": return "Read"
            case "write": return "Write"
            case "secrets": return "Secrets"
            default: return $0.capitalized
            }
        }
        return names.joined(separator: ", ")
    }
}

// MARK: - Devices

struct ServerDevicesView: View {
    private var sync: ServerSync { .shared }
    @State private var loading = false
    @State private var error: String?
    @State private var editing: SyncDevice?
    @State private var removing: SyncDevice?

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.live)
                }
            }
            Section {
                if sync.devices.isEmpty, loading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading devices…").foregroundStyle(Theme.secondaryText)
                    }
                }
                ForEach(sync.devices) { device in
                    Button { editing = device } label: { ServerDeviceRow(device: device) }
                        .contextMenu {
                            Button { editing = device } label: { Label("Rename & Permissions", systemImage: "pencil") }
                            Button(role: .destructive) { removing = device } label: { Label("Remove", systemImage: "trash") }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button(role: .destructive) { removing = device } label: { Label("Remove", systemImage: "trash") }
                            Button { editing = device } label: { Label("Edit", systemImage: "pencil") }
                        }
                        #endif
                }
            } footer: {
                Text("Removing a device signs it out immediately; it keeps its own data. Devices without “Secrets” never receive passwords, API keys or PINs.")
            }
            Section {
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Devices")
        .task { await load() }
        .sheet(item: $editing) { device in
            ServerDeviceEditSheet(device: device)
        }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { device in
            Button("Remove \(device.name)", role: .destructive) { Task { await remove(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text(device.current ? "This signs out this device." : "“\(device.name)” will be signed out right away.")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await sync.loadDevices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ device: SyncDevice) async {
        do {
            try await sync.revokeDevice(device)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ServerDeviceRow: View {
    var device: SyncDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.platformIcon)
                .font(.title2)
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name).font(.headline).lineLimit(1)
                    if device.current { Pill(text: "THIS DEVICE", color: Theme.accent) }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if device.scopes.isEmpty {
                        Pill(text: "NO ACCESS", color: Theme.live.opacity(0.6))
                    }
                    ForEach(device.scopes, id: \.self) { scope in
                        Pill(text: scope.uppercased(), color: scope == "secrets" ? Theme.gold.opacity(0.35) : Theme.surfaceHigh)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [device.platformLabel]
        if let seen = device.lastSeen {
            parts.append("seen \(seen.formatted(.relative(presentation: .named)))")
        }
        if let ip = device.lastIp, !ip.isEmpty { parts.append(ip) }
        return parts.joined(separator: " · ")
    }
}

struct ServerDeviceEditSheet: View {
    var device: SyncDevice
    private var sync: ServerSync { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var read = true
    @State private var write = true
    @State private var secrets = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Device name", text: $name)
                }
                Section {
                    Toggle("Read — download changes", isOn: $read)
                    Toggle("Write — upload changes", isOn: $write)
                    Toggle("Secrets — passwords, API keys, PINs", isOn: $secrets)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text(device.current ? "These are this device's own permissions." : "Changes apply the next time “\(device.name)” syncs.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.live)
                    }
                }
            }
            .navigationTitle(device.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || name.trimmed.isEmpty)
                }
            }
        }
        .onAppear {
            name = device.name
            read = device.scopes.contains("read")
            write = device.scopes.contains("write")
            secrets = device.scopes.contains("secrets")
        }
    }

    private var selectedScopes: [String] {
        var out: [String] = []
        if read { out.append("read") }
        if write { out.append("write") }
        if secrets { out.append("secrets") }
        return out
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            if name.trimmed != device.name { try await sync.renameDevice(device, to: name) }
            if Set(selectedScopes) != Set(device.scopes) { try await sync.setScopes(device, selectedScopes) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Approve a TV code

struct ApproveTVCodeView: View {
    private var sync: ServerSync { .shared }
    @State private var code = ""
    @State private var read = true
    @State private var write = true
    @State private var secrets = true
    @State private var busy = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        List {
            Section {
                TextField("Code, e.g. K7Q-4MX", text: $code)
                    .font(.title3.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    #endif
            } header: {
                Text("Code shown on the TV")
            } footer: {
                Text("On the Apple TV or Android TV: Settings → Sync Server → Pairing code. The TV signs in to your account (\(sync.username ?? "this account")) as soon as you approve.")
            }
            Section {
                Toggle("Read — download changes", isOn: $read)
                Toggle("Write — upload changes", isOn: $write)
                Toggle("Secrets — passwords, API keys, PINs", isOn: $secrets)
            } header: {
                Text("Allow the TV to")
            }
            Section {
                Button {
                    Task { await approve() }
                } label: {
                    HStack {
                        Label("Approve", systemImage: "checkmark.seal")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || code.trimmed.count < 4)
                if let result {
                    Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(ok ? .green : Theme.live)
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Approve a TV")
    }

    private func approve() async {
        busy = true
        defer { busy = false }
        var scopes: [String] = []
        if read { scopes.append("read") }
        if write { scopes.append("write") }
        if secrets { scopes.append("secrets") }
        do {
            let device = try await sync.approvePairing(code: code, scopes: scopes)
            ok = true
            result = "“\(device.name)” is now signed in."
            code = ""
        } catch {
            ok = false
            result = error.localizedDescription
        }
    }
}

// MARK: - Change password

struct ChangeServerPasswordView: View {
    private var sync: ServerSync { .shared }
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        List {
            Section {
                SecureField("Current password", text: $current)
                SecureField("New password", text: $new)
                SecureField("Repeat new password", text: $confirm)
            } footer: {
                Text("Changes the password of \(sync.username ?? "your account") on \(sync.serverHost). Devices that are already signed in stay signed in.")
            }
            Section {
                Button {
                    Task { await change() }
                } label: {
                    HStack {
                        Label("Change Password", systemImage: "key")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || current.isEmpty || new.isEmpty || new != confirm)
                if !new.isEmpty, !confirm.isEmpty, new != confirm {
                    Text("The new passwords don't match.").font(.footnote).foregroundStyle(Theme.gold)
                }
                if let result {
                    Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundStyle(ok ? .green : Theme.live)
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Change Password")
    }

    private func change() async {
        busy = true
        defer { busy = false }
        do {
            try await sync.changePassword(current: current, new: new)
            ok = true
            result = "Password changed."
            current = ""; new = ""; confirm = ""
        } catch {
            ok = false
            result = error.localizedDescription
        }
    }
}
