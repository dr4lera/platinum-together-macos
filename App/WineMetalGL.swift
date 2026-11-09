import Foundation
import CryptoKit

// WineMetalGL runtime integration.
//
// We do not bundle WineMetalGL. On first enable, we download its pinned signed
// release from upstream, verify the SHA-256, and lay the module + core into a
// writable WINEMETALGL_HOME under Application Support. Wine is pointed there via
// WINEDLLPATH at launch; the forwarding opengl32.dll goes into the prefix.
//
// Layout installed into WINEMETALGL_HOME:
//   lib/wine/x86_64-windows/winemetalgl.dll
//   lib/wine/i386-windows/winemetalgl.dll
//   lib/wine/x86_64-unix/winemetalgl.so
//   lib/wine/x86_64-unix/libwinemetalgl.dylib
// Forwarders copied into the prefix each launch (self-healing against updates):
//   system32/opengl32.dll  (forwards to winemetalgl.dll)
//   system32/winemetalgl.dll

enum WineMetalGL {

    static func home(_ supportHome: URL) -> URL {
        supportHome.appendingPathComponent("WineMetalGL")
    }

    /// The module+core have been installed into WINEMETALGL_HOME.
    static func isInstalled(_ supportHome: URL) -> Bool {
        let lib = home(supportHome).appendingPathComponent("lib/wine")
        let required = [
            "x86_64-windows/winemetalgl.dll",
            "x86_64-unix/winemetalgl.so",
            "x86_64-unix/libwinemetalgl.dylib",
        ]
        return required.allSatisfy { FileManager.default.fileExists(atPath: lib.appendingPathComponent($0).path) }
    }

    /// Download the pinned release, verify its hash, and install the module+core
    /// into WINEMETALGL_HOME. Throws on any failure (network, hash, layout).
    static func install(into supportHome: URL, progress: ((String) -> Void)? = nil) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("winemetalgl-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        progress?("Downloading WineMetalGL \(WineMetalGLPin.version)…")
        let tarball = tmp.appendingPathComponent("wmgl.tar.gz")
        try download(WineMetalGLPin.tarballURL, to: tarball)

        progress?("Verifying download…")
        let digest = try sha256(of: tarball)
        guard digest == WineMetalGLPin.tarballSHA256 else {
            throw err("WineMetalGL download failed verification (SHA-256 mismatch). Not installed.")
        }

        progress?("Installing…")
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", tmp.path])
        let module = tmp.appendingPathComponent("\(WineMetalGLPin.assetName)/module")
        guard fm.fileExists(atPath: module.path) else { throw err("WineMetalGL package missing module/ directory.") }

        let lib = home(supportHome).appendingPathComponent("lib/wine")
        for sub in ["x86_64-windows", "i386-windows", "x86_64-unix"] {
            try fm.createDirectory(at: lib.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let files = [
            "x86_64-windows/winemetalgl.dll",
            "i386-windows/winemetalgl.dll",
            "x86_64-unix/winemetalgl.so",
            "x86_64-unix/libwinemetalgl.dylib",
        ]
        for f in files {
            let src = module.appendingPathComponent(f)
            let dst = lib.appendingPathComponent(f)
            guard fm.fileExists(atPath: src.path) else { throw err("WineMetalGL package missing \(f).") }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        // Ad-hoc re-sign the unix binaries so Gatekeeper lets Wine load them.
        for f in ["x86_64-unix/winemetalgl.so", "x86_64-unix/libwinemetalgl.dylib"] {
            let p = lib.appendingPathComponent(f).path
            if (try? run("/usr/bin/codesign", ["--verify", p])) == nil {
                try run("/usr/bin/codesign", ["-f", "-s", "-", p])
            }
        }
        // Stash the two forwarder DLLs beside the module for the per-launch copy.
        let fwd = home(supportHome).appendingPathComponent("forwarders")
        try fm.createDirectory(at: fwd, withIntermediateDirectories: true)
        for n in ["opengl32.dll", "winemetalgl.dll"] {
            let src = module.appendingPathComponent("x86_64-windows/\(n)")
            let dst = fwd.appendingPathComponent(n)
            guard fm.fileExists(atPath: src.path) else { throw err("WineMetalGL package missing forwarder \(n).") }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        try writeManifest(supportHome)
        progress?("WineMetalGL \(WineMetalGLPin.version) installed.")
    }

    /// Deployment for the Metal backend: prefix forwarder DLLs + Wine env.
    /// `wineRoot` is the bundled (read-only) Wine; we prepend its own lib/wine
    /// dirs, then WINEMETALGL_HOME/lib/wine (parent dir form — the arch-correct
    /// PE + its .so companion resolve from there; arch-subdirs alone fail).
    static func deployment(supportHome: URL, wineRoot: URL) -> BackendDeployment {
        let fwd = home(supportHome).appendingPathComponent("forwarders")
        let wineLib = wineRoot.appendingPathComponent("lib/wine").path
        let extLib = home(supportHome).appendingPathComponent("lib/wine").path
        let dllPath = [
            "\(wineLib)/x86_64-windows",
            "\(wineLib)/i386-windows",
            wineLib,
            extLib,
        ].joined(separator: ":")
        return BackendDeployment(
            prefixDLLs: [
                ("opengl32.dll", fwd.appendingPathComponent("opengl32.dll")),
                ("winemetalgl.dll", fwd.appendingPathComponent("winemetalgl.dll")),
            ],
            setEnv: [
                "WINEDLLPATH": dllPath,
                "WINEMETALGL_HOME": home(supportHome).path,
                "WINEMETALGL_SETTINGS": "0",   // ignore any user-wide WineMetalGL settings file
            ],
            unsetEnv: ["GALLIUM_DRIVER", "MESA_SHADER_CACHE_DIR", "LP_NUM_THREADS"]
        )
    }

    // MARK: - helpers

    private static func writeManifest(_ supportHome: URL) throws {
        let m: [String: Any] = [
            "winemetalgl_version": WineMetalGLPin.version,
            "winemetalgl_sha256": WineMetalGLPin.tarballSHA256,
            "installed_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: home(supportHome).appendingPathComponent("runtime-manifest.json"), options: .atomic)
    }

    private static func download(_ url: URL, to dst: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var fetchErr: Error?
        let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
            defer { sem.signal() }
            if let error { fetchErr = error; return }
            guard let tmpURL else { fetchErr = err("No data downloaded."); return }
            do {
                if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                try FileManager.default.moveItem(at: tmpURL, to: dst)
            } catch { fetchErr = error }
        }
        task.resume()
        sem.wait()
        if let fetchErr { throw fetchErr }
    }

    private static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if p.terminationStatus != 0 {
            throw err("\(tool) failed: \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "WineMetalGL", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
