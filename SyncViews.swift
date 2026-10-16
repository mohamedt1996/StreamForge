import SwiftUI
import UniformTypeIdentifiers

/// Settings → Sync & Backup.
struct SyncSettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { ServerSyncView() } label: {
                    HStack {
                        Label("StreamForge Server", systemImage: "arrow.triangle.2.circlepath.circle")
                        Spacer()
                        Text(ServerSync.shared.isSignedIn ? ServerSync.shared.statusText : "Off")
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Sync server")
            } footer: {
                Text("Your own server keeps iPhone, iPad, Apple TV and Android in sync, with accounts and per-device access.")
            }
            CloudSyncSection()
            Section {
                NavigationLink { ReceiveSyncView() } label: {
                    Label(receiveTitle, systemImage: "square.and.arrow.down.on.square")
                }
                NavigationLink { SendSyncView() } label: {
                    Label(sendTitle, systemImage: "square.and.arrow.up.on.square")
                }
            } header: {
                Text("Local network")
            } footer: {
                Text("Copies your Dispatcharr servers (with passwords), addons, settings, API keys, profiles and libraries to another StreamForge on the same Wi-Fi. No cloud account needed: the receiving device shows a 4-digit code you type on the sender.")
            }
            #if os(iOS)
            BackupSection()
            #else
            Section("Backup") {
                Text("Backup files can be made and restored on iPhone or iPad. To set up this Apple TV, use “Receive from iPhone” above.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            #endif
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Sync & Backup")
    }

    private var receiveTitle: String {
        #if os(tvOS)
        return "Receive from iPhone"
        #else
        return "Receive from another device"
        #endif
    }

    private var sendTitle: String {
        #if os(tvOS)
        return "Send to another device"
        #else
        return "Send to Apple TV"
        #endif
    }
}

struct ReceiveSyncView: View {
    private var sync: LocalSyncService { .shared }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "appletv.fill").font(.system(size: 60)).foregroundStyle(Theme.accentGradient)
            switch sync.receiverState {
            case .idle, .waiting:
                Text("Waiting for another device…").font(.title2.weight(.bold))
                Text("On your iPhone or iPad open StreamForge → Settings → Sync & Backup → Send to Apple TV and pick “\(SyncService.deviceName)”.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText).frame(maxWidth: 560)
                ProgressView()
            case .paired(let code, _):
                Text("Enter this code on the other device").font(.title2.weight(.bold))
                Text(code)
                    .font(.system(size: 96, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.accentGradient)
                    .kerning(12)
            case .received(let summary):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text(summary).font(.title3.weight(.semibold)).multilineTextAlignment(.center).frame(maxWidth: 600)
                Button("Receive Again") { sync.startReceiving() }.buttonStyle(.bordered)
            case .failed(let message):
                Text(message).foregroundStyle(Theme.live).multilineTextAlignment(.center).frame(maxWidth: 600)
                Button("Try Again") { sync.startReceiving() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("Receive")
        .onAppear { sync.startReceiving() }
        .onDisappear { sync.stopReceiving() }
    }
}

struct SendSyncView: View {
    private var sync: LocalSyncService { .shared }
    @State private var codeError = false

    var body: some View {
        Group {
            switch sync.senderState {
            case .needsCode(let name):
                ScrollView {
                    PINPadView(title: "Enter the code shown on \(name)", subtitle: sync.lastError, error: codeError) { code in
                        sync.send(code: code)
                        return true
                    } onCancel: {
                        sync.startBrowsing()
                    }
                }
            case .connecting(let name):
                LoadingView(text: "Connecting to \(name)…")
            case .sending:
                LoadingView(text: "Sending…")
            case .sent(let message):
                EmptyStateView(icon: "checkmark.circle", title: "Done", message: message, actionTitle: "Send Again") { sync.startBrowsing() }
            case .failed(let message):
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't send", message: message, actionTitle: "Try Again") { sync.startBrowsing() }
            case .idle, .browsing:
                peerList
            }
        }
        .screenBackground()
        .navigationTitle("Send")
        .onAppear { sync.startBrowsing() }
        .onDisappear { sync.stopBrowsing() }
    }

    private var peerList: some View {
        List {
            Section {
                if sync.peers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for devices… Open Settings → Sync & Backup → Receive on the other device.")
                            .font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                ForEach(sync.peers) { peer in
                    Button { sync.connect(to: peer) } label: {
                        Label(peer.name, systemImage: peer.name.lowercased().contains("tv") ? "appletv" : "iphone")
                    }
                }
            } header: {
                Text("Devices on this network")
            } footer: {
                Text("Sends servers and their passwords, addons, settings, API keys, profiles (with PINs) and libraries. Data is encrypted with the pairing code.")
            }
        }
        .hiddenListBackground()
    }
}

#if os(iOS)
/// Backup export (share sheet / Files) and import (iOS only).
struct BackupSection: View {
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share Backup File", systemImage: "square.and.arrow.up") }
            } else {
                Button { makeBackup() } label: { Label("Create Backup", systemImage: "doc.badge.arrow.up") }
            }
            Button { importing = true } label: { Label("Restore from Backup…", systemImage: "doc.badge.arrow.down") }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text("Backup")
        } footer: {
            Text("The backup is a JSON file that includes your passwords and API keys. Keep it private.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let summary = try await SyncService.importFile(url)
                        message = "Restored \(summary)."
                    } catch {
                        message = error.localizedDescription
                    }
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func makeBackup() {
        do {
            exportURL = try SyncService.exportFile()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
#endif


/// iCloud: automatic sync between every device signed in to the same Apple ID.
struct CloudSyncSection: View {
    private var cloud: CloudSync { .shared }
    @State private var busy = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { cloud.isEnabled }, set: { cloud.isEnabled = $0 })) {
                Label("iCloud Sync", systemImage: "icloud")
            }
            if cloud.isEnabled {
                LabeledContent("Status", value: cloud.status.text)
                if let device = cloud.lastRemoteDevice {
                    LabeledContent("Last change from", value: device)
                }
                Button {
                    busy = true
                    Task {
                        await cloud.syncNow()
                        busy = false
                    }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(!cloud.iCloudAvailable || busy || ServerSync.shared.isSignedIn)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Keeps servers, addons, settings, profiles, favorites and watch progress the same on every iPhone, iPad and Apple TV signed in to your Apple ID. Passwords and PINs travel through iCloud Keychain. Requires a build signed with an Apple Developer account that has iCloud enabled; otherwise use local-network sync below.")
        }
    }
}
