using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using PlatinumTogether.Core;
using PlatinumTogether.Core.Beta;
using PlatinumTogether.Core.Install;
using PlatinumTogether.Core.Online;
using PlatinumTogether.Core.News;

var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
object outputLock = new();
void Send(object value) { lock(outputLock) Console.WriteLine(JsonSerializer.Serialize(value, jsonOptions)); }
var home = Environment.GetEnvironmentVariable("PT_LAUNCHER_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "Platinum Together");
Directory.CreateDirectory(home);
File.SetUnixFileMode(home, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
BetaDownloadSession? session = null;
ChannelSignInRequest? pending = null;
using var channel = new ChannelSignInClient();
using var beta = new BetaAccessClient();
using var hub = new HubClient();
void SessionUpdate() {
 if (session == null || !session.IsValid) { Send(new { type="account", name="", valid=false }); return; }
 // The original Windows persistence calls DPAPI. Preserve its session format in macOS Keychain instead.
 var token = typeof(BetaDownloadSession).GetFields(BindingFlags.Instance | BindingFlags.NonPublic)
  .Where(f => f.FieldType == typeof(string)).Select(f => f.GetValue(session) as string)
  .First(s => s != null && Regex.IsMatch(s, "^[A-Za-z0-9_-]{43}$"));
 Send(new { type="credential", token, name=session.Name, persistent=session.IsPersistent, expires=DateTimeOffset.UtcNow.AddSeconds(3500).ToUnixTimeSeconds() });
 Send(new { type="account", name=session.Name, valid=true });
}
Send(new { type="ready", version="0.1.21-mac.3", home });
while (await Console.In.ReadLineAsync() is string line) {
 try {
  using var document=JsonDocument.Parse(line); var root=document.RootElement;
  var command=root.GetProperty("command").GetString();
  string S(string key) => root.TryGetProperty(key,out var v) ? v.GetString() ?? "" : "";
  using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(95));
  switch(command) {
   case "status":
    var status = await hub.GetStatusAsync(timeout.Token);
    Send(new { type="status", label=status.Label, players=status.Players }); break;
   case "start":
    pending = S("method")=="command" ? await channel.StartWithCommandAsync(S("username"), ChannelSignInClient.LoadDevice(home), timeout.Token) : await channel.StartAsync(S("username"), ChannelSignInClient.LoadDevice(home), timeout.Token);
    Send(new { type="pending", url=pending.ChannelUrl.AbsoluteUri, expires=pending.ExpiresAt.ToUnixTimeSeconds(), slash=pending.UseSlashCommand, loginCommand=pending.LoginCommand, unavailable=pending.ChannelUnavailable }); break;
   case "complete":
    if(pending==null || pending.ExpiresAt<=DateTimeOffset.UtcNow) throw new Exception("This code request expired. Request a new code.");
    var signed=await channel.CompleteAsync(pending,S("code"),timeout.Token);
    session?.Dispose(); session=signed; pending=null; SessionUpdate(); break;
   case "browser":
    session?.Dispose();
    session=await beta.SignInAsync(uri => Send(new { type="open",url=uri.AbsoluteUri }),timeout.Token);
    SessionUpdate(); break;
   case "restore":
    var token=S("token"); var name=S("name");
    bool persistent=root.GetProperty("persistent").GetBoolean();
    long remaining=root.GetProperty("expires").GetInt64()-DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    if(!Regex.IsMatch(token,"^[A-Za-z0-9_-]{43}$") || name.Length>32 || (!persistent && remaining<=0)) { Send(new {type="forget"}); break; }
    var constructor=typeof(BetaDownloadSession).GetConstructors(BindingFlags.Instance|BindingFlags.NonPublic).Single(c=>c.GetParameters().Length==4);
    session?.Dispose(); session=(BetaDownloadSession)constructor.Invoke([token,name,(int)Math.Clamp(remaining,1,3600),persistent]);
    Send(new { type="account", name=session.Name, valid=session.IsValid }); break;
   case "signout":
    try { if(session != null) await session.SignOutAsync(BetaAccessClient.ProductionRoot, timeout.Token); }
    finally { session?.Dispose();session=null;pending=null;Send(new {type="forget"});Send(new {type="account",name="",valid=false}); }
    break;
   case "link-game":
    if(session==null || !session.IsValid || !session.IsPersistent) throw new Exception("Sign in to Discord once more to connect your game account.");
    var gameLink=await hub.LinkLauncherAsync(session,timeout.Token);
    using(var linkedSession=gameLink.Session) {
      var saved=linkedSession.ToSaved(gameLink.Named);
      try {
        var payload=JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string,object> {
          ["schema"]=1,["hub"]=saved.Hub,["seed"]=Convert.ToBase64String(saved.Seed),["token"]=saved.Token,["refresh_token"]=saved.RefreshToken,["name"]=saved.Name,["named"]=saved.Named
        });
        try { Send(new{type="game-credential",payload=Convert.ToBase64String(payload),fingerprint=session.AccountLinkFingerprint}); }
        finally { Array.Clear(payload); }
      } finally { Array.Clear(saved.Seed); }
    }
    break;
   case "prepare-play":
    var playRoot=Path.Combine(home,"GameData");
    var playInstall=await GameInstaller.GetInstalledAsync(playRoot,timeout.Token) ?? throw new Exception("Choose Install Game first.");
    var proofPath=Path.Combine(playRoot,"release.signed.json");
    var cachedProof=Path.Combine(home,"Downloads",playInstall.PackageSha256+".signed.json");
    if(!File.Exists(cachedProof) && !File.Exists(proofPath)) throw new Exception("The signed release proof is missing. Choose Install / Repair and select your ROM.");
    var proofBytes=await File.ReadAllBytesAsync(File.Exists(cachedProof)?cachedProof:proofPath,timeout.Token);
    var playable=await GameInstaller.VerifyAsync(playRoot,timeout.Token);
    if(!playable.IsValid) throw new Exception("Game or ROM files need repair. Choose Install / Repair and select your ROM.");
    await ReleaseIntegrity.VerifyInstalledAsync(playRoot,proofBytes,ReleaseFeed.ProductionSigningKey,playInstall.PackageSha256,timeout.Token);
    await File.WriteAllBytesAsync(proofPath+".tmp",proofBytes,timeout.Token); File.Move(proofPath+".tmp",proofPath,true);
    Send(new {type="play-ready",path=playRoot,version=playInstall.Version}); break;
   case "verify-game":
    var rootPath=S("path");
    var installedGame=await GameInstaller.GetInstalledAsync(rootPath,timeout.Token) ?? throw new Exception("No game installation manifest.");
    var checkedFiles=await GameInstaller.VerifyAsync(rootPath,timeout.Token);
    if(!checkedFiles.IsValid) throw new Exception("Installed game files failed verification.");
    var releaseProof=await File.ReadAllBytesAsync(Path.Combine(rootPath,"release.signed.json"),timeout.Token);
    await ReleaseIntegrity.VerifyInstalledAsync(rootPath,releaseProof,ReleaseFeed.ProductionSigningKey,installedGame.PackageSha256,timeout.Token);
    Send(new {type="verified-game",valid=true,version=installedGame.Version}); break;
   case "validate-rom":
    var checkedRom=await RomImporter.ValidateAsync(S("path"),timeout.Token);
    Send(new {type="rom", valid=true, sha256=checkedRom.Sha256}); break;
   case "game-data":
    var existing=await GameInstaller.GetInstalledAsync(Path.Combine(home,"GameData"),timeout.Token);
    Send(new {type="game-data", installed=existing!=null, version=existing?.Version ?? ""}); break;
   case "install":
    if(session==null || !session.IsValid) throw new Exception("Sign in to Discord before installing the beta game files.");
    timeout.CancelAfter(TimeSpan.FromMinutes(25));
    Send(new {type="progress",stage="Checking your ROM",fraction=0.0});
    var rom=await RomImporter.ValidateAsync(S("rom"),timeout.Token);
    using(var feed = new ReleaseFeed(new Uri(ReleaseFeed.ProductionUrl), ReleaseFeed.ProductionSigningKey, session.CreateDownloadHandler(BetaAccessClient.ProductionRoot))) {
      var release=await feed.CheckAsync(timeout.Token);
      var downloads=Path.Combine(home,"Downloads"); Directory.CreateDirectory(downloads);
      var archive=Path.Combine(downloads,release.Sha256+".zip");
      long lastProgress=0;
      var downloadProgress=new Progress<DownloadProgress>(p => {
        var now=Environment.TickCount64;
        if(now-Interlocked.Read(ref lastProgress)>250 || p.Received>=release.Bytes) { Interlocked.Exchange(ref lastProgress,now); Send(new {type="progress", stage="Downloading verified game files",fraction=Math.Clamp((double)p.Received/release.Bytes,0,1)}); }
      });
      await feed.DownloadAsync(release,archive,downloadProgress,timeout.Token);
      await File.WriteAllBytesAsync(Path.Combine(downloads,release.Sha256+".signed.json"),feed.LastVerifiedEnvelope!,timeout.Token);
      var gameRoot=Path.Combine(home,"GameData");
      var installProgress=new Progress<InstallProgress>(p => {
        var now=Environment.TickCount64;
        if(now-Interlocked.Read(ref lastProgress)>250) { Interlocked.Exchange(ref lastProgress,now); Send(new {type="progress",stage=p.Stage,fraction=p.TotalBytes>0 ? Math.Clamp((double)p.CompletedBytes/p.TotalBytes,0,1) : 0.0}); }
      });
      await GameInstaller.InstallAsync(archive,new PackageManifest(release.Version,release.Sha256,release.Bytes,release.OwnedPaths,release.GameplayReleaseId,release.SaveSchema),rom,gameRoot,installProgress,timeout.Token);
      await File.WriteAllBytesAsync(Path.Combine(gameRoot,"release.signed.json"),feed.LastVerifiedEnvelope!,timeout.Token);
      var result=await GameInstaller.VerifyAsync(gameRoot,timeout.Token);
      if(!result.IsValid) throw new Exception("Game data verification failed. Choose Install Game to repair it.");
      await ReleaseIntegrity.VerifyInstalledAsync(gameRoot,feed.LastVerifiedEnvelope!,ReleaseFeed.ProductionSigningKey,release.Sha256,timeout.Token);
      Send(new {type="game-data",installed=true,version=release.Version});
      Send(new {type="progress",stage="Game installed and verified. Choose Play to start.",fraction=1.0});
    }
    break;
   case "updates":
    if(session==null || !session.IsValid) throw new Exception("Sign in to Discord before checking the beta game release.");
    using(var feed = new ReleaseFeed(new Uri(ReleaseFeed.ProductionUrl), ReleaseFeed.ProductionSigningKey, session.CreateDownloadHandler(BetaAccessClient.ProductionRoot))) {
      var release=await feed.CheckAsync(timeout.Token);
      Send(new {type="updates", version=release.Version, platform="windows-x64", message=$"Verified official game release {release.Version}. Use Install / Repair to install or update your game."});
    }
    break;
   case "news":
    var path=Path.Combine(AppContext.BaseDirectory,"news.json");
    var news=NewsDocument.Parse(File.ReadAllBytes(path)); Send(new {type="news",posts=news.Visible()}); break;
   case "selftest":
    var valid=NewsDocument.Parse("{\"schema\":1,\"posts\":[]}"u8.ToArray()).Visible().Count==0;
    Send(new {type="selftest",passed=valid && NativeCrypto.Probe()==null, coreVersion=typeof(BetaAccessClient).Assembly.GetName().Version?.ToString(), platform=System.Runtime.InteropServices.RuntimeInformation.OSDescription}); break;
   default: throw new Exception("Unknown launcher action.");
  }
  Send(new {type="done"});
 } catch(Exception error) {
  Send(new {type="error",message=error is OperationCanceledException ? "The request timed out. Please try again." : error.Message});
  Send(new {type="done"});
 }
}
session?.Dispose();
