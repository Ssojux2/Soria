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

        return false
    }
}
