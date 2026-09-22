import Foundation

/// Gets a Twilio access token from the `/token` Twilio Function.
enum TokenService {
    @MainActor static var isConfigured: Bool {
        URL(string: AppSettings.shared.twilioBaseURL)?.host != nil && !AppSettings.shared.twilioSecret.isEmpty
    }

    @MainActor static func fetch() async throws -> String {
        let settings = AppSettings.shared
        guard let base = URL(string: settings.twilioBaseURL.trimmingCharacters(in: .whitespaces)) else {
            throw TokenError.notConfigured
        }
        var request = URLRequest(url: base.appending(path: "token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["secret": settings.twilioSecret])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TokenError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    private struct TokenResponse: Decodable { let token: String }

    enum TokenError: LocalizedError {
        case notConfigured
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Twilio Functions URL and secret in Settings."
            case .rejected(401): "The token function rejected the secret."
            case .rejected(let code): "The token function returned \(code)."
            }
        }
    }
}
