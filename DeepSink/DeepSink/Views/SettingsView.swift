//
//  SettingsView.swift
//  DeepSink
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @State private var isTestingConnection = false
    @State private var connectionMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("https://ai-router.<subdomain>.workers.dev", text: $settings.routerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bearer token", text: $settings.routerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTestingConnection { ProgressView() } else { Text("Test Connection") }
                }
                .disabled(isTestingConnection)
            } header: {
                Text("Router")
            } footer: {
                Text("The same ai-router your other personal apps use. The token is stored in Keychain, never in plain settings — see the app's README for what deepsink.transcribe/deepsink.notes need added server-side.")
            }

            Section {
                Stepper(value: $settings.chunkTargetSeconds, in: 60...600, step: 30) {
                    HStack {
                        Text("Chunk length")
                        Spacer()
                        Text("\(settings.chunkTargetSeconds / 60) min").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Target length before a chunk is cut and uploaded — actual cuts happen a little after this, at the next quiet moment in the room.")
            }

            Section {
                Stepper(value: $settings.deleteAudioAfterDays, in: 0...90, step: 1) {
                    HStack {
                        Text("Delete audio after")
                        Spacer()
                        Text(settings.deleteAudioAfterDays == 0 ? "Never" : "\(settings.deleteAudioAfterDays)d").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Audio is kept once a session is ready, then deleted automatically this many days later to save space. The transcript and notes are never deleted by this — only the audio files. Set to 0 to keep audio indefinitely.")
            }

            Section {
                Toggle("Reminder to announce recording", isOn: $settings.announceRecordingReminder)
            } footer: {
                Text("Shows a brief on-screen reminder the moment you start recording, to say out loud that the room is being recorded. Recording consent law varies by jurisdiction — that's your call to make, not this app's.")
            }

            Section {
                NavigationLink("Update App") {
                    DeployView()
                }
            } footer: {
                Text("Rebuilds and reinstalls over Wi-Fi — tucked away here rather than on the recording screen, since it's never safe to trigger mid-meeting.")
            }

            if let hash = BuildInfo.commitHash {
                Section {
                    HStack { Text("Build"); Spacer(); Text(hash).foregroundStyle(.secondary) }
                    if let installDate = BuildInfo.installDate {
                        HStack { Text("Installed"); Spacer(); Text(installDate.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Router", isPresented: Binding(get: { connectionMessage != nil }, set: { if !$0 { connectionMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionMessage ?? "")
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        let result = await routerClient.testConnection(settings: settings)
        isTestingConnection = false
        switch result {
        case .success: connectionMessage = "Connected successfully."
        case .failure(let error): connectionMessage = error.message
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environmentObject(AppSettings())
    .environmentObject(RouterClient())
}
