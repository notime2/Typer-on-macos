// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

/// `GET {baseURL}/models` on an OpenAI-compatible server: `{"data":[{"id":"..."}]}`.
/// Entries without a usable `id` are skipped rather than failing the whole list.
struct OpenAIModelListResponse: Decodable, Sendable {
    let modelIDs: [String]

    init(modelIDs: [String]) {
        self.modelIDs = modelIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([Entry].self, forKey: .data)

        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            guard let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        modelIDs = ids
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }

    private struct Entry: Decodable, Sendable {
        let id: String?

        private enum CodingKeys: String, CodingKey {
            case id
        }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                id = nil
                return
            }
            id = try? container.decodeIfPresent(String.self, forKey: .id)
        }
    }
}
