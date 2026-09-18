//
//  DeployView.swift
//  DeepSink
//

import SwiftUI

// Ported from yt-run's DeployView — same one-click Wi-Fi update
// mechanism, same reasoning (a deploy is a multi-minute clean build, so
// this polls rather than holding one long request open), just talking
// to RouterClient's deploy methods instead of AIGatewayClient's. See
// README's "Router contract" section for the one option (`project`)
// ai-router's `local.deploy` needs added server-side to disambiguate
// yt-run from DeepSink.
struct DeployView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient

    @State private var isChecking = false
    @State private var isShowingConfirmation = false
    @State private var isDeploying = false
    @State private var liveLog = ""
    @State private var resultMessage: String?

    private static let maxWaitSeconds: TimeInterval = 20 * 60
    private static let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        Form {
            Section {
                if let installDate = BuildInfo.installDate {
                    HStack {
                        Text("Last installed")
                        Spacer()
                        Text(installDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let hash = BuildInfo.commitHash {
                    HStack {
                        Text("Commit")
                        Spacer()
                        Text(BuildInfo.commitDate.map { "\(hash) · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? hash)
                            .foregroundStyle(.secondary)
                    }
                }
                if isChecking {
                    HStack { ProgressView(); Text("Checking…") }
                } else if isDeploying {
                    HStack { ProgressView(); Text("Updating…") }
                } else {
                    Button("Update App") {
                        Task { await beginUpdateFlow() }
                    }
                }
                if !liveLog.isEmpty {
                    ScrollView {
                        Text(liveLog)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 220)
                }
            } footer: {
                Text("Pulls the latest code, rebuilds, and reinstalls onto this phone — takes a few minutes. The app will quit partway through when the new build replaces it; just reopen it afterward. Never triggers while a recording is in progress.")
            }
        }
        .navigationTitle("Update App")
        .onAppear {
            Task { await resumeIfAlreadyRunning() }
        }
        .confirmationDialog(
            "Update the app now?",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update", role: .destructive) {
                Task { await runDeploy() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rebuilds and reinstalls the app — it will quit unexpectedly partway through. Reopen it afterward to use the new version. Existing sessions and queued uploads survive a reinstall.")
        }
        .alert("Update App", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func beginUpdateFlow() async {
        isChecking = true
        let readiness = await routerClient.deployWifiStatus(settings: settings)
        isChecking = false
        switch readiness {
        case .success(let info):
            if info.proceedOK {
                isShowingConfirmation = true
            } else {
                resultMessage = "Not paired — move to the same Wi-Fi as your Mac mini and try again."
            }
        case .failure(let error):
            resultMessage = error.message
        }
    }

    private func resumeIfAlreadyRunning() async {
        guard !isDeploying else { return }
        if case .success(let info) = await routerClient.deployStatus(settings: settings), info.status == .running {
            isDeploying = true
            liveLog = info.logTail ?? ""
            await pollUntilFinished()
        }
    }

    private func runDeploy() async {
        isDeploying = true
        liveLog = ""
        switch await routerClient.startDeploy(settings: settings) {
        case .failure(let error):
            guard error.message.contains("already in progress") else {
                isDeploying = false
                resultMessage = error.message
                return
            }
        case .success:
            break
        }
        await pollUntilFinished()
    }

    private func pollUntilFinished() async {
        defer { isDeploying = false }
        let deadline = Date().addingTimeInterval(Self.maxWaitSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            switch await routerClient.deployStatus(settings: settings) {
            case .success(let info):
                if let logTail = info.logTail {
                    liveLog = logTail
                }
                switch info.status {
                case .success:
                    resultMessage = "Update installed — reopen the app to use the new version."
                    return
                case .failed:
                    resultMessage = "Update failed — see the log above for details."
                    return
                case .idle, .running:
                    continue
                }
            case .failure(let error):
                resultMessage = error.message
                return
            }
        }
        resultMessage = "Still running after \(Int(Self.maxWaitSeconds / 60)) minutes — check on it from the Mac directly."
    }
}

#Preview {
    NavigationStack {
        DeployView()
    }
    .environmentObject(AppSettings())
    .environmentObject(RouterClient())
}
