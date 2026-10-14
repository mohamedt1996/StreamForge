import SwiftUI

struct SettingsView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(AddonManager.self) private var addons
    @Environment(TorrentEngine.self) private var torrents
    @Environment(TraktService.self) private var trakt
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section("Sources") {
                NavigationLink { DispatcharrSettingsView() } label: {
                    row("Dispatcharr", icon: "server.rack", value: store.activeServer?.name ?? "Not connected")
                }
                NavigationLink { AddonsSettingsView() } label: {
                    row("Stremio Addons", icon: "puzzlepiece.extension", value: "\(addons.enabled.count) enabled")
                }
                NavigationLink { TorrentSettingsView() } label: {
                    row("Torrent Streaming", icon: "arrow.down.circle", value: torrents.mode.label)
                }
            }
            Section("Metadata") {
                NavigationLink { MetadataSettingsView() } label: {
                    row("Metadata Sources", icon: "photo.on.rectangle.angled",
                        value: settings.values.metadataPriority.map(\.label).joined(separator: " → "))
                }
                NavigationLink { TraktSettingsView() } label: {
                    row("Trakt", icon: "checkmark.seal", value: trakt.username ?? (trakt.isSignedIn ? "Signed in" : "Off"))
                }
            }
            Section("Playback") {
                NavigationLink { PlayerSettingsView() } label: { row("Player", icon: "play.rectangle", value: "mpv") }
                NavigationLink { PlayerAdvancedSettingsView() } label: {
                    row("Player Appearance & Audio", icon: "slider.horizontal.3", value: nil)
                }
                NavigationLink { LiveSettingsView() } label: { row("Live TV & Library", icon: "dot.radiowaves.left.and.right", value: nil) }
            }
            Section("Household") {
                NavigationLink { ProfilesSettingsView() } label: {
                    row("Profiles", icon: "person.2", value: ProfileStore.shared.activeProfile.name)
                }
                NavigationLink { SyncSettingsView() } label: {
                    row("Sync & Backup", icon: "arrow.triangle.2.circlepath", value: nil)
                }
                if ProfileStore.shared.isKidsMode && ProfileStore.shared.settingsUnlocked {
                    Button { ProfileStore.shared.lockSettings() } label: { Label("Lock Settings", systemImage: "lock") }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Player engine", value: "libmpv (MPVKit) · FFmpeg")
                LabeledContent("Torrent engine", value: TorrentEngine.embeddedAvailable ? "TorrServer (embedded + remote)" : "TorrServer (remote)")
            } header: {
                Text("About")
            } footer: {
                Text("StreamForge plays content from servers and addons you configure. It doesn't host or provide any content.")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Settings")
    }

    private func row(_ title: String, icon: String, value: String?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.secondaryText).lineLimit(1) }
        }
    }
}

// MARK: - Dispatcharr

struct DispatcharrSettingsView: View {
    @Environment(DispatcharrStore.self) private var store
    @State private var editing: DispatcharrServer?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    Button { store.activate(server.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).font(.headline)
                                Text("\(server.username.isEmpty ? "API key" : server.username) @ \(server.baseURL) · \(server.authMode.shortLabel)")
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if server.id == store.activeServer?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                    .contextMenu {
                        Button { editing = server } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { store.remove(server) } label: { Label("Remove", systemImage: "trash") }
                    }
                    #if os(iOS)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(server) } label: { Label("Remove", systemImage: "trash") }
                        Button { editing = server } label: { Label("Edit", systemImage: "pencil") }
                    }
                    #endif
                }
                Button { adding = true } label: { Label("Add Server", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Sign in with your Dispatcharr account (or an API key): StreamForge fetches your XC streaming password automatically. Live TV, the guide, catch-up, movies and series come through Dispatcharr's Xtream Codes API; recordings and channel profiles use its REST API.")
            }
            if let warning = store.credentialWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.gold).font(.footnote)
                }
            }
            if store.isConfigured {
                GuideSettingsSection()
                if !store.channelProfiles.isEmpty {
                    Section {
                        Picker("Channel profile", selection: Binding(get: { store.activeServer?.channelProfileID ?? -1 },
                                                                     set: { store.setChannelProfile($0 < 0 ? nil : $0) })) {
                            Text("All channels").tag(-1)
                            ForEach(store.channelProfiles) { p in Text(p.name).tag(p.id) }
                        }
                    } header: {
                        Text("Channel profile")
                    } footer: {
                        Text(store.channelProfileNote ?? "Show only the channels in one of your Dispatcharr channel profiles.")
                    }
                }
                Section("Library") {
                    LabeledContent("Channels", value: "\(store.channels.count)")
                    LabeledContent("Movies", value: "\(store.movies.count)")
                    LabeledContent("Series", value: "\(store.series.count)")
                    if let d = store.lastRefresh { LabeledContent("Updated", value: d.formatted(date: .omitted, time: .shortened)) }
                    Button {
                        Task {
                            await store.refreshAll(force: true)
                            await store.loadChannelProfiles()
                        }
                    } label: { Label("Refresh Now", systemImage: "arrow.clockwise") }
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Dispatcharr")
        .sheet(isPresented: $adding) { DispatcharrServerForm(server: nil) }
        .sheet(item: $editing) { DispatcharrServerForm(server: $0) }
    }
}

struct DispatcharrServerForm: View {
    var server: DispatcharrServer?
    @Environment(DispatcharrStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: DispatcharrAuthMode = .account
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var xcPassword = ""
    @State private var webPassword = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false
    /// Account / API-key login worked but the user has no XC password in Dispatcharr.
    @State private var needsManualXC = false
    @State private var verified = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sign in with", selection: $mode) {
                        ForEach(DispatcharrAuthMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(modeFooter)
                }
                Section("Server") {
                    TextField("Name (optional)", text: $name)
                    TextField("Address, e.g. http://192.168.1.10:9191", text: $url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                credentialsSection
                if needsManualXC || mode == .xc {
                    Section {
                        SecureField("XC password", text: $xcPassword)
                    } header: {
                        Text(mode == .xc ? "Streaming (required)" : "XC password")
                    } footer: {
                        Text(mode == .xc
                             ? "The XC password is set per user in Dispatcharr (Users → edit → XC Password). It is not your web login password."
                             : "Your Dispatcharr user has no XC password yet. Ask the admin to set one (Users → edit user → XC Password), or enter it here if you know it.")
                    }
                }
                if mode == .xc {
                    Section {
                        SecureField("Web password (optional)", text: $webPassword)
                    } header: { Text("DVR (optional)") } footer: {
                        Text("Your Dispatcharr login password unlocks recordings and channel profiles.")
                    }
                }
                Section {
                    Button { Task { await test() } } label: {
                        HStack {
                            Text(mode == .xc ? "Test Connection" : "Sign In")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(!canTest || testing)
                    if let result {
                        Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(ok ? .green : Theme.live)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(server == nil ? "Add Dispatcharr" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveTapped() } }.disabled(!canSave || testing)
                }
            }
            .onChange(of: mode) { result = nil; needsManualXC = false; verified = false }
        }
        .onAppear {
            if let server {
                mode = server.authMode
                name = server.name; url = server.baseURL; username = server.username
                xcPassword = server.xcPassword
                webPassword = server.webPassword
                password = server.authMode == .account ? server.webPassword : ""
                apiKey = server.apiKey
                verified = true
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        switch mode {
        case .account:
            Section {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField("Password", text: $password)
            } header: { Text("Dispatcharr account") } footer: {
                Text("The same username and password you use for Dispatcharr's web interface.")
            }
        case .apiKey:
            Section {
                SecureField("API key", text: $apiKey)
            } header: { Text("API key") } footer: {
                Text("Create a key in Dispatcharr (your user menu → API keys). The username and XC password are read from your account.")
            }
        case .xc:
            Section {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            } header: { Text("XC username") }
        }
    }

    private var modeFooter: String {
        switch mode {
        case .account: return "Recommended: one login gives live TV, guide, VOD, DVR and channel profiles."
        case .apiKey: return "For accounts that use API keys instead of a password."
        case .xc: return "Only the Xtream Codes credentials. Add a web password for DVR."
        }
    }

    private var canTest: Bool {
        guard !url.trimmed.isEmpty else { return false }
        switch mode {
        case .account: return !username.trimmed.isEmpty && !password.isEmpty
        case .apiKey: return !apiKey.trimmed.isEmpty
        case .xc: return !username.trimmed.isEmpty && !xcPassword.isEmpty
        }
    }

    private var canSave: Bool {
        guard canTest else { return false }
        if mode == .xc { return true }
        return verified || !xcPassword.isEmpty
    }

    private func draft() -> DispatcharrServer {
        var s = server ?? DispatcharrServer(name: "", baseURL: "", username: "")
        s.name = name.trimmed.isEmpty ? (URL.normalizedBase(url)?.host ?? "Dispatcharr") : name.trimmed
        s.baseURL = url.trimmed
        s.username = username.trimmed
        s.authMode = mode
        return s
    }

    /// A copy under a throwaway id so testing never touches saved credentials.
    private func probe() -> DispatcharrServer {
        var p = draft()
        p.id = UUID()
        p.webPassword = mode == .account ? password : webPassword
        p.apiKey = mode == .apiKey ? apiKey : ""
        p.xcPassword = xcPassword
        return p
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let p = probe()
        defer { p.clearSecrets() }
        do {
            var text = ""
            var probeServer = p
            if mode != .xc {
                let me = try await DispatcharrREST(server: p).me()
                if !me.username.isEmpty {
                    username = me.username
                    probeServer.username = me.username
                }
                if let xc = me.xcPassword, !xc.isEmpty {
                    xcPassword = xc
                    p.xcPassword = xc
                    needsManualXC = false
                } else if xcPassword.isEmpty {
                    needsManualXC = true
                    verified = true
                    result = "Signed in as \(me.username), but this user has no XC password. Ask your Dispatcharr admin to set one (Users → edit → XC Password), or enter it below."
                    ok = false
                    return
                }
                text = "Signed in as \(me.username.isEmpty ? "API key" : me.username)"
            }
            let auth = try await XtreamClient(server: probeServer).authenticate()
            text += text.isEmpty ? "Connected" : " · streaming OK"
            if let max = auth.userInfo?.maxConnections { text += " · \(max) streams allowed" }
            if mode == .xc, !webPassword.isEmpty {
                do {
                    try await DispatcharrREST(server: probeServer).login()
                    text += " · DVR enabled"
                } catch {
                    text += " · DVR login failed"
                }
            }
            verified = true
            result = text
            ok = true
        } catch {
            result = error.localizedDescription
            ok = false
        }
    }

    private func saveTapped() async {
        if mode != .xc, !verified || xcPassword.isEmpty {
            await test()
            guard ok, !xcPassword.isEmpty else { return }
        }
        switch mode {
        case .account:
            store.upsert(draft(), xcPassword: xcPassword, webPassword: password, apiKey: "")
        case .apiKey:
            store.upsert(draft(), xcPassword: xcPassword, webPassword: "", apiKey: apiKey.trimmed)
        case .xc:
            store.upsert(draft(), xcPassword: xcPassword, webPassword: webPassword, apiKey: "")
        }
        dismiss()
    }
}

/// Settings → Dispatcharr → Guide: bulk XMLTV status and options.
struct GuideSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    private var guide: GuideStore { .shared }

    var body: some View {
        @Bindable var settings = settings
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(guide.statusText).font(.subheadline)
                if case .downloading(_, let fraction) = guide.phase {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                } else if case .parsing = guide.phase {
                    ProgressView()
                }
                if guide.channelCount > 0 {
                    Text("\(guide.channelCount) channels covered").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Picker("Days to download", selection: $settings.values.guideDays) {
                ForEach([1, 2, 3, 5, 7, 10, 14], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
            }
            Toggle("Refresh every 6 hours", isOn: $settings.values.refreshGuideAutomatically)
            Button { Task { await guide.refresh(force: true) } } label: {
                Label("Refresh Guide Now", systemImage: "arrow.clockwise")
            }
            .disabled(guide.phase.isBusy)
        } header: {
            Text("TV Guide")
        } footer: {
            Text("Downloads Dispatcharr's full XMLTV guide once instead of asking per channel. Channels with catch-up also get yesterday's programmes.")
        }
    }
}

// MARK: - Addons

struct AddonsSettingsView: View {
    @Environment(AddonManager.self) private var addons
    @State private var url = ""
    @State private var installing = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                TextField("Addon URL (…/manifest.json or stremio://…)", text: $url)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button {
                    Task {
                        installing = true
                        do {
                            let a = try await addons.install(from: url)
                            message = "Installed \(a.manifest.name)"
                            url = ""
                        } catch {
                            message = error.localizedDescription
                        }
                        installing = false
                    }
                } label: {
                    HStack { Text("Install"); Spacer(); if installing { ProgressView() } }
                }
                .disabled(url.trimmed.isEmpty || installing)
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.secondaryText) }
            } header: {
                Text("Install Addon")
            } footer: {
                Text("Paste any Stremio addon manifest link. Addons that need configuration must be configured on their website first; paste the configured link. Order matters: addons higher in the list are asked first.")
            }

            Section("Installed") {
                ForEach(addons.addons) { addon in
                    HStack(spacing: 12) {
                        RemoteImage(url: addon.logoURL, contentMode: .fit, placeholderSymbol: "puzzlepiece.extension")
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(addon.manifest.name).font(.headline)
                            Text(capabilities(addon)).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { addon.enabled }, set: { addons.setEnabled(addon, $0) }))
                            .labelsHidden()
                    }
                    .contextMenu {
                        Button(role: .destructive) { addons.remove(addon) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                #if os(iOS)
                .onDelete { idx in idx.map { addons.addons[$0] }.forEach { addons.remove($0) } }
                .onMove { addons.move(from: $0, to: $1) }
                #endif
            }
            Section {
                Button { Task { await addons.refreshManifests() } } label: { Label("Update All Manifests", systemImage: "arrow.clockwise") }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Addons")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func capabilities(_ a: InstalledAddon) -> String {
        var c: [String] = []
        if !(a.manifest.catalogs ?? []).isEmpty { c.append("Catalogs") }
        if a.manifest.hasMeta { c.append("Metadata") }
        if a.manifest.hasStreams { c.append("Streams") }
        if a.manifest.hasSubtitles { c.append("Subtitles") }
        return c.joined(separator: " · ") + (a.manifest.version.map { "  v\($0)" } ?? "")
    }
}

// MARK: - Torrents

struct TorrentSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TorrentEngine.self) private var engine
    @State private var password = AppSettings.shared.torrServerPassword
    @State private var status: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            if TorrentEngine.embeddedAvailable {
                Section {
                    Picker("Engine", selection: $settings.values.torrentMode) {
                        ForEach(TorrentMode.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("“On this device” runs TorrServer inside the app: no extra hardware needed, streams use your phone's connection and a small RAM cache. “Remote” uses a TorrServer on your network or seedbox.")
                }
            } else {
                Section {
                    Text("Apple TV streams torrents through a TorrServer on your network (Docker, NAS, or a computer).")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }

            if engine.mode == .remote {
                Section("Remote TorrServer") {
                    TextField("Address, e.g. http://192.168.1.10:8090", text: $settings.values.remoteTorrServerURL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Username (if auth enabled)", text: $settings.values.torrServerUser)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                        .onChange(of: password) { settings.torrServerPassword = password }
                }
            } else {
                Section("On-device cache") {
                    #if os(tvOS)
                    Picker("RAM cache", selection: $settings.values.embeddedCacheMB) {
                        ForEach(Array(stride(from: 64, through: 1024, by: 64)), id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    Picker("Preload before play", selection: $settings.values.preloadPercent) {
                        ForEach(Array(stride(from: 0, through: 50, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                    }
                    #else
                    Stepper("RAM cache: \(settings.values.embeddedCacheMB) MB", value: $settings.values.embeddedCacheMB, in: 64...1024, step: 64)
                    Stepper("Preload before play: \(settings.values.preloadPercent)%", value: $settings.values.preloadPercent, in: 0...50, step: 5)
                    #endif
                }
            }

            Section {
                Button {
                    Task {
                        status = "Checking…"
                        if engine.mode == .embedded { await engine.startEmbeddedIfNeeded() }
                        if let v = await engine.serverVersion() {
                            status = "Connected · \(v)"
                        } else {
                            status = engine.lastError ?? "Not reachable"
                        }
                    }
                } label: { Label("Test Engine", systemImage: "bolt.horizontal.circle") }
                if let status { Text(status).font(.footnote).foregroundStyle(Theme.secondaryText) }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Torrents")
    }
}

// MARK: - Metadata

struct MetadataSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var tmdb = AppSettings.shared.tmdbKey
    @State private var omdb = AppSettings.shared.omdbKey
    @State private var fanart = AppSettings.shared.fanartKey

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(settings.values.metadataPriority) { source in
                    Label(source.label, systemImage: icon(source))
                }
                #if os(iOS)
                .onMove { settings.values.metadataPriority.move(fromOffsets: $0, toOffset: $1) }
                #endif
                #if os(tvOS)
                Picker("First choice", selection: Binding(get: { settings.values.metadataPriority.first ?? .tmdb }, set: { first in
                    settings.values.metadataPriority = [first] + MetadataSource.allCases.filter { $0 != first }
                })) {
                    ForEach(MetadataSource.allCases) { Text($0.label).tag($0) }
                }
                #endif
            } header: {
                Text("Priority")
            } footer: {
                Text("Earlier sources win for titles, artwork and descriptions. Your IPTV provider's episodes are always used for playback.")
            }

            Section {
                SecureField("TMDB API key or read token", text: $tmdb).onChange(of: tmdb) { settings.tmdbKey = tmdb }
                SecureField("OMDb API key", text: $omdb).onChange(of: omdb) { settings.omdbKey = omdb }
                SecureField("Fanart.tv API key", text: $fanart).onChange(of: fanart) { settings.fanartKey = fanart }
            } header: {
                Text("API keys")
            } footer: {
                Text("TMDB (themoviedb.org) powers artwork, cast, trailers, trending and episode stills. OMDb adds IMDb, Rotten Tomatoes and Metacritic scores. Fanart.tv adds title logos. All are free for personal use.")
            }

            Section("Options") {
                TextField("Language (ISO code)", text: $settings.values.metadataLanguage)
                Toggle("Fill missing posters from TMDB", isOn: $settings.values.enrichPosters)
                Toggle("Hide adult content", isOn: $settings.values.hideAdult)
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Metadata")
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func icon(_ s: MetadataSource) -> String {
        switch s {
        case .provider: return "server.rack"
        case .tmdb: return "film"
        case .cinemeta: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Trakt

struct TraktSettingsView: View {
    @Environment(TraktService.self) private var trakt
    @Environment(AppSettings.self) private var settings
    @State private var clientID = AppSettings.shared.traktClientID
    @State private var secret = AppSettings.shared.traktClientSecret
    @State private var code: TraktService.DeviceCode?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var syncMessage: String?

    var body: some View {
        Form {
            if trakt.isSignedIn {
                Section {
                    LabeledContent("Account", value: trakt.username ?? "Signed in")
                    Button("Sync Watchlist & Up Next") {
                        Task {
                            await trakt.refreshWatchlist()
                            await trakt.refreshUpNext(force: true)
                        }
                    }
                    Button("Import Playback Progress") {
                        Task {
                            let n = await trakt.syncPlayback()
                            syncMessage = n == 0 ? "No in-progress items on Trakt." : "Merged \(n) in-progress item\(n == 1 ? "" : "s") into \(ProfileStore.shared.activeProfile.name)."
                        }
                    }
                    if let syncMessage { Text(syncMessage).font(.footnote).foregroundStyle(Theme.secondaryText) }
                    Button("Sign Out", role: .destructive) { trakt.signOut() }
                } footer: {
                    Text("What you watch is scrobbled to Trakt automatically. Progress from other apps is imported at launch.")
                }
            } else {
                Section {
                    TextField("Client ID", text: $clientID).onChange(of: clientID) { settings.traktClientID = clientID }
                    SecureField("Client secret", text: $secret).onChange(of: secret) { settings.traktClientSecret = secret }
                } header: {
                    Text("Trakt app")
                } footer: {
                    Text("Create an app at trakt.tv/oauth/applications (redirect URI: urn:ietf:wg:oauth:2.0:oob) and paste its keys.")
                }
                Section {
                    if let code {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Go to \(code.verification_url) and enter:")
                            Text(code.user_code).font(.system(size: 34, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.accent)
                            HStack { ProgressView(); Text("Waiting for approval…").font(.footnote) }
                        }
                    } else {
                        Button("Sign In with Trakt") { start() }.disabled(clientID.isEmpty || secret.isEmpty)
                    }
                    if let error { Text(error).foregroundStyle(Theme.live).font(.footnote) }
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Trakt")
        .onDisappear { task?.cancel() }
    }

    private func start() {
        error = nil
        task = Task {
            do {
                let c = try await trakt.startDeviceAuth()
                code = c
                try await trakt.pollDeviceAuth(c)
                code = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                code = nil
            }
        }
    }
}

// MARK: - Player

struct PlayerSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Decoding", selection: $settings.values.hwdec) {
                    ForEach(HardwareDecoding.allCases) { Text($0.label).tag($0) }
                }
                Toggle("HDR / Dolby Vision output", isOn: $settings.values.hdrPassthrough)
                #if os(tvOS)
                Picker("Cache", selection: $settings.values.demuxerCacheMB) {
                    ForEach(Array(stride(from: 50, through: 800, by: 50)), id: \.self) { Text("\($0) MB").tag($0) }
                }
                #else
                Stepper("Cache: \(settings.values.demuxerCacheMB) MB", value: $settings.values.demuxerCacheMB, in: 50...800, step: 50)
                #endif
            } header: { Text("Video") } footer: {
                Text("mpv renders through Metal with VideoToolbox hardware decoding, libplacebo tone-mapping and full HDR10/HLG/Dolby Vision support. Try “compatible” decoding if a file shows artifacts.")
            }
            Section("Audio & Subtitles") {
                TextField("Preferred audio language", text: $settings.values.preferredAudioLanguage)
                TextField("Preferred subtitle language", text: $settings.values.preferredSubtitleLanguage)
                Toggle("Turn on subtitles automatically", isOn: $settings.values.autoSubtitles)
                #if os(tvOS)
                Picker("Subtitle size", selection: $settings.values.subtitleScale) {
                    ForEach(Array(stride(from: 5, through: 25, by: 1)), id: \.self) { (tenths: Int) in
                        Text(String(format: "%.1f×", Double(tenths) / 10)).tag(Double(tenths) / 10)
                    }
                }
                #else
                Stepper(String(format: "Subtitle size: %.1f×", settings.values.subtitleScale), value: $settings.values.subtitleScale, in: 0.5...2.5, step: 0.1)
                #endif
            }
            Section("Controls") {
                Picker("Skip interval", selection: $settings.values.seekStep) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Resume where I left off", isOn: $settings.values.resumePlayback)
                Toggle("Autoplay next episode", isOn: $settings.values.autoplayNext)
            }
            Section("Sources") {
                Picker("Sort streams by", selection: $settings.values.streamSort) {
                    ForEach(StreamSort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Maximum quality", selection: $settings.values.maxStreamResolution) {
                    Text("4K").tag(2160); Text("1080p").tag(1080); Text("720p").tag(720)
                }
                Toggle("Hide CAM / telesync releases", isOn: $settings.values.excludeCam)
            }
            #if os(iOS)
            Section {
                Toggle("Autoplay trailers on detail pages", isOn: $settings.values.trailerAutoplay)
            } header: { Text("Detail pages") } footer: {
                Text("Plays a muted trailer behind the artwork. Never on cellular or in Low Data Mode.")
            }
            #else
            Section {
                Toggle("Autoplay trailers on detail pages", isOn: $settings.values.trailerAutoplay)
                TextField("Invidious instance, e.g. https://yewtu.be", text: $settings.values.invidiousInstance)
            } header: { Text("Detail pages") } footer: {
                Text("Apple TV can't embed YouTube, so trailers stream through an Invidious instance you choose. Leave it empty to keep trailers off.")
            }
            #endif
            Section {
                TextField("Custom User-Agent", text: $settings.values.customUserAgent)
            } header: { Text("Network") } footer: {
                Text("Some providers require a specific player User-Agent. Leave empty for the default.")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Player")
    }
}

struct LiveSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Live TV") {
                Toggle("Show channel numbers", isOn: $settings.values.showChannelNumbers)
                #if os(tvOS)
                Picker("Live buffer", selection: $settings.values.liveBufferSeconds) {
                    ForEach(1...20, id: \.self) { Text("\($0)s").tag($0) }
                }
                #else
                Stepper("Live buffer: \(settings.values.liveBufferSeconds)s", value: $settings.values.liveBufferSeconds, in: 1...20)
                #endif
            }
            Section {
                ForEach(store.liveCategories) { cat in
                    categoryToggle(cat.name, key: "live:\(cat.id)")
                }
            } header: { Text("Visible channel groups") }
            Section {
                ForEach(store.movieCategories) { cat in categoryToggle(cat.name, key: "movie:\(cat.id)") }
            } header: { Text("Visible movie categories") }
            Section {
                ForEach(store.seriesCategories) { cat in categoryToggle(cat.name, key: "series:\(cat.id)") }
            } header: { Text("Visible series categories") }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Live TV & Library")
    }

    private func categoryToggle(_ name: String, key: String) -> some View {
        Toggle(name, isOn: Binding(get: { !library.isHidden(category: key) }, set: { _ in library.toggleHidden(category: key) }))
    }
}
