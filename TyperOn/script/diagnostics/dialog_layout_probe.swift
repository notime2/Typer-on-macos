// SPDX-License-Identifier: Apache-2.0
// Synthetic optimized diagnostic adapter, deliberately outside the app target.
import AppKit
import Darwin
import SwiftUI

@MainActor
private protocol LayoutProbeCounting: AnyObject {
    var layoutPasses: Int { get }
}

@MainActor
private final class LayoutProbeHost<Content: View>: NSHostingView<Content>, LayoutProbeCounting {
    var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

@MainActor
private final class WeakProbeView {
    weak var view: NSView?
    let label: String
    init(_ view: NSView, label: String) {
        self.view = view
        self.label = label
    }
}

@MainActor
private final class WeakProbeObject {
    weak var object: AnyObject?
    let label: String
    init(_ object: AnyObject, label: String) {
        self.object = object
        self.label = label
    }
}

/// Passive notifications and plain counters never invalidate the SwiftUI tree.
@MainActor
private final class GeometryProbe: NSObject {
    private var views: [WeakProbeView] = []
    private var counts: [ObjectIdentifier: Int] = [:]

    func attach(to host: NSView) {
        stop()
        // Traverse inside scroll views too: Markdown code and composer can nest.
        func allScrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(allScrolls)
        }
        for (index, scroll) in allScrolls(host).enumerated() {
            let role = scroll.documentView is NSTextView ? "composer" : "content"
            observe(scroll, label: "\(role)-\(index)-scroll")
            observe(scroll.contentView, label: "\(role)-\(index)-viewport")
            if let document = scroll.documentView {
                observe(document, label: "\(role)-\(index)-document")
            }
        }
    }

    private func observe(_ view: NSView, label: String) {
        let id = ObjectIdentifier(view)
        guard counts[id] == nil else { return }
        views.append(WeakProbeView(view, label: label))
        counts[id] = 0
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: view
        )
    }

    @objc private func frameChanged(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        counts[ObjectIdentifier(view), default: 0] += 1
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        views.removeAll()
        counts.removeAll()
    }

    var totalChanges: Int { counts.values.reduce(0, +) }

    func snapshot() -> [[String: Any]] {
        views.compactMap { reference in
            guard let view = reference.view else { return nil }
            return [
                "label": reference.label,
                "identity": String(describing: ObjectIdentifier(view)),
                "class": String(describing: type(of: view)),
                "frame": [view.frame.origin.x, view.frame.origin.y, view.frame.width, view.frame.height],
                "bounds": [view.bounds.origin.x, view.bounds.origin.y, view.bounds.width, view.bounds.height],
                "frame_changes": counts[ObjectIdentifier(view), default: 0]
            ]
        }
    }
}

@main
@MainActor
private enum DialogLayoutProbe {
    static func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func sample(_ name: String, panel: NSWindow, warmup: Double = 0.25) async {
        await pause(warmup)
        let geometry = GeometryProbe()
        if let host = panel.contentView { geometry.attach(to: host) }
        // Two independent quiet windows distinguish a transition from sustained work.
        for interval in 0..<2 {
            let host = panel.contentView as? any LayoutProbeCounting
            let startLayouts = host?.layoutPasses ?? 0
            let startFrames = geometry.totalChanges
            let startCPU = cpuSeconds()
            let start = ProcessInfo.processInfo.systemUptime
            await pause(0.5)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let cpu = cpuSeconds() - startCPU
            emit([
                "event": "sample", "stage": name, "interval": interval,
                "window": String(describing: ObjectIdentifier(panel)),
                "visible": panel.isVisible, "has_content": panel.contentView != nil,
                "elapsed_seconds": elapsed, "cpu_seconds": cpu,
                "cpu_percent_one_core": 100 * cpu / elapsed,
                "layout_passes": (host?.layoutPasses ?? 0) - startLayouts,
                "frame_changes": geometry.totalChanges - startFrames,
                "geometry": geometry.snapshot()
            ])
        }
        geometry.stop()
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            app.terminate(nil)
        }
        app.run()
    }

    static func run() async {
        let supplied = ProcessInfo.processInfo.environment
        emit([
            "event": "metadata", "evidence": "optimized diagnostic adapter; not exact Release proof",
            "revision": supplied["DIALOG_PROBE_REVISION"] ?? "UNKNOWN",
            "variant": supplied["DIALOG_PROBE_VARIANT"] ?? "UNKNOWN",
            "executable_sha256": supplied["DIALOG_PROBE_SHA256"] ?? "UNKNOWN",
            "executable": CommandLine.arguments[0],
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "displays": NSScreen.screens.map {
                ["frame": [$0.frame.width, $0.frame.height], "scale": $0.backingScaleFactor,
                 "maximum_fps": $0.maximumFramesPerSecond] as [String: Any]
            },
            "method": "native panels, passive hosting layout counters and frame notifications, getrusage process CPU; no bootstrap, AX observation, network or text capture"
        ])
        let suite = "DialogLayoutProbe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
              let replay = try? StreamReplayFixture(chunks: ["Synthetic completion."], intervalMilliseconds: 1) else {
            emit(["event": "error", "reason": "fixture initialization failed"])
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        // Construction disables keychain/catalog access. Do not call bootstrap().
        let environment = AppEnvironment(streamReplayFixture: replay, userDefaults: defaults)
        let chat = ChatViewModel(
            environment: environment,
            aiServiceProvider: { nil },
            cachedModelProvider: { _ in nil },
            modelResolver: { _, _ in nil },
            configuredModelIDProvider: { "diagnostic/text-only" }
        )
        let processing = ProcessingViewModel(
            environment: environment, aiServiceProvider: { nil }, replaceAction: { _, _ in .failed }
        )
        let chatPanel = ChatPanel()
        let processingPanel = ProcessingPanel()
        func chatHost() -> NSView {
            LayoutProbeHost(rootView: DialogThemeRoot { ChatView(viewModel: chat) }.defaultAppStorage(defaults))
        }
        func processingHost() -> NSView {
            LayoutProbeHost(rootView: DialogThemeRoot { ProcessingView(viewModel: processing) }.defaultAppStorage(defaults))
        }
        chatPanel.contentView = chatHost()
        chatPanel.showCentered(on: nil)
        await sample("chat-empty", panel: chatPanel)
        let markdown = (0..<35).map {
            "## Synthetic section \($0)\n\nA stable paragraph with **emphasis**, inline `code`, and wrapping text.\n\n- First item\n- Second item\n\n```swift\nlet value = 42\n```\n"
        }.joined(separator: "\n")
        chat.messages = [.init(role: .user, text: "Synthetic prompt"), .init(role: .assistant, text: markdown)]
        for lines in [1, 6, 12] {
            chat.inputText = (0..<lines).map { "Synthetic composer line \($0)" }.joined(separator: "\n")
            await sample("chat-filled-composer-\(lines)", panel: chatPanel)
        }
        chatPanel.setContentSize(NSSize(width: 420, height: 370))
        await sample("chat-resized-narrow", panel: chatPanel)
        chatPanel.setContentSize(ChatPanel.defaultContentSize)
        await sample("chat-restored-width-no-stream", panel: chatPanel)
        chat.isStreaming = true
        await sample("chat-streaming-indicator", panel: chatPanel)
        chat.isStreaming = false
        await sample("chat-streaming-stopped", panel: chatPanel)
        weak var temporaryHost = chatPanel.contentView
        chatPanel.orderOut(nil)
        await sample("chat-temporary-orderOut", panel: chatPanel)
        chatPanel.makeKeyAndOrderFront(nil)
        emit(["event": "temporary_restore", "same_host": chatPanel.contentView === temporaryHost])
        await sample("chat-restored", panel: chatPanel)
        chatPanel.dismiss()
        await sample("chat-dismissed", panel: chatPanel)

        processing.originalText = "Synthetic source"
        processing.resultText = markdown
        processing.userComment = "Synthetic refinement"
        processingPanel.contentView = processingHost()
        processingPanel.showCentered(on: nil)
        await sample("processing-filled", panel: processingPanel)
        processingPanel.dismiss()
        await sample("processing-dismissed", panel: processingPanel)

        var weakHosts: [WeakProbeView] = []
        var weakEditors: [WeakProbeObject] = []
        var weakCoordinators: [WeakProbeObject] = []
        func trackEditors(in view: NSView, label: String) {
            if let editor = view as? NSTextView {
                weakEditors.append(WeakProbeObject(editor, label: label))
                if let delegate = editor.delegate {
                    weakCoordinators.append(WeakProbeObject(delegate as AnyObject, label: label))
                }
            }
            for child in view.subviews { trackEditors(in: child, label: label) }
        }
        var chatRetainedAfterDismiss = 0
        var processingRetainedAfterDismiss = 0
        // Retain no strong host outside the window during lifecycle measurements.
        // Both fade-outs share the waiting interval. Set zero for layout-only A/B runs.
        let cycles = max(0, Int(supplied["DIALOG_PROBE_CYCLES"] ?? "50") ?? 50)
        for cycle in 0..<cycles {
            chatPanel.contentView = chatHost()
            processingPanel.contentView = processingHost()
            if let host = chatPanel.contentView { weakHosts.append(WeakProbeView(host, label: "chat-\(cycle)")) }
            if let host = processingPanel.contentView { weakHosts.append(WeakProbeView(host, label: "processing-\(cycle)")) }
            chatPanel.showCentered(on: nil)
            processingPanel.showCentered(on: nil)
            // Real run-loop mounting before dismiss, with no forced layout calls.
            await pause(0.02)
            if let host = chatPanel.contentView { trackEditors(in: host, label: "chat-\(cycle)") }
            if let host = processingPanel.contentView { trackEditors(in: host, label: "processing-\(cycle)") }
            chatPanel.dismiss()
            processingPanel.dismiss()
            await pause(0.24)
            if chatPanel.contentView != nil { chatRetainedAfterDismiss += 1 }
            if processingPanel.contentView != nil { processingRetainedAfterDismiss += 1 }
        }
        await pause(0.3)
        emit([
            "event": "lifecycle_cycles", "cycles_per_panel": cycles,
            "chat_retained_content_after_dismiss": chatRetainedAfterDismiss,
            "processing_retained_content_after_dismiss": processingRetainedAfterDismiss,
            "weak_hosts_alive": weakHosts.filter { $0.view != nil }.map(\.label),
            "tracked_editors": weakEditors.count,
            "weak_editors_alive": weakEditors.filter { $0.object != nil }.map(\.label),
            "tracked_coordinators": weakCoordinators.count,
            "weak_coordinators_alive": weakCoordinators.filter { $0.object != nil }.map(\.label),
            "chat_visible": chatPanel.isVisible, "processing_visible": processingPanel.isVisible
        ])
        chatPanel.orderOut(nil)
        processingPanel.orderOut(nil)
        chatPanel.contentView = nil
        processingPanel.contentView = nil
        await pause(0.3)
        emit([
            "event": "probe_cleanup",
            "weak_hosts_alive": weakHosts.filter { $0.view != nil }.map(\.label),
            "weak_editors_alive": weakEditors.filter { $0.object != nil }.map(\.label),
            "weak_coordinators_alive": weakCoordinators.filter { $0.object != nil }.map(\.label)
        ])
    }
}
