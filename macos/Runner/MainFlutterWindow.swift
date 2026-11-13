import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    if let screen = NSScreen.main {
      self.setFrame(screen.visibleFrame, display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Every other window (the code editor, a table in its own window) runs
    // its own Flutter engine, which starts with its controls hidden too.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { _ in
      MainFlutterWindow.showControlsToAccessibilityClients()
    }
    MainFlutterWindow.showControlsToAccessibilityClients()

    super.awakeFromNib()
  }

  /// Flutter shows its controls to accessibility clients other than
  /// VoiceOver (automation tools, agents driving the app) only once the
  /// window says a screen reader started. key_flow names every command's
  /// control and gives its shortcut as the value, so this makes them
  /// readable from outside. Every running engine listens for this, so
  /// posting it again for a new window leaves the others as they are.
  static func showControlsToAccessibilityClients() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: NSNotification.Name("NSApplicationDidChangeAccessibilityEnhancedUserInterfaceNotification"),
        object: NSApp, userInfo: ["AXEnhancedUserInterface": true])
    }
  }
}
