// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

@MainActor
protocol PanelVisibilityProvider: AnyObject {
    var isProcessingVisible: Bool { get }
    var isProcessingActive: Bool { get }
    var isChatVisible: Bool { get }
}
