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
                NavigationLink { LiveSettingsView() } label: { row("Live TV & Library", icon: "dot.radiowaves.left.and.right", value: nil) }
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
        .scrollContentBackground(.hidden)
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
                                Text("\(server.username) @ \(server.baseURL)").font(.caption).foregroundStyle(Theme.secondaryText)
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
                Text("Use your Dispatcharr username and its XC password (Users → edit user → XC Password). Live TV, the guide, catch-up, movies and series all come through Dispatcharr's Xtream Codes API.")
            }
            if store.isConfigured {
                Section("Library") {
                    LabeledContent("Channels", value: "\(store.channels.count)")
                    LabeledContent("Movies", value: "\(store.movies.count)")
                    LabeledContent("Series", value: "\(store.series.count)")
                    if let d = store.lastRefresh { LabeledContent("Updated", value: d.formatted(date: .omitted, time: .shortened)) }
                    Button { Task { await store.refreshAll(force: true) } } label: { Label("Refresh Now", systemImage: "arrow.clockwise") }
                }
            }
        }
        .scrollContentBackground(.hidden)
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
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var xcPassword = ""
    @State private var webPassword = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $name)
                    TextField("Address, e.g. http://192.168.1.10:9191", text: $url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                Section {
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("XC password", text: $xcPassword)
                } header: { Text("Streaming (required)") } footer: {
                    Text("The XC password is set per user in Dispatcharr. It is not your web login password.")
                }
                Section {
                    SecureField("Web password (optional)", text: $webPassword)
                } header: { Text("DVR (optional)") } footer: {
                    Text("Your Dispatcharr login password unlocks scheduling and playing recordings.")
                }
                Section {
                    Button { Task { await test() } } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(url.trimmed.isEmpty || username.trimmed.isEmpty || xcPassword.isEmpty)
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
                    Button("Save") { save() }.disabled(url.trimmed.isEmpty || username.trimmed.isEmpty || xcPassword.isEmpty)
                }
            }
        }
        .onAppear {
            if let server {
                name = server.name; url = server.baseURL; username = server.username
                xcPassword = server.xcPassword; webPassword = server.webPassword
            }
        }
    }

    private func draft() -> DispatcharrServer {
        var s = server ?? DispatcharrServer(name: "", baseURL: "", username: "")
        s.name = name.trimmed.isEmpty ? (URL.normalizedBase(url)?.host ?? "Dispatcharr") : name.trimmed
        s.baseURL = url.trimmed
        s.username = username.trimmed
        return s
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let s = draft()
        // Test with an unsaved copy: write creds under a throwaway id.
        var probe = s
        probe.id = UUID()
        probe.xcPassword = xcPassword
        defer { probe.xcPassword = "" }
        do {
            let auth = try await XtreamClient(server: probe).authenticate()
            let info = auth.userInfo
            var text = "Connected"
            if let max = info?.maxConnections { text += " · \(max) streams allowed" }
            if !webPassword.isEmpty {
                probe.webPassword = webPassword
                defer { probe.webPassword = "" }
                do {
                    try await DispatcharrREST(server: probe).login()
                    text += " · DVR enabled"
                } catch {
                    text += " · DVR login failed"
                }
            }
            result = text
            ok = true
        } catch {
            result = error.localizedDescription
            ok = false
        }
    }

    private func save() {
        store.upsert(draft(), xcPassword: xcPassword, webPassword: webPassword)
        dismiss()
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
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
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

    var body: some View {
        Form {
            if trakt.isSignedIn {
                Section {
                    LabeledContent("Account", value: trakt.username ?? "Signed in")
                    Button("Sync Watchlist") { Task { await trakt.refreshWatchlist() } }
                    Button("Sign Out", role: .destructive) { trakt.signOut() }
                } footer: {
                    Text("What you watch is scrobbled to Trakt automatically.")
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
        .scrollContentBackground(.hidden)
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
            Section {
                TextField("Custom User-Agent", text: $settings.values.customUserAgent)
            } header: { Text("Network") } footer: {
                Text("Some providers require a specific player User-Agent. Leave empty for the default.")
            }
        }
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Live TV & Library")
    }

    private func categoryToggle(_ name: String, key: String) -> some View {
        Toggle(name, isOn: Binding(get: { !library.isHidden(category: key) }, set: { _ in library.toggleHidden(category: key) }))
    }
}
