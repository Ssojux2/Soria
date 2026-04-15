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
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleMainWindowRecovery()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ensureMainWindowVisible()
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

    private func ensureMainWindowVisible() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard
            let fileMenuItem = NSApp.mainMenu?.item(withTitle: "File"),
            let newWindowItem = fileMenuItem.submenu?.items.first(where: { $0.title == "New Window" }),
            let action = newWindowItem.action
        else {
            return
        }

        NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first(where: { !$0.isMiniaturized })?.makeKeyAndOrderFront(nil)
        }
    }
}
