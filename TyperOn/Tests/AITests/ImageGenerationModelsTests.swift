// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test
func testImageGenerationRequestEncodesDocumentedInputReferences() throws {
    let dataURL = "data:image/png;base64,AQIDBA=="
    let request = ImageGenerationRequest(
        model: "vendor/image-model",
        prompt: "Generate a variation",
        inputReferences: [ImageGenerationInputReference(imageURL: dataURL)]
    )

    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let references = try #require(object["input_references"] as? [[String: Any]])
    let reference = try #require(references.first)
    let imageURL = try #require(reference["image_url"] as? [String: Any])

    #expect(object["model"] as? String == "vendor/image-model")
    #expect(object["prompt"] as? String == "Generate a variation")
    #expect(references.count == 1)
    #expect(reference["type"] as? String == "image_url")
    #expect(imageURL["url"] as? String == dataURL)
}

@Test
func testImageGenerationRequestOmitsEmptyInputReferences() throws {
    let request = ImageGenerationRequest(
        model: "vendor/image-model",
        prompt: "Generate an icon",
        inputReferences: []
    )

    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["input_references"] == nil)
}

@Test
func testImagesURLRequestUsesResolvedModelAndImagesEndpoint() throws {
    let service = AIEndpointService(apiKey: "constructor-key")
    let request = ImageGenerationRequest(
        model: "stale-model",
        prompt: "Generate an icon",
        inputReferences: [
            ImageGenerationInputReference(imageURL: "data:image/png;base64,AQID")
        ]
    )
    let config = ResolvedAIConfig(
        apiKey: "resolved-key",
        model: "resolved/image-model",
        temperature: 0.2,
        maxTokens: 4096
    )

    let urlRequest = try service.buildImagesURLRequest(for: request, config: config)
    let body = try #require(urlRequest.httpBody)
    let decodedRequest = try JSONDecoder().decode(ImageGenerationRequest.self, from: body)

    #expect(urlRequest.url?.absoluteString == "https://openrouter.ai/api/v1/images")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer resolved-key")
    #expect(urlRequest.value(forHTTPHeaderField: "X-Title") == "Typer On")
    #expect(urlRequest.value(forHTTPHeaderField: "HTTP-Referer") == "https://github.com/notime2/Typer-on-macos")
    #expect(decodedRequest.model == "resolved/image-model")
    #expect(decodedRequest.prompt == "Generate an icon")
    #expect(decodedRequest.inputReferences == request.inputReferences)
}

@Test
func testImagesResponseDecodesAllImagesAndInfersMissingMediaType() throws {
    let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let data = Data(
        #"{"data":[{"b64_json":"AQID","media_type":"IMAGE/JPEG"},{"b64_json":"\#(pngBase64)"}]}"#.utf8
    )

    let result = try AIEndpointService.decodeImageGenerationResult(from: data)

    #expect(result.images == [
        GeneratedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg"),
        GeneratedImage(data: Data(base64Encoded: pngBase64)!, mimeType: "image/png")
    ])
    #expect(result.invalidImageCount == 0)
}

@Test
func testImagesResponseRejectsMissingMediaTypeWhenBytesAreUndetectable() throws {
    let data = Data(
        #"{"data":[{"b64_json":"AQID"}]}"#.utf8
    )

    let result = try AIEndpointService.decodeImageGenerationResult(from: data)

    #expect(result.images.isEmpty)
    #expect(result.invalidImageCount == 1)
}

@Test
func testImagesResponseKeepsValidSiblingAndCountsMalformedEntries() throws {
    let data = Data(
        #"{"data":[{"b64_json":"AQID","media_type":"image/png"},{"b64_json":"%%%","media_type":"image/png"},{"b64_json":"BAUG","media_type":"text/plain"},{"media_type":"image/png"}]}"#.utf8
    )

    let result = try AIEndpointService.decodeImageGenerationResult(from: data)

    #expect(result.images == [
        GeneratedImage(data: Data([1, 2, 3]), mimeType: "image/png")
    ])
    #expect(result.invalidImageCount == 3)
}

@Test
func testImagesResponseRejectsEmptyDataArray() {
    let data = Data(
        #"{"data":[]}"#.utf8
    )

    #expect(throws: AIError.self) {
        try AIEndpointService.decodeImageGenerationResult(from: data)
    }
}
