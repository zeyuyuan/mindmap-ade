import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    static let resourceBundle: Bundle = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .module }
        // Packaged macOS apps put resources in Contents/Resources. The
        // SwiftPM native accessor can otherwise fall back to the build tree.
        let name = "GhosttyKit_GhosttyTerminal.bundle"
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
            let bundle = Bundle(url: url)
        else { fatalError("Missing packaged resource bundle: \(name)") }
        return bundle
    }()

    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        resourceBundle.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        resourceBundle.url(forResource: "terminfo", withExtension: nil)
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
