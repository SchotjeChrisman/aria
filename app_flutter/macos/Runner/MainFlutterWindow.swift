import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let frameName = NSWindow.FrameAutosaveName("AriaMainWindow")

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Frame must be set AFTER contentViewController — assigning it resizes the
    // window to the view's fitting size. First launch opens near-full-screen
    // (visibleFrame = screen minus menu bar and Dock); afterwards macOS restores
    // whatever the user resized to.
    // ponytail: setFrameAutosaveName is the native persistence — no window
    // manager plugin, no prefs key, no Dart-side code.
    self.contentViewController = flutterViewController
    if !self.setFrameUsingName(Self.frameName), let screen = self.screen ?? NSScreen.main {
      self.setFrame(screen.visibleFrame, display: true)
    }
    _ = self.setFrameAutosaveName(Self.frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
