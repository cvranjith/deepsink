//
//  SettingsView.swift
//  DeepSink
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @State private var isTestingLogin = false
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("https://<name>.ts.net/gateway", text: $settings.gatewayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("DeepSink user ID", text: $settings.deepSinkUserID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $settings.deepSinkPassword)
                Button {
                    Task { await testLogin() }
                } label: {
                    if isTestingLogin { ProgressView() } else { Text("Test Login") }
                }
                .disabled(isTestingLogin)
            } header: {
                Text("Mac Mini")
            } footer: {
                Text("The one address to enter — its Tailscale Funnel URL, always reachable. When you're on the same Wi-Fi, the app finds the Mac mini's local address on its own (by asking the gateway, over this same URL, what its own address currently is) and prefers that for speed — nothing to configure for that part. The password is stored in Keychain, never in plain settings.")
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
                Toggle("Reminder to announce recording", isOn: $settings.announceRecordingReminder)
            } footer: {
                Text("Shows a brief on-screen reminder the moment you start recording, to say out loud that the room is being recorded. Recording consent law varies by jurisdiction — that's your call to make, not this app's.")
            }

            Section {
                Toggle("Live Assist", isOn: $settings.liveAssistEnabled)
            } footer: {
                Text("Runs on-device speech recognition while recording — no audio or text leaves the phone for this — to notice a keyword being said and to give Articulate something recent to work from. Uses extra battery, and needs Speech Recognition permission the first time you turn it on.")
            }

            if settings.liveAssistEnabled {
                Section {
                    // Indexed, not `id: \.self` on the strings themselves —
                    // with value-identity, every keystroke changes the
                    // element's identity (the string IS the ID), so SwiftUI
                    // tore down and rebuilt the TextField after each
                    // character, dropping keyboard focus every time. The
                    // index is stable while typing and only changes on
                    // insert/delete, which is exactly when a fresh identity
                    // is actually wanted.
                    ForEach(settings.attentionKeywords.indices, id: \.self) { index in
                        TextField("e.g. your name", text: Binding(
                            get: { settings.attentionKeywords[index] },
                            set: { settings.attentionKeywords[index] = $0 }
                        ))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    }
                    .onDelete { settings.attentionKeywords.remove(atOffsets: $0) }
                    Button("Add Keyword") {
                        settings.attentionKeywords.append("")
                    }
                } header: {
                    Text("Attention keywords")
                } footer: {
                    Text("Usually your name. Matched case-insensitively as a substring of whatever's recognized — you'll get a banner and a haptic buzz when one's heard.")
                }

                Section {
                    Stepper(value: $settings.articulateWindowSeconds, in: 60...600, step: 30) {
                        HStack {
                            Text("Articulate window")
                            Spacer()
                            Text("\(settings.articulateWindowSeconds / 60) min").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("How far back Articulate looks when you tap it.")
                }
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
        .alert("DeepSink Login", isPresented: Binding(get: { loginMessage != nil }, set: { if !$0 { loginMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginMessage ?? "")
        }
    }

    private func testLogin() async {
        isTestingLogin = true
        let result = await routerClient.testSessionLogin(settings: settings)
        isTestingLogin = false
        switch result {
        case .success: loginMessage = "Signed in successfully."
        case .failure(let error): loginMessage = error.message
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
