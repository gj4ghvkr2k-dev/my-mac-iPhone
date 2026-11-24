import RemoteCore
import SwiftUI

/// 接続中の画面に渡すもの。
struct ActiveRemote: Identifiable {
    let id = UUID()
    let session: RemoteSession
}

/// 登録済みの Mac の一覧（アプリの最初の画面）。
struct HostListView: View {
    @ObservedObject var store: ClientStore
    @State private var activeRemote: ActiveRemote?
    @State private var showsScanner = false
    @State private var pendingInvitation: PairingInvitation?
    @State private var alertMessage: String?
    @State private var peerToRemove: TrustedPeer?

    var body: some View {
        NavigationStack {
            List {
                if let problem = store.browserProblem {
                    Section {
                        Label(problem, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if store.hosts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("まだ Mac が登録されていません").font(.headline)
                            Text("Mac で MacRemote を起動し、メニューバーのアイコンから「iPhone／iPad を追加」を選んでください。表示された QR コードを、右上の ＋ から読み取ると登録できます。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    ForEach(store.hosts) { host in
                        Button {
                            connect(to: host)
                        } label: {
                            HostRow(host: host, isOnline: store.isOnline(host))
                        }
                        .swipeActions {
                            Button("削除", role: .destructive) { peerToRemove = host }
                        }
                    }
                } header: {
                    Text("登録済みの Mac")
                } footer: {
                    if !store.hosts.isEmpty {
                        Text("Mac と同じ Wi-Fi にいるか、Wi-Fi をオンにして Mac の近くにいると「接続できます」と表示されます。")
                    }
                }
            }
            .navigationTitle("MacRemote")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Mac を追加", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear { store.startBrowsing() }
        .sheet(isPresented: $showsScanner) {
            ScannerSheet { code in
                showsScanner = false
                handleScanned(code)
            }
        }
        .overlay {
            if let pendingInvitation {
                SearchingOverlay(hostName: pendingInvitation.hostName) {
                    self.pendingInvitation = nil
                }
            }
        }
        .onChange(of: store.onlineHostIDs) { _, _ in startPendingPairingIfPossible() }
        .fullScreenCover(item: $activeRemote) { remote in
            RemoteScreen(session: remote.session) { activeRemote = nil }
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .alert("MacRemote", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            "「\(peerToRemove?.name ?? "")」の登録を削除しますか？",
            isPresented: Binding(get: { peerToRemove != nil }, set: { if !$0 { peerToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let peerToRemove { store.remove(peerToRemove) }
                peerToRemove = nil
            }
        } message: {
            Text("Mac 側の登録も削除する場合は、Mac の MacRemote の設定から削除してください。")
        }
    }

    // MARK: - 操作

    private func connect(to host: TrustedPeer) {
        guard let session = store.makeSession(for: host) else {
            alertMessage = "「\(host.name)」が見つかりません。Mac で MacRemote が起動していて、同じ Wi-Fi にいるか（または Wi-Fi をオンにして近くにいるか）確認してください。"
            return
        }
        activeRemote = ActiveRemote(session: session)
    }

    private func handleScanned(_ code: String) {
        guard let invitation = try? PairingInvitation(string: code) else {
            alertMessage = "MacRemote の QR コードではないようです。Mac の MacRemote で表示した QR コードを読み取ってください。"
            return
        }
        pendingInvitation = invitation
        startPendingPairingIfPossible()

        // 15 秒たっても見つからなければ諦める。
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard pendingInvitation == invitation else { return }
            pendingInvitation = nil
            alertMessage = "「\(invitation.hostName)」が見つかりませんでした。Mac と同じ Wi-Fi にいるか、Wi-Fi がオンになっているか確認してください。"
        }
    }

    private func startPendingPairingIfPossible() {
        guard let invitation = pendingInvitation,
              let session = store.makePairingSession(for: invitation) else { return }
        pendingInvitation = nil
        activeRemote = ActiveRemote(session: session)
    }
}

private struct HostRow: View {
    let host: TrustedPeer
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(isOnline ? Color.accentColor : Color.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isOnline ? "接続できます" : "見つかりません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView(onCode: onCode)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Mac の画面に表示された QR コードを読み取ってください")
                        .font(.subheadline)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 32)
                }
                .navigationTitle("Mac を追加")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                }
        }
    }
}

private struct SearchingOverlay: View {
    let hostName: String
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text("「\(hostName)」を探しています…")
                Button("キャンセル", action: onCancel)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// UIKit のリモート画面を SwiftUI で表示する。
struct RemoteScreen: UIViewControllerRepresentable {
    let session: RemoteSession
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> RemoteViewController {
        RemoteViewController(session: session, onClose: onClose)
    }

    func updateUIViewController(_ controller: RemoteViewController, context: Context) {}
}
