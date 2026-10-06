import Foundation

final class ChatGPTClient {
    static let shared = ChatGPTClient()
    private let base = URL(string: "https://api.openai.com/v1")!

    func availableModels() async throws -> [AvailableModel] {
        let token = try await ChatGPTAuthManager.shared.validAccessToken()
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CopilotError.service("Could not load the model list (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try JSONDecoder().decode(ModelCatalog.self, from: data).models
    }

    func streamResponse(model: String, input: String) async throws -> String {
        let token = try await ChatGPTAuthManager.shared.validAccessToken()
        var request = URLRequest(url: base.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [["role": "user", "content": input]],
            "store": false,
            "stream": true
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CopilotError.service(code == 401 ? "ChatGPT authorization expired. Sign in again." : "ChatGPT request failed (HTTP \(code)).")
        }
        var output = ""
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "response.output_text.delta", let delta = event["delta"] as? String { output += delta }
            if type == "response.failed" {
                let error = event["response"] as? [String: Any]
                let code = (error?["error"] as? [String: Any])?["code"] as? String ?? "unknown_error"
                throw CopilotError.service("ChatGPT could not complete this request (\(code)).")
            }
            if type == "response.incomplete" { throw CopilotError.streamIncomplete }
            if type == "response.completed" { completed = true }
        }
        guard completed else { throw CopilotError.streamIncomplete }
        return output
    }
}
