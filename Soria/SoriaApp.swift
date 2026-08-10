//
//  SoriaApp.swift
//  Soria
//
//  Created by Junseop So on 4/14/26.
//

import AppKit
import SwiftUI

@main
struct SoriaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Soria", id: "main") {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var fallbackMainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleMainWindowRecovery()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        if ensureMainWindowVisible() {
            return false
        }
        return true
    }

    private func scheduleMainWindowRecovery() {
        for delay in [0.0, 0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.ensureMainWindowVisible()
            }
        }
    }

    @discardableResult
    private func ensureMainWindowVisible() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { !$0.isMiniaturized && $0.isVisible }) ?? NSApp.windows.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return true
        }

        if NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) ||
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil) {
            return true
        }

        createFallbackMainWindow()
        return true
    }

    private func createFallbackMainWindow() {
        if let fallbackMainWindow {
            fallbackMainWindow.makeKeyAndOrderFront(nil)
            fallbackMainWindow.orderFrontRegardless()
            return
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1440, height: 900)
        let width = min(max(1280, visibleFrame.width * 0.82), visibleFrame.width)
        let height = min(max(800, visibleFrame.height * 0.82), visibleFrame.height)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        ).integral

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soria"
        window.minSize = NSSize(width: 1280, height: 800)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ContentView())
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        fallbackMainWindow = window
    }
}
