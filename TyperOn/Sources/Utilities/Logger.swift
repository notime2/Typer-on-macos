// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import os

enum Log {
    static let app = Logger(subsystem: "com.typeron.app", category: "app")
    static let accessibility = Logger(subsystem: "com.typeron.app", category: "accessibility")
    static let ai = Logger(subsystem: "com.typeron.app", category: "ai")
    static let clipboard = Logger(subsystem: "com.typeron.app", category: "clipboard")
    static let modules = Logger(subsystem: "com.typeron.app", category: "modules")
    static let ui = Logger(subsystem: "com.typeron.app", category: "ui")
    static let hotkeys = Logger(subsystem: "com.typeron.app", category: "hotkeys")
}
