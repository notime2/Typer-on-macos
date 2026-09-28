// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum ModuleCategory: String, Codable, CaseIterable, Sendable {
    case correction
    case style
    case translation
    case summarization
    case explain
    case factCheck
    case generation
    case custom
}
