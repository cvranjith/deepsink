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
        case .notConfigured: return "Set the router URL and token in Settings."
        case .invalidURL: return "The router URL in Settings doesn't look valid."
        case .network(let error): return "Couldn't reach the router: \(error.localizedDescription)"
        case .unauthorized: return "The router rejected this token — check it in Settings."
        case .loginFailed(let message): return message
        case .server(let message): return message
        case .decoding: return "Got an unexpected response from the router."
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

// One small, testable surface for everything DeepSink calls ai-router
// for — ported from yt-run's AIGatewayClient, trimmed to just the
// token/`local.*` path (DeepSink never talks to ai-gateway directly, and
// never holds a provider API key — see requirement-deepsink-mobile.md
// section 2). Swapping the router URL, token, or adding a service ID
// never touches a View: every call site above this type only ever sees
// plain Swift types.
//
// Two request shapes live here side by side, each with its own auth:
//   - `invoke(...)` — the original `/v1/invoke` envelope
//     (`{service, input, options}` -> `{output}`), used by `articulate`
//     and the deploy calls, both genuinely stateless AI/action calls.
//     Authenticated with `settings.routerToken` (this Worker's shared
//     token) — the same credential every non-DeepSink app using
//     ai-router already has.
//   - `restRequest(...)` — plain REST against `/deepsink/sessions/*`
//     (ai-router proxies this straight through to ai-gateway's own
//     session store; see that project's README). This is real, stateful
//     CRUD, not an AI call, so it isn't forced into the invoke envelope —
//     method/path/body/status all pass through as-is, and every write
//     endpoint returns the full, current session. Authenticated with a
//     separate, human DeepSink user_id/password (see `sessionToken`
//     below) — that credential scopes data to one user's own folder on
//     the Mac mini, which a generic shared router token has no concept
//     of.
final class RouterClient: ObservableObject {

    // MARK: - DeepSink session login
    //
    // A separate, human user_id/password (ai-gateway's user_auth.py),
    // independent of `routerToken` — that one just says "this is a
    // legitimate app calling the router at all" (still used by `invoke`
    // below, unchanged); this one says "this is <user>'s own session
    // data" and scopes every /deepsink/sessions/* call to that user's
    // folder on the Mac mini. Cached in memory only (never persisted —
    // re-login on a cold launch is one cheap call), refreshed a little
    // ahead of its real ~1-week expiry, same pattern yt-run's
    // AIGatewayClient already uses for its own OAuth2 token caching.

    private var cachedSessionToken: String?
    private var cachedSessionTokenExpiry: Date?

    private func sessionToken(settings: AppSettings) async -> Result<String, RouterError> {
        if let cachedSessionToken, let cachedSessionTokenExpiry, cachedSessionTokenExpiry > Date() {
            return .success(cachedSessionToken)
        }

        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(settings.routerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notConfigured : .invalidURL)
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
        switch await sessionToken(settings: settings) {
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
    // so this needs the same generous timeout deepsink.transcribe used
    // to get for the same reason (CPU-only Whisper on the Mac mini).
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

    // Codex over the accumulated transcript can take a while — same
    // budget deepsink.notes used to get.
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
    // The server tracks `is_diarizing` itself, but since this call is a
    // single, directly-awaited HTTP request (not a start/poll pair), the
    // client doesn't need to poll separately — it already blocks until
    // the real answer comes back.
    func diarizeSession(id: String, settings: AppSettings) async -> Result<DeepSinkSession, RouterError> {
        decodeSessionResult(await restRequest(method: "POST", path: "deepsink/sessions/\(id)/diarize", body: nil, settings: settings, timeout: 1800))
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

    // Sends a deliberately unknown service ID and reads the *shape* of
    // the rejection, same trick as yt-run's AIGatewayClient: 401 means
    // the token itself was rejected; a 400 "unknown_service" means the
    // token was accepted and this got as far as service routing.
    func testConnection(settings: AppSettings) async -> Result<Void, RouterError> {
        switch await invoke(service: "__ping__", input: nil, options: [:], settings: settings, timeout: 15) {
        case .success:
            return .success(())
        case .failure(let error):
            if case .server(let message) = error, message.contains("unknown_service") {
                return .success(())
            }
            return .failure(error)
        }
    }

    // A short, recent transcript excerpt (typically the last few
    // minutes, from LiveAssistEngine's on-device recognition — not the
    // full accurate transcript) in, quick bullets + a spoken-style draft
    // out. Meant to be waited on mid-meeting, so this gets a generous
    // timeout for the same reason the deploy calls do — see that MARK's
    // comment for the measured Funnel latency this needs to absorb, on
    // top of however long Codex itself takes. Deliberately still
    // stateless/on-device: Articulate never touches the server session
    // store, since it needs to work off text that's fresher than
    // whatever's landed there so far.
    func articulate(recentTranscript: String, backgroundNotes: String, settings: AppSettings) async -> Result<ArticulateResponse, RouterError> {
        let result = await invoke(service: "deepsink.articulate", input: recentTranscript, options: ["background_notes": backgroundNotes], settings: settings, timeout: 100)
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
    // Reuses ai-router's existing `local.deploy` / ai-gateway's
    // `mac_deploy` — the exact mechanism yt-run's DeployView already
    // uses, not a new one. The `project` option is the one addition
    // that service needs server-side (it's currently hardcoded to yt-run's
    // own install_to_device.sh) — see README.
    //
    // 45s, not yt-run's original 20s: measured directly against the
    // deployed router, the Cloudflare Worker -> Tailscale Funnel -> Mac
    // mini round trip for a single wifi_status call varies anywhere from
    // ~2s to ~19s on its own (Funnel always relays rather than going
    // peer-to-peer, since the caller is outside the tailnet) - 20s left
    // almost no margin and could read as "stuck"/timing out on a slow
    // sample even though the call would have succeeded a second later.

    func deployWifiStatus(settings: AppSettings) async -> Result<RouterDeployWifiInfo, RouterError> {
        switch await invoke(service: "local.deploy", input: nil, options: ["action": "wifi_status", "project": "deepsink"], settings: settings, timeout: 45) {
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
        switch await invoke(service: "local.deploy", input: nil, options: ["action": "start_deploy", "project": "deepsink"], settings: settings, timeout: 45) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    func deployStatus(settings: AppSettings) async -> Result<RouterDeployStatusInfo, RouterError> {
        switch await invoke(service: "local.deploy", input: nil, options: ["action": "deploy_status", "project": "deepsink"], settings: settings, timeout: 45) {
        case .success(let json):
            let status = RouterDeployStatus(rawValue: (json["status"] as? String) ?? "") ?? .idle
            return .success(RouterDeployStatusInfo(status: status, logTail: json["log_tail"] as? String))
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Transport (/v1/invoke envelope — stateless AI/action calls)

    private func invoke(
        service: String,
        input: Any?,
        options: [String: Any],
        settings: AppSettings,
        timeout: TimeInterval
    ) async -> Result<[String: Any], RouterError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(settings.routerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notConfigured : .invalidURL)
        }
        let token = settings.routerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.notConfigured) }

        var body: [String: Any] = ["service": service, "options": options]
        if let input { body["input"] = input }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/invoke"))
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
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else { return .failure(.decoding) }
        if http.statusCode == 401 { return .failure(.unauthorized) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decoding)
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "Request failed (\(http.statusCode))."
            return .failure(.server(message))
        }
        return .success((json["output"] as? [String: Any]) ?? json)
    }

    // MARK: - Transport (plain REST — /deepsink/sessions/*)

    private func restRequest(
        method: String,
        path: String,
        body: [String: Any]?,
        settings: AppSettings,
        timeout: TimeInterval
    ) async -> Result<Data, RouterError> {
        guard let baseURL = Self.baseURL(from: settings) else {
            return .failure(settings.routerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notConfigured : .invalidURL)
        }
        // The DeepSink user's own session token, NOT `routerToken` — see
        // the "DeepSink session login" MARK above for why these are two
        // separate credentials.
        let tokenResult = await sessionToken(settings: settings)
        guard case .success(let token) = tokenResult else {
            if case .failure(let error) = tokenResult { return .failure(error) }
            return .failure(.decoding)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
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

    private static func baseURL(from settings: AppSettings) -> URL? {
        var trimmed = settings.routerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }
}
