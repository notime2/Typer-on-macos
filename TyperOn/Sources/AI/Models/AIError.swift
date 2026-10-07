// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum AIError: LocalizedError {
    case noAPIKey
    case httpError(statusCode: Int, body: String)
    case cancelled
    case rateLimited
    case invalidAPIKey
    case insufficientCredits
    case modelNotFound(String)
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Open Settings (Cmd+,) to add your OpenRouter key."
        case .httpError(let code, let body):
            return "Server error (\(code)): \(body.prefix(200))"
        case .cancelled:
            return "Request cancelled."
        case .rateLimited:
            return "Rate limited by the API. Wait a moment and try again."
        case .invalidAPIKey:
            return "Invalid API key. Check your key in Settings (Cmd+,)."
        case .insufficientCredits:
            return "Insufficient credits on your OpenRouter account. Add credits at openrouter.ai."
        case .modelNotFound(let model):
            return "Model \"\(model)\" not found. Check model ID in Settings."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case .timeout:
            return "Request timed out. Try again or use a faster model."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .httpError:
            return true
        case .noAPIKey, .invalidAPIKey, .insufficientCredits, .modelNotFound, .invalidResponse, .cancelled:
            return false
        }
    }
}
