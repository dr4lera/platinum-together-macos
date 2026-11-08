import Foundation

// Graphics backend selection for the Wine runtime.
//
// - software: Mesa llvmpipe (CPU). The original, maximally compatible default.
// - metal:    WineMetalGL (OpenGL -> Metal, GPU). Opt-in, experimental.
//
// WineMetalGL is NOT bundled or redistributed. When the user enables the Metal
// backend, its pinned release is downloaded from the upstream project and
// installed into a writable location under Application Support. The launcher
// only orchestrates that install and points Wine at it; see WineMetalGL.swift.

enum GraphicsBackend: String {
    case software
    case metal

    /// Persisted choice, overridable via PT_GRAPHICS_BACKEND for testing.
    static var current: GraphicsBackend {
        if let env = ProcessInfo.processInfo.environment["PT_GRAPHICS_BACKEND"],
           let b = GraphicsBackend(rawValue: env) { return b }
        if let s = UserDefaults.standard.string(forKey: "graphicsBackend"),
           let b = GraphicsBackend(rawValue: s) { return b }
        return .software
    }

    static func set(_ b: GraphicsBackend) {
        UserDefaults.standard.set(b.rawValue, forKey: "graphicsBackend")
    }

    var displayName: String {
        switch self {
        case .software: return "Software (compatible)"
        case .metal:    return "GPU — WineMetalGL (experimental)"
        }
    }
}

// Pinned WineMetalGL release. Keep the version, URL and SHA-256 together as one
// tested tuple so an install can be verified and never silently drifts.
enum WineMetalGLPin {
    static let version = "3.9.0"
    static let arch = "x86_64"
    static var assetName: String { "winemetalgl-\(version)-\(arch)" }
    static var tarballURL: URL {
        URL(string: "https://github.com/metalsharp/WineMetalGL/releases/download/winemetalgl-\(version)/\(assetName).tar.gz")!
    }
    // SHA-256 of winemetalgl-3.9.0-x86_64.tar.gz, verified against the release's
    // SHA256SUMS.txt on 2026-11-08.
    static let tarballSHA256 = "1c17a7f412977250e22c2c36a003809350dee66be33679213a3cee1847d72513"
}

// A backend's deployment: the DLLs to write into the prefix system32, and the
// extra environment to apply. One source of truth so files and env can't drift.
struct BackendDeployment {
    // Source files to copy into <prefix>/drive_c/windows/system32, by filename.
    let prefixDLLs: [(name: String, source: URL)]
    // Environment overrides to merge in (and keys to remove).
    let setEnv: [String: String]
    let unsetEnv: [String]
}
