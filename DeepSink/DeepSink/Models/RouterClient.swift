//
//  RouterClient.swift
//  DeepSink
//

import Foundation
import Combine

enum RouterError: Error {
    case notConfigured
    case invalidURL
    case network(Error)
    case unauthorized
    case loginFailed(String)
    case server(String)
    case decoding
    case cancelled

    var message: String {
        switch self {
        case .notConfigured: return "Set the Mac mini's gateway URL and DeepSink login in Settings."
        case .invalidURL: return "The gateway URL in Settings doesn't look valid."
        case .network(let error): return "Couldn't reach the Mac mini: \(error.localizedDescription)"
        case .unauthorized: return "The gateway rejected this login — check the user ID/password in Settings."
        case .loginFailed(let message): return message
        case .server(let message): return message
        case .decoding: return "Got an unexpected response from the Mac mini."
        case .cancelled: return "Cancelled."
        }
    }
}

struct RouterDeployWifiInfo {
    let ssid: String?
    let ip: String?
    let proceedOK: Bool
}

enum RouterDeployStatus: String {
    case idle, running, success, failed
}

struct RouterDeployStatusInfo {
    let status: RouterDeployStatus
    let logTail: String?
}

// Talks to ai-gateway on the Mac mini directly — no Cloudflare/ai-router
// hop. That Worker added nothing for this single-user app (no fan-out to
// other backends, one client), so it's been cut from DeepSink's path
// entirely (yt-run still uses it for its own purposes — untouched).
//
// One credential for everything: DeepSink's own user_id/password (see
// `sessionToken` below), exchanged for a JWT that authenticates both
// request shapes this type makes, against whichever base URL
// `resolveBaseURL` currently resolves to:
//   - `invoke(...)` — ai-gateway's own `/invoke` envelope
//     (`{service_id, params}` -> `{result}`), used by `articulate` and
//     the deploy calls, both genuinely stateless AI/action calls.
//     ai-gateway's `/invoke` accepts this same user token as an
//     alternative to its OAuth2 Client Credentials grant (see
//     `gateway.py`'s `require_client_or_user`) specifically so DeepSink
//     doesn't need a second, separate registered client just for these.
//   - `restRequest(...)` — plain REST against `/deepsink/sessions/*`
//     (ai-gateway's own session store; see that project's README). This
//     is real, stateful CRUD, not an AI call, so it isn't forced into the
//     invoke envelope — method/path/body/status all pass through as-is,
//     and every write endpoint returns the full, current session.
final class RouterClient: ObservableObject {

    // MARK: - Base URL resolution (LAN-preferred, Funnel-fallback)
    //
    // Only one URL is configured (`settings.gatewayURL`, the Mac mini's
    // Tailscale Funnel address) — the LAN address isn't a setting at all.
    // It's discovered at runtime by asking the gateway itself, over that
    // same Funnel URL, what its own current local IP is (`mac_deploy`'s
    // `wifi_status` action — already existed for the Update App screen).
    // That discovery call is pinned directly to the Funnel URL rather
    // than going through `resolveBaseURL`/`invoke` (which would be
    // circular — the whole point is finding out whether a LAN URL exists
    // yet), and its result is cached for a few minutes (`lanIPCacheTTL`)
    // since a home DHCP lease doesn't move often and it's a real network
    // round trip. The IP is combined with the fixed port ai-gateway
    // itself listens on (`gatewayLANPort` — hardcoded in `gateway.py`,
    // not something that varies) to get a candidate LAN URL, which is
    // then probed directly (`/health`, short timeout) — the probe is what
    // actually decides LAN-vs-Funnel for a given call, not network-name
    // matching, so it stays correct even if the cached IP is stale (the
    // probe just fails and this falls back to Funnel, same as if LAN had
    // never been discovered at all). The LAN-vs-Funnel *choice* itself is
    // cached even more briefly (`baseCacheTTL`) so a burst of calls
    // doesn't re-probe for each one; a real request failure against a
    // cached LAN choice invalidates that cache and retries once against
    // Funnel immediately, rather than waiting out the TTL while stuck on
    // a base URL that just stopped working (e.g. walking out of Wi-Fi
    // range mid-session).

    private struct ResolvedBase {
        let url: URL
        let isLAN: Bool
    }

    private static let gatewayLANPort = 8788

    private var cachedBase: ResolvedBase?
    private var cachedBaseTimestamp: Date?
    private let baseCacheTTL: TimeInterval = 30

    private var cachedLANURL: URL?
    private var cachedLANURLTimestamp: Date?
    private let lanIPCacheTTL: TimeInterval = 300

    private let lanProbeTimeout: TimeInterval = 2.5

    private func resolveBaseURL(settings: AppSettings) async -> Result<ResolvedBase, RouterError> {
        if let cachedBase, let cachedBaseTimestamp, Date().timeIntervalSince(cachedBaseTimestamp) < baseCacheTTL {
            return .success(cachedBase)
        }

        guard let funnelURL = Self.normalizedURL(settings.gatewayURL) else {
            return .failure(settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notConfigured : .invalidURL)
        }

        var lanCandidate: URL?
        if let cachedLANURL, let cachedLANURLTimestamp, Date().timeIntervalSince(cachedLANURLTimestamp) < lanIPCacheTTL {
            lanCandidate = cachedLANURL
        } else if let discovered = await discoverLANURL(funnelURL: funnelURL, settings: settings) {
            lanCandidate = discovered
            cachedLANURL = discovered
            cachedLANURLTimestamp = Date()
        }

        if let lanCandidate, await Self.probe(lanCandidate, timeout: lanProbeTimeout) {
            let resolved = ResolvedBase(url: lanCandidate, isLAN: true)
            cachedBase = resolved
            cachedBaseTimestamp = Date()
            return .success(resolved)
        }

        let resolved = ResolvedBase(url: funnelURL, isLAN: false)
        cachedBase = resolved
        cachedBaseTimestamp = Date()
        return .success(resolved)
    }

    // Asks the gateway (over Funnel — always reachable, unlike the thing
    // being discovered) for its own current LAN IP via `mac_deploy`'s
    // `wifi_status` action, the same call the Update App screen already
    // uses for its own display purposes. A minimal, direct request rather
    // than reusing `invoke()`/`deployWifiStatus()`: those go through
    // `resolveBaseURL`, which is what's calling this in the first place.
    private func discoverLANURL(funnelURL: URL, settings: AppSettings) async -> URL? {
        guard case .success(let token) = await sessionToken(baseURL: funnelURL, settings: settings) else { return nil }

        var request = URLRequest(url: funnelURL.appendingPathComponent("invoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "service_id": "mac_deploy",
            "params": ["action": "wifi_status", "project": "deepsink"],
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let ip = result["ip"] as? String, !ip.isEmpty else {
            return nil
        }
        return URL(string: "http://\(ip):\(Self.gatewayLANPort)")
    }

    private static func probe(_ baseURL: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func normalizedURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    // MARK: - DeepSink session login (the one credential for everything)
    //
    // Cached in memory only (never persisted — re-login on a cold launch
    // is one cheap call), refreshed a little ahead of its real ~1-week
    // expiry — in practice this never surfaces as a visible "log back in"
    // moment, since every call transparently re-authenticates from the
    // user_id/password already in Settings/Keychain whenever the cached
    // token is missing or stale.

    private var cachedSessionToken: String?
    private var cachedSessionTokenExpiry: Date?

    private func sessionToken(baseURL: URL, settings: AppSettings) async -> Result<String, RouterError> {
        if let cachedSessionToken, let cachedSessionTokenExpiry, cachedSessionTokenExpiry > Date() {
            return .success(cachedSessionToken)
        }

        let userID = settings.deepSinkUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = settings.deepSinkPassword
        guard !userID.isEmpty, !password.isEmpty else { return .failure(.notConfigured) }

        var request = URLRequest(url: baseURL.appendingPathComponent("deepsink/auth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userID, "password": password])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }
        guard (200...299).contains(http.statusCode),
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Double else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String)
                ?? "Sign-in failed — check the DeepSink user ID/password in Settings."
            return .failure(.loginFailed(message))
        }

        cachedSessionToken = accessToken
        cachedSessionTokenExpiry = Date().addingTimeInterval(expiresIn - 3600)
        return .success(accessToken)
    }

    // Lets Settings validate a user_id/password without waiting on some
    // other, unrelated session call to surface a login failure.
    func testSessionLogin(settings: AppSettings) async -> Result<Void, RouterError> {
        cachedSessionToken = nil
        cachedSessionTokenExpiry = nil
        let baseResult = await resolveBaseURL(settings: settings)
        guard case .success(let base) = baseResult else {
            if case .failure(let error) = baseResult { return .failure(error) }
            return .failure(.decoding)
        }
        switch await sessionToken(baseURL: base.url, settings: settings) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    // MARK: - Session store (server is the source of truth — see
    // DeepSinkSession's own doc comment)

    private static let sessionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Python's `datetime.isoformat()` (what ai-gateway's
        // session_store.py stamps every timestamp with) includes
        // fractional seconds and a "+00:00" offset rather than "Z" —
        // Foundation's plain `.iso8601` strategy doesn't parse that, so
        // this tries a fractional-seconds-aware formatter first and
        // falls back to a plain one, covering both shapes rather than
        // assuming one.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) { return date }
            if let date = withoutFractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return decoder
    }()

    private struct SessionListResponse: Decodable {
        var sessions: [DeepSinkSession]
    }

    func listSessions(settings: AppSettings) async -> Result<[DeepSinkSession], RouterError> {
        let result = await restRequest(method: "GET", path: "deepsink/sessions", body: nil, settings: settings, timeout: 30)
        switch result {
        case .success(let data):
            guard let wrapper = try? Self.sessionDecoder.decode(SessionListResponse.self, from: data) else {
                return .failure(.decoding)
            }
            return .success(wrapper.sessions)
        case .failure(let error):
            return .failure(error)
        }
    }

    func createSession(title: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions", body: ["title": title], settings: settings, timeout: 30))
    }

    func getSession(id: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "GET", path: "deepsink/sessions/\(id)", body: nil, settings: settings, timeout: 30))
    }

    // `fields` is a small allowlisted set server-side — title,
    // background_notes, duration_seconds, recording_incomplete — see
    // deepsink_sessions.py's patch_session.
    func updateSession(id: String, fields: [String: Any], settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "PATCH", path: "deepsink/sessions/\(id)", body: fields, settings: settings, timeout: 30))
    }

    func deleteSession(id: String, settings: AppSettings) async -> Result<Void, RouterError> {
        switch await restRequest(method: "DELETE", path: "deepsink/sessions/\(id)", body: nil, settings: settings, timeout: 30) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    // Doubles as the transcription call now — the server transcribes via
    // Whisper and persists the chunk + transcript blocks in one request,
    // so this needs a generous timeout (CPU-only Whisper on the Mac mini).
    func uploadChunk(
        sessionID: String,
        chunkIndex: Int,
        startOffsetSeconds: Double,
        durationSeconds: Double,
        audioData: Data,
        format: String = "m4a",
        settings: AppSettings
    ) async -> Result<DeepSinkSession, RouterError> {
        let body: [String: Any] = [
            "audio_base64": audioData.base64EncodedString(),
            "chunk_index": chunkIndex,
            "start_offset_seconds": startOffsetSeconds,
            "duration_seconds": durationSeconds,
            "format": format,
        ]
        return decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(sessionID)/chunks", body: body, settings: settings, timeout: 300))
    }

    // Codex over the accumulated transcript can take a while.
    func finishSession(id: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(id)/finish", body: nil, settings: settings, timeout: 180))
    }

    func regenerateNotes(id: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(id)/notes/regenerate", body: nil, settings: settings, timeout: 180))
    }

    func toggleActionItem(sessionID: String, itemID: String, isChecked: Bool, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "PATCH", path: "deepsink/sessions/\(sessionID)/action_items/\(itemID)", body: ["is_checked": isChecked], settings: settings, timeout: 30))
    }

    func addMarker(sessionID: String, offsetSeconds: Double, comment: String?, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        var body: [String: Any] = ["offset_seconds": offsetSeconds]
        if let comment { body["comment"] = comment }
        return decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(sessionID)/markers", body: body, settings: settings, timeout: 30))
    }

    // Diarizing a long meeting on CPU can take many minutes — matches
    // the gateway's own 1800s subprocess timeout for deepsink_diarize.
    func diarizeSession(id: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(id)/diarize", body: nil, settings: settings, timeout: 1800))
    }

    // Renaming isn't just cosmetic server-side — it's the roster
    // enrollment step (see speaker_roster.py): the server saves this
    // name against that speaker's voice embedding from this session, so
    // a later Detect Speakers run (this session or another) can
    // recognize the same voice automatically instead of defaulting back
    // to "Person N".
    func renameSpeaker(sessionID: String, speakerID: String, displayName: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "PATCH", path: "deepsink/sessions/\(sessionID)/speakers/\(speakerID)", body: ["display_name": displayName], settings: settings, timeout: 30))
    }

    // MARK: - Live preview (demand-driven — see live_preview.py's own doc)
    //
    // The phone polls `liveViewerCount` on a slow cadence while recording
    // and only starts calling `postLivePreview` (on a fast cadence) once
    // it sees a real number there — no point pushing on-device text to a
    // session nobody's watching in the web viewer's Transcript tab.

    func liveViewerCount(sessionID: String, settings: AppSettings) async -> Int {
        let result = await restRequest(method: "GET", path: "deepsink/sessions/\(sessionID)/live_preview/viewers", body: nil, settings: settings, timeout: 15)
        guard case .success(let data) = result,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return json["viewers"] as? Int ?? 0
    }

    func postLivePreview(sessionID: String, text: String, settings: AppSettings) async {
        _ = await restRequest(method: "POST", path: "deepsink/sessions/\(sessionID)/live_preview", body: ["text": text], settings: settings, timeout: 15)
    }

    private func decodeSessionResult(_ result: Result<Data, RouterError>) -> Result<DeepSinkSession, RouterError> {
        switch result {
        case .success(let data):
            guard let session = try? Self.sessionDecoder.decode(DeepSinkSession.self, from: data) else {
                return .failure(.decoding)
            }
            return .success(session)
        case .failure(let error):
            return .failure(error)
        }
    }

    // A short, recent transcript excerpt (typically the last few
    // minutes, from LiveAssistEngine's on-device recognition — not the
    // full accurate transcript) in, quick bullets + a spoken-style draft
    // out. Deliberately still stateless/on-device: Articulate never
    // touches the server session store, since it needs to work off text
    // that's fresher than whatever's landed there so far.
    func articulate(recentTranscript: String, backgroundNotes: String, settings: AppSettings) async -> Result<ArticulateResponse, RouterError> {
        let result = await invoke(
            serviceID: "deepsink_articulate",
            params: ["transcript": recentTranscript, "background_notes": backgroundNotes],
            settings: settings,
            timeout: 100
        )
        switch result {
        case .success(let json):
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let payload = try? JSONDecoder().decode(ArticulateResponse.self, from: data) else {
                return .failure(.decoding)
            }
            return .success(payload)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Deploy
    //
    // Reuses ai-gateway's existing `mac_deploy` service — the same
    // mechanism yt-run's DeployView already uses, just called directly
    // now instead of through ai-router. The `project` param is the one
    // addition that service needed server-side (it's otherwise hardcoded
    // to yt-run's own install_to_device.sh) — see ai-gateway's README.

    func deployWifiStatus(settings: AppSettings) async -> Result<RouterDeployWifiInfo, RouterError> {
        switch await invoke(serviceID: "mac_deploy", params: ["action": "wifi_status", "project": "deepsink"], settings: settings, timeout: 45) {
        case .success(let json):
            return .success(RouterDeployWifiInfo(
                ssid: json["ssid"] as? String,
                ip: json["ip"] as? String,
                proceedOK: json["proceed_ok"] as? Bool ?? false
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    func startDeploy(settings: AppSettings) async -> Result<Void, RouterError> {
        switch await invoke(serviceID: "mac_deploy", params: ["action": "start_deploy", "project": "deepsink"], settings: settings, timeout: 45) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    func deployStatus(settings: AppSettings) async -> Result<RouterDeployStatusInfo, RouterError> {
        switch await invoke(serviceID: "mac_deploy", params: ["action": "deploy_status", "project": "deepsink"], settings: settings, timeout: 45) {
        case .success(let json):
            let status = RouterDeployStatus(rawValue: (json["status"] as? String) ?? "") ?? .idle
            return .success(RouterDeployStatusInfo(status: status, logTail: json["log_tail"] as? String))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Transport (ai-gateway's `/invoke` envelope — stateless AI/action calls)

    private func invoke(
        serviceID: String,
        params: [String: Any],
        settings: AppSettings,
        timeout: TimeInterval
    ) async -> Result<[String: Any], RouterError> {
        let baseResult = await resolveBaseURL(settings: settings)
        guard case .success(let base) = baseResult else {
            if case .failure(let error) = baseResult { return .failure(error) }
            return .failure(.decoding)
        }

        let tokenResult = await sessionToken(baseURL: base.url, settings: settings)
        guard case .success(let token) = tokenResult else {
            if case .failure(let error) = tokenResult { return .failure(error) }
            return .failure(.decoding)
        }

        let body: [String: Any] = ["service_id": serviceID, "params": params]

        var request = URLRequest(url: base.url.appendingPathComponent("invoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return .failure(.cancelled) }
            // A LAN base URL that just went stale (walked out of range,
            // Mac asleep) shouldn't sit dead for the rest of the cache
            // TTL — drop it and retry this one call against Funnel before
            // giving up.
            if base.isLAN {
                cachedBase = nil
                cachedBaseTimestamp = nil
                return await invoke(serviceID: serviceID, params: params, settings: settings, timeout: timeout)
            }
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }
        if http.statusCode == 401 {
            cachedSessionToken = nil
            cachedSessionTokenExpiry = nil
            return .failure(.unauthorized)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }
        return .success((json["result"] as? [String: Any]) ?? json)
    }

    // MARK: - Transport (plain REST — /deepsink/sessions/*)

    private func restRequest(
        method: String,
        path: String,
        body: [String: Any]?,
        settings: AppSettings,
        timeout: TimeInterval
    ) async -> Result<Data, RouterError> {
        let baseResult = await resolveBaseURL(settings: settings)
        guard case .success(let base) = baseResult else {
            if case .failure(let error) = baseResult { return .failure(error) }
            return .failure(.decoding)
        }

        // The DeepSink user's own session token, NOT the client-credentials
        // token — see the "DeepSink session login" MARK above for why
        // these are two separate credentials.
        let tokenResult = await sessionToken(baseURL: base.url, settings: settings)
        guard case .success(let token) = tokenResult else {
            if case .failure(let error) = tokenResult { return .failure(error) }
            return .failure(.decoding)
        }

        var request = URLRequest(url: base.url.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return .failure(.cancelled) }
            if base.isLAN {
                cachedBase = nil
                cachedBaseTimestamp = nil
                return await restRequest(method: method, path: path, body: body, settings: settings, timeout: timeout)
            }
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }
        if http.statusCode == 401 {
            // The cached session token might have just expired (clock
            // skew, or the week finally ran out) — drop it so the next
            // call re-logs-in instead of repeating the same dead token.
            cachedSessionToken = nil
            cachedSessionTokenExpiry = nil
            return .failure(.unauthorized)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return .failure(.server(message ?? "Request failed (\(http.statusCode))."))
        }
        return .success(data)
    }
}
