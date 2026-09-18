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
    case server(String)
    case decoding
    case cancelled

    var message: String {
        switch self {
        case .notConfigured: return "Set the router URL and token in Settings."
        case .invalidURL: return "The router URL in Settings doesn't look valid."
        case .network(let error): return "Couldn't reach the router: \(error.localizedDescription)"
        case .unauthorized: return "The router rejected this token — check it in Settings."
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
// `deepsink.transcribe` and `deepsink.notes` are NOT live on ai-router
// yet as of this app's first cut — see README's "Router contract" for
// the exact extension this needs server-side. Calls against them will
// fail with a clear, retryable error (unknown_service) until that lands;
// nothing here needs to change when it does.
final class RouterClient: ObservableObject {

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

    // Chunk audio is sent as base64 in the JSON body — simplest possible
    // contract for a router this small; worth revisiting as real
    // multipart only if chunk sizes ever make base64's ~33% overhead
    // matter (see README's math on why chunks stay small).
    func transcribe(
        chunkData: Data,
        chunkIndex: Int,
        startOffsetSeconds: Double,
        settings: AppSettings
    ) async -> Result<[TranscriptBlock], RouterError> {
        let options: [String: Any] = [
            "chunk_index": chunkIndex,
            "start_offset_seconds": startOffsetSeconds,
            "format": "m4a",
        ]
        let result = await invoke(
            service: "deepsink.transcribe",
            input: chunkData.base64EncodedString(),
            options: options,
            settings: settings,
            timeout: 180
        )
        switch result {
        case .success(let json):
            if let blocksJSON = json["blocks"] as? [[String: Any]] {
                let blocks = blocksJSON.compactMap { dict -> TranscriptBlock? in
                    guard let text = dict["text"] as? String else { return nil }
                    let start = dict["start"] as? Double ?? startOffsetSeconds
                    let end = dict["end"] as? Double ?? start
                    return TranscriptBlock(startSeconds: start, endSeconds: end, text: text)
                }
                return .success(blocks)
            }
            // Tolerates a simpler first router implementation that just
            // returns plain text with no block boundaries yet.
            if let text = (json["text"] as? String) ?? (json["output"] as? String) {
                return .success([TranscriptBlock(startSeconds: startOffsetSeconds, endSeconds: startOffsetSeconds, text: text)])
            }
            return .failure(.decoding)
        case .failure(let error):
            return .failure(error)
        }
    }

    func generateNotes(
        transcript: String,
        markers: [Marker],
        settings: AppSettings
    ) async -> Result<SessionNotesPayload, RouterError> {
        let markerHints = markers
            .sorted { $0.offsetSeconds < $1.offsetSeconds }
            .map { ["offset_seconds": $0.offsetSeconds, "comment": $0.comment ?? ""] as [String: Any] }
        let result = await invoke(
            service: "deepsink.notes",
            input: transcript,
            options: ["marker_hints": markerHints],
            settings: settings,
            timeout: 120
        )
        switch result {
        case .success(let json):
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let payload = try? JSONDecoder().decode(SessionNotesPayload.self, from: data) else {
                return .failure(.decoding)
            }
            return .success(payload)
        case .failure(let error):
            return .failure(error)
        }
    }

    // A short, recent transcript excerpt (typically the last few
    // minutes, from LiveAssistEngine's on-device recognition — not the
    // full accurate transcript) in, quick bullets + a spoken-style draft
    // out. Meant to be waited on mid-meeting, so this gets a generous
    // timeout for the same reason the deploy calls do — see that MARK's
    // comment for the measured Funnel latency this needs to absorb, on
    // top of however long Codex itself takes.
    func articulate(recentTranscript: String, settings: AppSettings) async -> Result<ArticulateResponse, RouterError> {
        let result = await invoke(service: "deepsink.articulate", input: recentTranscript, options: [:], settings: settings, timeout: 100)
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

    // MARK: - Transport

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

    private static func baseURL(from settings: AppSettings) -> URL? {
        var trimmed = settings.routerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }
}
