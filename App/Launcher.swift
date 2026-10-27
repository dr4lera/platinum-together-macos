import AppKit
import Darwin
import SwiftUI
import AVFoundation
import Security
import UniformTypeIdentifiers

private let assetRoot = Bundle.main.resourceURL!.appendingPathComponent("Assets")

final class LauncherModel: ObservableObject {
    @Published var page = "Game"
    @Published var account = ""
    @Published var gameDataInstalled = false
    @Published var gameDataVersion = ""
    @Published var installFraction = 0.0
    @Published var gameBusy = false
    @Published var gameMessage = ""
    @Published var isPlaying = false
    private var resetTimer: Timer?
    private var resetRestarts: [Date] = []
    private var launchPending = false
    private var pendingGamePath: String?
    private var pendingGameCredential: Data?
    @Published var accountMessage = ""
    var gameCredentialExists: Bool {
        let users=supportHome.appendingPathComponent("WinePrefix/drive_c/users")
        return ((try? FileManager.default.contentsOfDirectory(at:users,includingPropertiesForKeys:nil)) ?? []).contains {
            FileManager.default.fileExists(atPath:$0.appendingPathComponent("AppData/Local/PlatinumTogether/online-sign-in.dat").path)
        }
    }
    func connectGameAccount() {
        guard !isPlaying else { error="Save and close the game before connecting its account.";return }
        guard !account.isEmpty else { signIn();return }
        guard !gameCredentialExists else { accountMessage="A game sign-in is already saved. Manage it from the game's account menu.";return }
        launchPending=true;gameBusy=true;pendingGamePath=nil;accountMessage="Connecting your game account…";send("link-game")
    }

    private var gameProcess: Process?
    private var gameLog: FileHandle?
    var supportHome: URL {
        ProcessInfo.processInfo.environment["PT_LAUNCHER_HOME"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Platinum Together")
    }
    var wineRoot: URL { Bundle.main.resourceURL!.appendingPathComponent("Compatibility/Wine") }
    var canPlay: Bool { gameDataInstalled && FileManager.default.isExecutableFile(atPath:wineRoot.appendingPathComponent("bin/wine").path) }
    private static func resetRequest(_ root:URL, excluding:Set<String>) -> Date? {
        let fm=FileManager.default
        let logs=root.appendingPathComponent("logs")
        let fresh=((try? fm.contentsOfDirectory(at:logs,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []).filter {!excluding.contains($0.lastPathComponent) && $0.pathExtension=="log"}
        for log in fresh {
            guard let modified=(try? log.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate,
                  let handle=try? FileHandle(forReadingFrom:log) else {continue}
            defer {try? handle.close()}
            guard let end=try? handle.seekToEnd() else {continue}
            try? handle.seek(toOffset:end>8192 ? end-8192 : 0)
            let tail=String(decoding:(try? handle.read(upToCount:8192)) ?? Data(),as:UTF8.self)
            if let last=tail.split(whereSeparator:{$0.isNewline}).last,
               last.contains("RESET"),last.contains("going back to the last save") {return modified}
        }
        return nil
    }
    private func restartAfterReset() {
        resetRestarts=resetRestarts.filter {Date().timeIntervalSince($0)<60}
        guard resetRestarts.count<3 else {gameMessage="Soft reset stopped after repeated retries. Close and reopen the game from Play.";return}
        resetRestarts.append(Date());gameMessage="Returning to your last save…"
        DispatchQueue.main.asyncAfter(deadline:.now()+1) {self.playGame()}
    }
    private static func backupBeforeReset(_ root:URL, home:URL) throws {
        let fm=FileManager.default
        let backup=home.appendingPathComponent("Backups/before-soft-reset-"+UUID().uuidString)
        try fm.createDirectory(at:backup,withIntermediateDirectories:true)
        for item in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            let name=item.lastPathComponent
            if name=="worlds" || name.hasPrefix("save") && name.hasSuffix(".bin") || name.hasPrefix("world") && (name.hasSuffix(".txt") || name.hasSuffix(".ini")) || name=="quick-restart.ini" {
                try fm.copyItem(at:item,to:backup.appendingPathComponent(name))
            }
        }
    }
    private static func helperResponse(_ handle:FileHandle) throws -> Data {
        // Wine services may inherit stdout and outlive the helper; read its one-line reply, not EOF.
        defer {try? handle.close()}
        var result=Data()
        while result.count<4096 {
            guard let byte=try handle.read(upToCount:1),!byte.isEmpty else {break}
            if byte[0]==10 {break}
            result.append(byte)
        }
        return result
    }
    func launchCompatibilityGame(_ rootPath:String, startGame:Bool = true) {
        guard !isPlaying else { return }
        gameBusy=true; gameMessage="Preparing the game runtime…"; installFraction=0
        let prefix=supportHome.appendingPathComponent("WinePrefix")
        let runtime=wineRoot; let resources=Bundle.main.resourceURL!
        var credential=pendingGameCredential;pendingGameCredential=nil
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let fm=FileManager.default
                try fm.createDirectory(at:prefix,withIntermediateDirectories:true)
                var environment=ProcessInfo.processInfo.environment
                environment["WINEPREFIX"]=prefix.path; environment["WINEDEBUG"]="-all"
                environment["WINEDLLOVERRIDES"]="opengl32=n;winemenubuilder.exe=d;mscoree,mshtml=d"
                environment["GALLIUM_DRIVER"]="llvmpipe"; environment["MESA_SHADER_CACHE_DIR"]="C:\\MesaShaderCache"; environment["LP_NUM_THREADS"]="8"
                environment["MVK_CONFIG_LOG_LEVEL"]="0"
                let logDir=self.supportHome.appendingPathComponent("Logs"); try fm.createDirectory(at:logDir,withIntermediateDirectories:true)
                let logURL=logDir.appendingPathComponent("compatibility.log")
                _=fm.createFile(atPath:logURL.path,contents:Data())
                let log=try FileHandle(forWritingTo:logURL)
                if !fm.fileExists(atPath:prefix.appendingPathComponent("system.reg").path) {
                    let boot=Process();boot.executableURL=runtime.appendingPathComponent("bin/wineboot");boot.arguments=["-u"];var bootEnvironment=environment;bootEnvironment["WINEDLLOVERRIDES"]="winemenubuilder.exe=d;mscoree,mshtml=d";boot.environment=bootEnvironment;boot.standardOutput=log;boot.standardError=log
                    try boot.run();boot.waitUntilExit()
                    guard boot.terminationStatus==0 else { throw NSError(domain:"Launcher",code:3,userInfo:[NSLocalizedDescriptionKey:"The compatibility runtime couldn't initialize. Check that Rosetta is installed."]) }
                }
                let runningCheck=Process();runningCheck.executableURL=runtime.appendingPathComponent("bin/wine")
                runningCheck.arguments=[resources.appendingPathComponent("Compatibility/GameSessionHelper.exe").path,"--running"];runningCheck.environment=environment
                let runningOutput=Pipe();runningCheck.standardOutput=runningOutput;runningCheck.standardError=FileHandle.nullDevice
                try runningCheck.run();let runningBytes=try Self.helperResponse(runningOutput.fileHandleForReading);runningCheck.waitUntilExit()
                guard runningCheck.terminationStatus==0,let runningResult=try? JSONSerialization.jsonObject(with:runningBytes) as? [String:Any],runningResult["ok"] as? Bool == true else {throw NSError(domain:"Launcher",code:5,userInfo:[NSLocalizedDescriptionKey:"Couldn't check the game runtime. Open Logs in Settings for details."])}
                guard runningResult["running"] as? Bool != true else {throw NSError(domain:"Launcher",code:6,userInfo:[NSLocalizedDescriptionKey:"The game is already running. Switch to its window, or save and close it before starting again."])}
                let system=prefix.appendingPathComponent("drive_c/windows/system32")
                for name in ["opengl32.dll","libgallium_wgl.dll"] {
                    let destination=system.appendingPathComponent(name)
                    let bytes=try Data(contentsOf:resources.appendingPathComponent("Compatibility/Mesa/"+name))
                    try bytes.write(to:destination,options:.atomic)
                }
                if var bytes=credential {
                    defer { bytes.resetBytes(in:0..<bytes.count);credential=nil }
                    let helper=Process();helper.executableURL=runtime.appendingPathComponent("bin/wine")
                    helper.arguments=[resources.appendingPathComponent("Compatibility/GameSessionHelper.exe").path,"--import"]
                    helper.environment=environment
                    let incoming=Pipe(),outgoing=Pipe();helper.standardInput=incoming;helper.standardOutput=outgoing;helper.standardError=FileHandle.nullDevice
                    try helper.run();try incoming.fileHandleForWriting.write(contentsOf:bytes);try incoming.fileHandleForWriting.close()
                    let result=try Self.helperResponse(outgoing.fileHandleForReading);helper.waitUntilExit()
                    guard helper.terminationStatus==0,let response=try? JSONSerialization.jsonObject(with:result) as? [String:Any],response["ok"] as? Bool == true else { throw NSError(domain:"Launcher",code:4,userInfo:[NSLocalizedDescriptionKey:"The game account could not be saved. Close the game and try Connect game account again."]) }
                    DispatchQueue.main.async { self.accountMessage="Game account connected. Start the game to sign in." }
                }
                if !startGame {
                    try log.close()
                    DispatchQueue.main.async {self.launchPending=false;self.gameBusy=false;self.gameMessage="Game account connected. Choose Play."}
                    return
                }
                let gameRoot=URL(fileURLWithPath:rootPath)
                let defaultsMarker=self.supportHome.appendingPathComponent("compatibility-graphics-v1")
                if !fm.fileExists(atPath:defaultsMarker.path) {
                    let settings=gameRoot.appendingPathComponent("platinum-pc.ini")
                    var lines=((try? String(contentsOf:settings,encoding:.utf8)) ?? "").components(separatedBy:.newlines)
                    if fm.fileExists(atPath:settings.path) { try? fm.copyItem(at:settings,to:gameRoot.appendingPathComponent("platinum-pc.before-mac-compat.ini")) }
                    for (key,value) in [("potato_graphics","1"),("graphics_modern","0"),("fullscreen","0")] {
                        if let index=lines.firstIndex(where:{$0.hasPrefix(key+"=")}) {lines[index]=key+"="+value}
                        else {lines.append(key+"="+value)}
                    }
                    try lines.joined(separator:"\n").write(to:settings,atomically:true,encoding:.utf8)
                    try Data("low graphics defaults applied once\n".utf8).write(to:defaultsMarker,options:.atomic)
                }
                let previousLogs=Set((try? fm.contentsOfDirectory(atPath:gameRoot.appendingPathComponent("logs").path)) ?? [])
                let process=Process();process.executableURL=runtime.appendingPathComponent("bin/wine")
                process.arguments=["Platinum.exe"];process.currentDirectoryURL=URL(fileURLWithPath:rootPath);process.environment=environment
                process.standardOutput=log;process.standardError=log
                process.terminationHandler={ [weak self] process in
                    try? log.close()
                    DispatchQueue.main.async { guard let self else {return};self.resetTimer?.invalidate();self.resetTimer=nil;self.isPlaying=false;self.gameBusy=false;self.gameProcess=nil
                        if Self.resetRequest(gameRoot,excluding:previousLogs) != nil {self.restartAfterReset();return}
                        self.gameMessage=process.terminationStatus==0 ? "Game closed." : "Game exited (code \(process.terminationStatus)). Open Logs in Settings for details."
                        self.updateMedia()
                    }
                }
                try process.run()
                DispatchQueue.main.async {
                    guard process.isRunning else {return}
                    self.gameProcess=process;self.gameLog=log;self.isPlaying=true;self.launchPending=false;self.gameBusy=false;self.gameMessage="Game running in compatibility mode.";self.audio?.pause();self.video.pause()
                    self.resetTimer?.invalidate()
                    self.resetTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self,weak process] timer in
                        guard let self,let process,process.isRunning else {timer.invalidate();return}
                        guard let requested=Self.resetRequest(gameRoot,excluding:previousLogs),Date().timeIntervalSince(requested)>8 else {return}
                        timer.invalidate();self.gameMessage="Completing the requested soft reset…"
                        DispatchQueue.global(qos:.userInitiated).async {
                            do {try Self.backupBeforeReset(gameRoot,home:self.supportHome)}
                            catch {DispatchQueue.main.async {self.gameMessage="Couldn't back up the reset state: \(error.localizedDescription)"};return}
                            guard process.isRunning else {return}
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline:.now()+3) {
                                if process.isRunning {Darwin.kill(process.processIdentifier,SIGKILL)}
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.launchPending=false;self.gameBusy=false;self.gameMessage="Couldn't start the game: \(error.localizedDescription)" }
            }
        }
    }
    func openGameFolder() { NSWorkspace.shared.open(supportHome.appendingPathComponent("GameData")) }
    func openLogs() { let url=supportHome.appendingPathComponent("Logs");try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);NSWorkspace.shared.open(url) }
    func installGame() {
        let panel=NSOpenPanel(); panel.title="Install or repair Platinum Together"; panel.message="Choose your own US Platinum .nds ROM. The launcher downloads and verifies the current game, then imports the ROM data locally."; panel.prompt="Install Game"; panel.allowedContentTypes=[UTType(filenameExtension:"nds") ?? .data]; panel.directoryURL=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first; panel.canChooseFiles=true; panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let source=panel.url else { return }
        guard source.pathExtension.lowercased()=="nds" else { gameMessage="Choose your US Platinum .nds ROM.";return }
        guard !account.isEmpty else { gameMessage="Sign in first, then choose Install Game again."; signIn(); return }
        gameBusy=true; installFraction=0; gameMessage="Checking your ROM…"; send("install",values:["rom":source.path])
    }
    func playGame() {
        guard !isPlaying && !gameBusy else { gameMessage="The game is already running or being prepared.";return }
        guard gameDataInstalled else {gameMessage="Choose Install Game first.";return}
        launchPending=true;gameBusy=true;gameMessage="Verifying game files…";send("prepare-play")
    }
    func checkUpdates() {
        if account.isEmpty { gameMessage="Sign in to check the beta release."; signIn(); return }
        send("updates"); gameMessage="Checking the signed game release…"
    }
    @Published var status = "Checking server…"
    @Published var players: Int?
    @Published var error = ""
    @Published var busy = false
    @Published var ready = false
    @Published var showSignIn = false
    @Published var username = ""
    @Published var code = ""
    @Published var pending = false
    @Published var channelURL = ""
    @Published var loginCommand = ""
    @Published var slash = false
    @Published var expiry = Date()
    @Published var posts: [[String: Any]] = []
    @Published var scene = UserDefaults.standard.string(forKey: "scene") ?? "canalave" { didSet { UserDefaults.standard.set(scene, forKey: "scene"); updateMedia() } }
    @Published var motion = UserDefaults.standard.object(forKey: "motion") as? Bool ?? true { didSet { UserDefaults.standard.set(motion, forKey: "motion"); updateMedia() } }
    @Published var muted = UserDefaults.standard.object(forKey: "muted") as? Bool ?? true { didSet { UserDefaults.standard.set(muted, forKey: "muted"); updateMedia() } }
    let video = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var audio: AVAudioPlayer?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var timer: Timer?
    private var suppressAccountSheet = false
    private let keychainService = "online.platinumtogether.mac.launcher"

    init() {
        video.isMuted = true
        if let sound = try? AVAudioPlayer(contentsOf: assetRoot.appendingPathComponent("pt_launcher.wav")) { audio = sound; sound.numberOfLoops = -1; sound.volume = 0.25 }
        updateMedia()
        startBridge()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.ready, !self.busy else { return }; self.send("status", busy: false)
        }
    }
    func updateMedia() {
        video.pause(); looper = nil; video.removeAllItems()
        if motion {
            let item = AVPlayerItem(url: assetRoot.appendingPathComponent("\(scene).mp4"))
            looper = AVPlayerLooper(player: video, templateItem: item); video.play()
        }
        if muted { audio?.pause() } else { audio?.play() }
    }
    func startBridge() {
        let p = Process(); let incoming = Pipe(); let outgoing = Pipe()
        p.executableURL = Bundle.main.resourceURL!.appendingPathComponent("Bridge/PlatinumBridge")
        p.standardInput = incoming; p.standardOutput = outgoing; p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment; env["DOTNET_EnableDiagnostics"] = "0"; p.environment = env
        input = incoming.fileHandleForWriting
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            self?.ready = false; self?.busy = false
            self?.error = "The launcher service stopped. Quit and reopen Platinum Together."
        } }
        do { try p.run(); process = p } catch { self.error = "Couldn't start the launcher: \(error.localizedDescription)" }
    }
    func send(_ command: String, values: [String: Any] = [:], busy: Bool = true) {
        guard ready else { return }
        var object = values; object["command"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        if busy { self.busy = true; error = "" }
        do { try input.write(contentsOf: data + Data([10])) } catch { self.busy = false; self.error = "Couldn't reach the launcher service." }
    }
    func receive(_ data: Data) {
        buffer.append(data)
        while let index = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: index); buffer.removeSubrange(...index)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else { continue }
            switch type {
            case "ready":
                ready = true
                if let credential = loadCredential(), let saved = try? JSONSerialization.jsonObject(with: credential) as? [String: Any] { send("restore", values: saved, busy: false) }
                send("status", busy: false); send("news", busy: false); send("game-data", busy: false)
            case "done": busy = false; if !launchPending { gameBusy = false }
            case "status": status = object["label"] as? String ?? "Status unavailable"; players = object["players"] as? Int
            case "account":
                account = object["valid"] as? Bool == true ? object["name"] as? String ?? "Beta tester" : ""
                if !account.isEmpty { showSignIn = false; code = ""; pending = false }
            case "credential":
                var value = object; value.removeValue(forKey: "type")
                if let bytes = try? JSONSerialization.data(withJSONObject: value) { saveCredential(bytes) }
            case "forget": forgetCredential()
            case "pending":
                pending = true; channelURL = object["url"] as? String ?? ""; loginCommand = object["loginCommand"] as? String ?? ""
                slash = object["slash"] as? Bool ?? false; expiry = Date(timeIntervalSince1970: object["expires"] as? Double ?? 0)
            case "open": if let url = object["url"] as? String { open(url) }
            case "game-data": gameDataInstalled = object["installed"] as? Bool ?? false; gameDataVersion = object["version"] as? String ?? ""
            case "progress": gameMessage = object["stage"] as? String ?? "Installing…"; installFraction = object["fraction"] as? Double ?? 0
            case "play-ready": if let path=object["path"] as? String {
                if !account.isEmpty && !gameCredentialExists {pendingGamePath=path;send("link-game")}
                else {launchCompatibilityGame(path)}
            }
            case "game-credential":
                if let payload=object["payload"] as? String,let bytes=Data(base64Encoded:payload),bytes.count<16384 {
                    pendingGameCredential=bytes
                    let path=pendingGamePath;pendingGamePath=nil
                    launchCompatibilityGame(path ?? supportHome.appendingPathComponent("GameData").path,startGame:path != nil)
                } else {launchPending=false;gameBusy=false;error="The game account response was invalid."}
            case "updates": gameMessage = object["message"] as? String ?? "Update check complete."
            case "news": posts = object["posts"] as? [[String: Any]] ?? []
            case "error": launchPending=false; gameBusy=false; error = object["message"] as? String ?? "The request couldn't finish."
            default: break
            }
        }
    }
    func open(_ value: String) {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              ["discord.com", "discord.gg", "platinumtogether.online", "www.platinumtogether.online", "youtube.com", "www.youtube.com", "youtu.be", "x.com"].contains(host), url.user == nil, url.password == nil else { return }
        NSWorkspace.shared.open(url)
    }
    func keyQuery() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "beta-session"] }
    func saveCredential(_ data: Data) {
        let query = keyQuery()
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; status = SecItemAdd(item as CFDictionary, nil) }
        if status != errSecSuccess { error = "You're signed in for this session, but Keychain couldn't remember the sign-in." }
    }
    func loadCredential() -> Data? {
        var query = keyQuery(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    func forgetCredential() { SecItemDelete(keyQuery() as CFDictionary) }
    func signIn() { error = ""; showSignIn = true }
    func copyCommand() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(loginCommand, forType: .string) }
    func quit() { resetTimer?.invalidate(); timer?.invalidate(); process?.terminationHandler = nil; try? input?.close(); process?.terminate(); audio?.stop(); video.pause() }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    final class Surface: NSView {
        let videoLayer = AVPlayerLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; videoLayer.videoGravity = .resizeAspectFill; layer?.addSublayer(videoLayer) }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); videoLayer.frame = bounds }
    }
    func makeNSView(context: Context) -> Surface { let view = Surface(); view.videoLayer.player = player; return view }
    func updateNSView(_ view: Surface, context: Context) { view.videoLayer.player = player }
}

struct ActionButton: View {
    var title: String
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12).frame(minWidth: primary ? 180 : 0) }
            .buttonStyle(.plain).background(primary ? Color(red:0.76,green:0.89,blue:0.76) : .white.opacity(0.09)).foregroundStyle(primary ? Color(red:0.08,green:0.17,blue:0.16) : .white).clipShape(RoundedRectangle(cornerRadius:8))
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let pale = Color(red:0.79,green:0.86,blue:0.88)
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Image(nsImage: NSImage(contentsOf: assetRoot.appendingPathComponent("app.ico")) ?? NSImage()).resizable().scaledToFit().frame(width:44,height:44).padding(.top,24).padding(.bottom,20)
                ForEach([("Game","gamecontroller"),("News","newspaper"),("Guide","book")],id: \.0) { item in
                    Button { model.page = item.0; model.error = "" } label: {
                        VStack(spacing:7) { Image(systemName:item.1).font(.system(size:20)); Text(item.0).font(.system(size:11,weight:.medium)) }.frame(width:86,height:64)
                    }.buttonStyle(.plain).background(model.page == item.0 ? .white.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius:9))
                }
                Spacer()
                Button { model.page = "Settings"; model.error = "" } label: { VStack(spacing:7) { Image(systemName:"gearshape").font(.system(size:20)); Text("Settings").font(.system(size:11)) }.frame(width:86,height:64) }.buttonStyle(.plain).padding(.bottom,20)
            }.frame(width:114).background(Color(red:0.055,green:0.085,blue:0.115))
            GeometryReader { geo in
                ZStack(alignment:.topLeading) {
                    Image(nsImage:NSImage(contentsOf:assetRoot.appendingPathComponent("\(model.scene).png")) ?? NSImage()).resizable().scaledToFill().frame(width:geo.size.width,height:geo.size.height).clipped()
                    if model.motion { VideoSurface(player:model.video).allowsHitTesting(false) }
                    LinearGradient(colors:[.black.opacity(0.40),.black.opacity(0.05),Color(red:0.035,green:0.07,blue:0.10).opacity(0.98)],startPoint:.top,endPoint:.bottom)
                    LinearGradient(colors:[.black.opacity(0.46),.clear],startPoint:.leading,endPoint:.trailing)
                    VStack(alignment:.leading,spacing:0) {
                        HStack {
                            Text("PLATINUM TOGETHER").font(.system(size:11,weight:.semibold)).tracking(2)
                            Text("MAC COMPATIBILITY").font(.system(size:9,weight:.bold)).tracking(1).padding(.horizontal,8).padding(.vertical,5).background(.white.opacity(0.12)).clipShape(Capsule())
                            Spacer()
                            Button { model.signIn() } label: { Label(model.account.isEmpty ? "Sign in to Discord" : model.account,systemImage:"person.crop.circle").font(.system(size:12)) }.buttonStyle(.plain).disabled(!model.ready || model.busy)
                        }.frame(height:64)
                        if model.page == "Game" { home }
                        else { panel }
                        if !model.error.isEmpty && !model.showSignIn { Text(model.error).font(.system(size:12)).foregroundStyle(Color(red:1,green:0.78,blue:0.64)).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius:8)).padding(.bottom,12).textSelection(.enabled) }
                        HStack(spacing:9) {
                            Circle().fill(model.status.contains(" is open") ? Color.green : pale.opacity(0.6)).frame(width:6,height:6)
                            Text(model.status).font(.system(size:11))
                            if let players = model.players { Text("·  \(players) online").font(.system(size:11)) }
                            Spacer()
                            Text("Launcher 0.1.21 · Mac compatibility").font(.system(size:10)).opacity(0.6)
                        }.foregroundStyle(pale).padding(.bottom,20)
                    }.padding(.horizontal,36)
                }.clipped()
            }
        }.foregroundStyle(.white).frame(minWidth:940,minHeight:640).preferredColorScheme(.dark)
            .sheet(isPresented:$model.showSignIn) { signInSheet }
    }
    var home: some View {
        VStack(alignment:.leading,spacing:0) {
            Image(nsImage:NSImage(contentsOf:assetRoot.appendingPathComponent("wordmark.png")) ?? NSImage()).resizable().scaledToFit().frame(width:345).padding(.top,45)
            Text("See you in Sinnoh.").font(.system(size:34,weight:.semibold)).padding(.top,28)
            Text("Explore Sinnoh with your friends.").font(.system(size:15)).foregroundStyle(pale).padding(.top,12)
            Spacer()
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:10) {
                    Text(model.canPlay ? "Ready to explore." : "Install your game.").font(.system(size:21,weight:.semibold))
                    Text(model.gameDataInstalled ? "Platinum Together " + model.gameDataVersion + " · Compatibility mode" : "Choose your Platinum ROM to install the current game.").font(.system(size:13)).foregroundStyle(pale).lineSpacing(5)
                    HStack(spacing:10) {
                        ActionButton(title:model.isPlaying ? "Playing" : "Play",primary:true) { model.playGame() }.disabled(!model.canPlay || model.gameBusy || model.isPlaying).opacity(model.canPlay ? 1 : 0.4)
                        ActionButton(title:model.gameDataInstalled ? "Install / Repair" : "Install Game") { model.installGame() }.disabled(model.gameBusy || model.isPlaying)
                        ActionButton(title:"Check for Updates") { model.checkUpdates() }.disabled(!model.ready || model.busy || model.gameBusy)
                    }.padding(.top,12)
                    if model.gameBusy { ProgressView(value:model.installFraction).frame(maxWidth:400).padding(.top,8) }
                    if !model.gameMessage.isEmpty { Text(model.gameMessage).font(.system(size:12)).foregroundStyle(pale).fixedSize(horizontal:false,vertical:true).frame(maxWidth:650,alignment:.leading).padding(.top,8).textSelection(.enabled) }
                }
                Spacer()
                VStack(spacing:14) {
                    Button { model.open("https://youtube.com/@platinumtogether") } label: { Image(systemName:"play.rectangle").font(.system(size:20)) }
                    Button { model.open("https://platinumtogether.online") } label: { Image(systemName:"globe").font(.system(size:20)) }
                }.buttonStyle(.plain)
            }.padding(.bottom,38)
        }
    }
    var panel: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Text(model.page == "Guide" ? "Welcome to Platinum Together." : model.page).font(.system(size:30,weight:.semibold))
                if model.page == "News" {
                    if model.posts.isEmpty { Text("No announcements are bundled with this launcher release.").foregroundStyle(pale); ActionButton(title:"Visit Platinum Together") { model.open("https://platinumtogether.online") } }
                    ForEach(Array(model.posts.enumerated()),id:\.offset) { _, post in
                        VStack(alignment:.leading,spacing:12) { Text(post["title"] as? String ?? "").font(.title2); Text(post["body"] as? String ?? "").textSelection(.enabled); if let url=post["url"] as? String { ActionButton(title:"Read more") { model.open(url) } } }.padding(20).background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:12))
                    }
                } else if model.page == "Guide" {
                    Text("1. Sign in with your approved Discord account.").font(.headline)
                    Text("Enter your Discord username, then open the private sign-in channel or use /login. Enter the eight-digit code in this launcher. Your account needs the Beta Player role.").foregroundStyle(pale)
                    Text("2. Keep your own Platinum ROM ready.").font(.headline)
                    Text("Choose Install Game and select your US Platinum ROM. The launcher verifies the official download, then extracts the needed ROM data locally. Choose Play when installation finishes.").foregroundStyle(pale)
                    ActionButton(title:"Open the official guide") { model.open("https://platinumtogether.online/download.html") }
                } else {
                    Text("Make Sinnoh your own.").foregroundStyle(pale)
                    Picker("Background scene",selection:$model.scene) { Text("Canalave City").tag("canalave"); Text("Floaroma Town").tag("floaroma"); Text("Lake").tag("lake"); Text("Route").tag("route") }.frame(maxWidth:380)
                    Toggle("Animated background",isOn:$model.motion).toggleStyle(.switch).frame(maxWidth:380)
                    Toggle("Mute launcher music",isOn:$model.muted).toggleStyle(.switch).frame(maxWidth:380)
                    Divider().padding(.vertical,4)
                    Text("Account").font(.headline)
                    Text(model.account.isEmpty ? "Not signed in" : "Signed in as \(model.account)").foregroundStyle(pale)
                    Text("Saved sign-in is stored in macOS Keychain.").font(.system(size:12)).foregroundStyle(pale)
                    if model.account.isEmpty { ActionButton(title:"Sign in to Discord") { model.signIn() }.disabled(model.busy || !model.ready) }
                    else {
                        ActionButton(title:"Connect game account") { model.connectGameAccount() }.disabled(model.busy || model.gameBusy || model.isPlaying)
                        ActionButton(title:"Sign out of launcher") { model.send("signout") }.disabled(model.busy || model.gameBusy)
                    }
                    if !model.accountMessage.isEmpty { Text(model.accountMessage).font(.caption).foregroundStyle(pale) }
                    Text("The game keeps its own encrypted sign-in. Use its account menu to sign out of the game.").font(.caption).foregroundStyle(pale)
                    ActionButton(title:"Open game folder") { model.openGameFolder() }
                    ActionButton(title:"Open logs") { model.openLogs() }
                    ActionButton(title:"Refresh server status") { model.send("status") }.disabled(model.busy || !model.ready)
                    Text("Compatibility mode uses Wine and Mesa software OpenGL. Rosetta is required. Graphics performance and online features need testing on each Mac.").font(.system(size:12)).foregroundStyle(pale)
                }
                Spacer(minLength:20)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(28)
        }.background(Color(red:0.045,green:0.08,blue:0.11).opacity(0.94)).clipShape(RoundedRectangle(cornerRadius:14)).padding(.vertical,20)
    }
    var signInSheet: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text(model.account.isEmpty ? "Sign in for beta access" : "Your account").font(.system(size:24,weight:.semibold)); Spacer(); Button { model.showSignIn = false } label: { Image(systemName:"xmark") }.buttonStyle(.plain) }
            if !model.account.isEmpty {
                Text("Signed in as \(model.account).").foregroundStyle(pale)
                ActionButton(title:"Connect game account") { model.connectGameAccount() }.disabled(model.busy || model.gameBusy || model.isPlaying)
                if !model.accountMessage.isEmpty { Text(model.accountMessage).font(.caption).foregroundStyle(pale) }
                Text("Save and close the game before connecting. The game keeps a separate encrypted sign-in; sign out through its account menu.").font(.caption).foregroundStyle(pale)
                ActionButton(title:"Sign out of launcher") { model.send("signout"); model.showSignIn = false }.disabled(model.busy || model.gameBusy)
            } else if model.pending {
                Text(model.slash ? "Copy this command into #beta-tester-general in Discord. The bot's reply is visible only to you." : "Open your private Discord channel, then enter its eight-digit code below.").foregroundStyle(pale)
                if model.slash { Text(model.loginCommand).font(.system(.body,design:.monospaced)).textSelection(.enabled).padding(12).background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:6)); ActionButton(title:"Copy command") { model.copyCommand() } }
                ActionButton(title:model.slash ? "Open Discord" : "Open sign-in channel") { model.open(model.channelURL) }
                TextField("Eight-digit code",text:$model.code).textFieldStyle(.roundedBorder).onSubmit { if !model.busy { model.send("complete",values:["code":model.code]) } }
                Text("Expires at \(model.expiry.formatted(date:.omitted,time:.shortened)).").font(.caption).foregroundStyle(pale)
                ActionButton(title:"Sign in",primary:true) { model.send("complete",values:["code":model.code]) }.disabled(model.busy || model.code.count != 8)
                Button("Request a new code") { model.pending = false; model.code = ""; model.error = "" }.disabled(model.busy)
            } else {
                Text("Use the Discord account with the Beta Player role. No password or direct message is needed.").foregroundStyle(pale)
                TextField("Discord username",text:$model.username).textFieldStyle(.roundedBorder)
                ActionButton(title:"Create sign-in channel",primary:true) { model.send("start",values:["username":model.username,"method":"channel"]) }.disabled(model.busy || model.username.isEmpty)
                ActionButton(title:"Use /login in Discord") { model.send("start",values:["username":model.username,"method":"command"]) }.disabled(model.busy || model.username.isEmpty)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text("Contacting Platinum Together…").font(.caption) } }
            if !model.error.isEmpty { Text(model.error).font(.system(size:12)).foregroundStyle(Color(red:1,green:0.78,blue:0.64)).textSelection(.enabled) }
        }.padding(32).frame(width:480).background(Color(red:0.055,green:0.085,blue:0.12)).preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: LauncherModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = LauncherModel()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:744),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Platinum Together"; window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(red:0.055,green:0.085,blue:0.115,alpha:1)
        window.minSize = NSSize(width:940,height:640); window.contentView = NSHostingView(rootView:LauncherView(model:model)); window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu(); let appMenu = NSMenu(); let item=NSMenuItem(); item.submenu=appMenu; menu.addItem(item)
        appMenu.addItem(withTitle:"About Platinum Together",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Platinum Together",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let edit=NSMenuItem(); edit.title="Edit"; edit.submenu=NSMenu(title:"Edit"); menu.addItem(edit)
        edit.submenu?.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x"); edit.submenu?.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c"); edit.submenu?.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v"); edit.submenu?.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu=menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { model?.quit() }
}
@main struct Main {
    static func main() { let app=NSApplication.shared; let delegate=AppDelegate(); app.delegate=delegate; app.setActivationPolicy(.regular); app.run(); _=delegate }
}
