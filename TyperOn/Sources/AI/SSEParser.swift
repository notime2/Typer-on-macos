// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct SSEParser {
    enum LineResult {
        case ignored
        case done
        case response(ChatResponse)
        case malformedData
    }

    static func parseLine(_ line: String) -> LineResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("data:") else { return .ignored }

        let data = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return .done }
        guard !data.isEmpty else { return .ignored }
        guard let jsonData = data.data(using: .utf8),
              let response = try? JSONDecoder().decode(ChatResponse.self, from: jsonData) else {
            return .malformedData
        }
        return .response(response)
    }

    static func parse(line: String) -> ChatResponse? {
        guard case .response(let response) = parseLine(line) else { return nil }
        return response
    }

    static func parseEvents(
        line: String,
        seenImagePayloads: inout Set<Data>
    ) -> [ChatStreamEvent] {
        var hasSeenText = false
        return parseEvents(
            line: line,
            seenImagePayloads: &seenImagePayloads,
            hasSeenText: &hasSeenText
        )
    }

    static func parseEvents(
        line: String,
        seenImagePayloads: inout Set<Data>,
        hasSeenText: inout Bool
    ) -> [ChatStreamEvent] {
        guard let response = parse(line: line) else { return [] }
        return parseEvents(
            response: response,
            seenImagePayloads: &seenImagePayloads,
            hasSeenText: &hasSeenText
        )
    }

    static func parseEvents(
        response: ChatResponse,
        seenImagePayloads: inout Set<Data>,
        hasSeenText: inout Bool
    ) -> [ChatStreamEvent] {

        var events: [ChatStreamEvent] = []

        for choice in response.choices {
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
                hasSeenText = true
            } else if !hasSeenText,
                      let content = choice.message?.content,
                      !content.isEmpty {
                events.append(.text(content))
                hasSeenText = true
            }

            if choice.delta?.hasMalformedImagesPayload == true {
                events.append(.invalidImage)
            }
            if choice.message?.hasMalformedImagesPayload == true {
                events.append(.invalidImage)
            }

            let images = (choice.delta?.images ?? []) + (choice.message?.images ?? [])
            for image in images {
                guard image.type == nil || image.type == "image_url",
                      let imageURL = image.imageURL else {
                    events.append(.invalidImage)
                    continue
                }

                let imageEvent = decodeImageDataURL(imageURL)
                if case .image(let data, _) = imageEvent {
                    guard seenImagePayloads.insert(data).inserted else { continue }
                }
                events.append(imageEvent)
            }
        }

        return events
    }

    private static func decodeImageDataURL(_ dataURL: String) -> ChatStreamEvent {
        guard dataURL.hasPrefix("data:"),
              let separatorRange = dataURL.range(of: ";base64,"),
              separatorRange.lowerBound > dataURL.startIndex else {
            return .invalidImage
        }

        let mimeTypeStart = dataURL.index(dataURL.startIndex, offsetBy: 5)
        let mimeType = String(dataURL[mimeTypeStart..<separatorRange.lowerBound]).lowercased()
        let base64Payload = String(dataURL[separatorRange.upperBound...])

        guard isValidImageMIMEType(mimeType),
              !base64Payload.isEmpty,
              let data = Data(base64Encoded: base64Payload),
              !data.isEmpty else {
            return .invalidImage
        }

        return .image(data: data, mimeType: mimeType)
    }

    private static func isValidImageMIMEType(_ mimeType: String) -> Bool {
        guard mimeType.hasPrefix("image/") else { return false }

        let subtype = mimeType.dropFirst("image/".count)
        guard !subtype.isEmpty else { return false }

        let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.+-")
        return subtype.unicodeScalars.allSatisfy(validCharacters.contains)
    }
}
