// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("com.typeron.hotkeyChanged")
    static let autoDetectSelectionChanged = Notification.Name("com.typeron.autoDetectSelectionChanged")
    static let selectionTriggerStyleChanged = Notification.Name("com.typeron.selectionTriggerStyleChanged")
    static let openChatRequested = Notification.Name("com.typeron.openChatRequested")
}
