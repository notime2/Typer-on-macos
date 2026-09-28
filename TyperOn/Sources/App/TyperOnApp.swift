// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@main
struct TyperOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
