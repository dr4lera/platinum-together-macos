# Platinum Together for macOS

Unofficial macOS launcher for the **current official game**, using Wine + Mesa. The game executable is downloaded from its official signed feed; it is not a native game rewrite. The launcher is native SwiftUI.

## Install and play

1. Download the DMG from [Releases](https://github.com/dr4lera/platinum-together-macos/releases).
2. Open the DMG and drag **Platinum Together** into **Applications**. Eject the DMG and open the app from Applications.
3. Requires an **Apple Silicon Mac**, **macOS 15 or later**, and **Rosetta 2**. If Rosetta is missing, run `softwareupdate --install-rosetta` in Terminal and review Apple's license yourself.
4. Sign in with your approved Discord account. Use your private sign-in channel or `/login`, then enter the eight-digit code. Server access rules still apply.
5. Click **Install Game** and select your own **US Pokémon Platinum ROM (.nds)**. Installation downloads and verifies the official game, then imports ROM data locally. No ROM is included.
6. Click **Play**. The launcher connects the game account on its first signed-in launch. For an existing installation that still says offline, save and close the game, open the launcher's account panel, and click **Connect game account**, then Play.

The app is ad-hoc signed and **not Apple notarized**. macOS may require you to review it in Privacy & Security before allowing it to open. Build from source if you prefer. Do not disable Gatekeeper globally.

## Controls and troubleshooting

- **Play:** verifies installed files and starts the game. Save and close the existing game before launching again.
- **Install / Repair:** select the same original ROM to repair or install the current signed release. Keep a backup of saves before upgrading a game version.
- **Check for Updates:** checks the signed official feed and reports the available release. It does not install automatically; use Install / Repair.
- **Account:** Discord beta/download sign-in is saved in macOS Keychain. A Keychain prompt asks for your Mac login password. The game keeps a separate Windows-encrypted sign-in in its private Wine profile; use the game's account menu to sign out of the game. Signing out of the launcher only signs out of download access.
- **Settings:** choose background, animation and music; open game files/logs; refresh public server status. Background media pauses while the game runs.
- **News / Guide / social buttons:** open announcements or official project pages. This release bundles no announcements, so News shows an empty state.
- **Ctrl+R / back to last save:** keep the launcher open. If the official game hangs during its Windows restart, the launcher backs up the current save files and finishes the requested restart after about 8–12 seconds. As with any reset, unsaved progress is discarded.
- **Black scenes or slow rendering:** the launcher applies potato graphics, disables modern graphics, and starts windowed once on first use. Mesa uses CPU rendering, so leave potato graphics enabled. A shader cache is kept in the Wine profile. No promise is made that every scene or every Mac is free of rendering problems.

Your installed game, saves, logs, and Wine profile live under `~/Library/Application Support/Platinum Together/`. Settings includes **Open game folder** and **Open logs**. Replacing the application does not delete that folder. Do not post its credential files or private logs publicly. The first application of the graphics preset preserves `platinum-pc.before-mac-compat.ini`.

## Everyday use and backups

Double-click **Platinum Together** in Applications, or the Desktop shortcut if one was created. Leave the launcher open while playing so it can finish a stalled soft reset. Use the game's own Save command before exiting. Esc returns from menus; the game's Controls page shows the other bindings.

To update the **game**, check for updates and run Install / Repair with your original ROM. To update the **Mac launcher**, download the newer DMG and replace the app in Applications. Quit the game and launcher first. Existing game data and sign-in remain in Application Support.

For a manual backup, close the game, open Settings → Open game folder, and copy the whole GameData folder somewhere safe. Automatic reset-recovery backups are in `~/Library/Application Support/Platinum Together/Backups/`. Restore files only while the game is closed, and preserve a copy of the current folder first.

If the game fails to open, make sure Rosetta is installed and an earlier game window is closed. Check Settings → Open logs; game logs are in GameData/logs. If an online session fails, check public server status and your account's access, then close the game and use Connect game account if no game credential exists. An existing game account is deliberately preserved; manage it through the game's account menu.

## Tested

On one Apple Silicon Mac running macOS 26.5.1: official game **0.1.20**, title/menu, naming, saved-world loading, movement, and reduced black-screen stalls with potato graphics. The game resumed the launcher-provided account and connected to its online lobby. Ctrl+R reset recovery restarted the game and the saved world loaded successfully. Battles, trading, multiplayer sessions, every cutscene, Intel Macs, and older supported macOS releases are not comprehensively tested.

## Build

Install Xcode command-line tools, .NET SDK 10, and Python 3.12 or later, then run:

```sh
./scripts/build-mac.sh
```

The script downloads pinned official launcher dependencies, Wine 11.18, Mesa 26.2.4, 7-Zip, and Zig 0.17.0, verifies SHA-256 hashes, builds the native launcher and credential helper, ad-hoc signs the bundle, and creates `dist/PlatinumTogether-macOS-0.1.21-mac.4.dmg`. A network connection is needed for downloads and NuGet restore. It does not install or accept Apple's licenses for you.

The public repository contains only the Mac integration source and notices. It includes no ROM, game assets extracted from a ROM, Windows game executable, account credentials, saves, or decompiled game source. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with the official Platinum Together team, Nintendo, Game Freak, or The Pokémon Company.
