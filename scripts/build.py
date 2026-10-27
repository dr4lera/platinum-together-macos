#!/usr/bin/env python3
"""Build the Mac integration; never reads a ROM, saves, or a user account."""
from pathlib import Path
import hashlib,os,plistlib,shutil,subprocess,tarfile,urllib.request,zipfile
ROOT=Path(__file__).resolve().parents[1];os.chdir(ROOT)
B=ROOT/'.build';B.mkdir(exist_ok=True)
D=ROOT/'dist';D.mkdir(exist_ok=True)
def run(*args,**kw):subprocess.run([str(x) for x in args],check=True,**kw)
def fetch(name,url,sha):
 p=B/name
 if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest()!=sha:
  print('Downloading',name,flush=True)
  run('curl','--fail','--location','--retry','3','--output',p,url)
 if hashlib.sha256(p.read_bytes()).hexdigest()!=sha:raise RuntimeError('SHA-256 mismatch: '+name)
 return p
def unpack_tar(archive,dest):
 if not dest.exists():
  dest.mkdir()
  with tarfile.open(archive) as t:t.extractall(dest,filter='data')
def plain_copy(a,b):
 shutil.copyfile(a,b);os.chmod(b,os.stat(a).st_mode&0o777);return b
launcher=fetch('launcher.zip','https://pt-relay.kaicrits.com/beta-downloads/v1/launcher.zip','0722f05906276f94bcbd3ee46638fe1fbf610a47710c8204e7e8567b8d84308b')
if not (B/'launcher').exists():
 with zipfile.ZipFile(launcher) as z:z.extractall(B/'launcher')
wine=fetch('wine.tar.xz','https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz','aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82')
mesa=fetch('mesa.7z','https://github.com/pal1000/mesa-dist-win/releases/download/26.2.4/mesa3d-26.2.4-release-msvc.7z','351fc8c8b695878ffb3eaa044b3ead08672a48b1a045e3c3e3975811df0f6695')
seven=fetch('7zip.tar.xz','https://github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz','12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570')
zig=fetch('zig.tar.xz','https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz','b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a')
unpack_tar(wine,B/'wine');unpack_tar(seven,B/'7zip');unpack_tar(zig,B/'zig')
if not (B/'mesa').exists():run(B/'7zip/7zz','x',mesa,'-o'+str(B/'mesa'),'-y')
if os.uname().machine!='arm64':raise RuntimeError('This build targets Apple Silicon only.')
env=os.environ.copy();env['DOTNET_CLI_HOME']=str(B/'dotnet-home');env['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
run('dotnet','publish','Bridge','-c','Release','-r','osx-arm64','--self-contained','true','-o',B/'bridge','-p:PublishSingleFile=false',env=env)
# Keep the official content feed, including its honest empty-state behavior.
plain_copy(B/'launcher/Content/news.json',B/'bridge/news.json')
env['ZIG_GLOBAL_CACHE_DIR']=str(B/'zig-cache');env['ZIG_LOCAL_CACHE_DIR']=str(B/'zig-local')
zigbin=next((B/'zig').glob('*/zig'))
run(zigbin,'cc','-target','x86_64-windows-gnu','-O2','GameSessionHelper/session.c','-lcrypt32','-lshell32','-o',B/'GameSessionHelper.exe',env=env)
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
run('xcrun','swiftc','-parse-as-library','-swift-version','5','-module-cache-path',B/'swift-cache','-sdk',sdk,'-target','arm64-apple-macosx15.0','-O','App/Launcher.swift','-o',B/'PlatinumTogether')
stage=B/'stage-release'
if stage.exists():shutil.rmtree(stage)
app=stage/'Platinum Together.app';res=app/'Contents/Resources';mac=app/'Contents/MacOS';mac.mkdir(parents=True);res.mkdir()
plain_copy(B/'PlatinumTogether',mac/'PlatinumTogether');plain_copy(ROOT/'App/Info.plist',app/'Contents/Info.plist')
shutil.copytree(B/'bridge',res/'Bridge',copy_function=plain_copy)
shutil.copytree(B/'launcher/Assets',res/'Assets',copy_function=plain_copy)
compat=res/'Compatibility';compat.mkdir()
wineroot=next((B/'wine').glob('*.app'))/'Contents/Resources/wine'
shutil.copytree(wineroot,compat/'Wine',symlinks=True,copy_function=plain_copy,ignore=lambda path,names:[n for n in names if n in ('mono','gecko') and Path(path).name=='wine'])
(compat/'Mesa').mkdir()
for name in ('opengl32.dll','libgallium_wgl.dll'):plain_copy(B/'mesa/x64'/name,compat/'Mesa'/name)
plain_copy(B/'GameSessionHelper.exe',compat/'GameSessionHelper.exe')
shutil.copytree(ROOT/'licenses',res/'ThirdPartyNotices',copy_function=plain_copy)
plain_copy(ROOT/'THIRD_PARTY_NOTICES.md',res/'ThirdPartyNotices/THIRD_PARTY_NOTICES.md')
(stage/'Applications').symlink_to('/Applications')
plain_copy(ROOT/'START HERE.txt',stage/'START HERE.txt')
run('codesign','--force','--deep','--sign','-',app);run('codesign','--verify','--deep','--strict',app)
image=D/'PlatinumTogether-macOS-0.1.21-mac.4.dmg'
# HFS hybrid creation works in restricted build environments where create -srcfolder fails.
hybrid=B/'PlatinumTogether-hybrid.iso'
for old in (hybrid,Path(str(hybrid)+'.dmg')):
 if old.exists():old.unlink()
run('hdiutil','makehybrid','-hfs','-hfs-volume-name','Install Platinum Together','-o',hybrid,stage)
actual=hybrid if hybrid.exists() else Path(str(hybrid)+'.dmg')
run('hdiutil','convert',actual,'-format','UDZO','-ov','-o',image);run('hdiutil','verify',image)
(D/'SHA256SUMS.txt').write_text(hashlib.sha256(image.read_bytes()).hexdigest()+'  '+image.name+'\n')
print('Ready:',image)
