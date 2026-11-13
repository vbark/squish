import AppKit
import SwiftUI

@main
struct SquishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(model)
        } label: {
            Image(systemName: model.isPaused ? "pause.circle" : "arrow.down.right.and.arrow.up.left")
                .accessibilityLabel(model.isPaused ? "Squish, paused" : "Squish")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
        }
    }
}

enum Theme {
    /// Sky blue from the app icon; lighter in dark mode to keep contrast on dark materials.
    static let brand = Color(nsColor: NSColor(name: "brand") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1)  // #38BDF8
            : NSColor(srgbRed: 0.01, green: 0.52, blue: 0.78, alpha: 1)  // #0284C7
    })
}

// shortcut: in the macOS 27 SDK `@State` is a macro whose plugin ships only with Xcode, so Command Line
// Tools builds fail. A typealias resolves to the property wrapper instead. Swap back to `@State` once
// the project is built with Xcode only.
typealias ViewState<Value> = SwiftUI.State<Value>
