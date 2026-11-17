# Org Screen Saver

A macOS menu bar app that covers your screen while you step away, **without locking your Mac**. Your apps, calls, downloads and Omni-Channel status keep running. Only the screen and the keyboard are taken over. The app never changes any status (Slack, Omni-Channel or otherwise).

> **Status: v1.2.0.** It compiles, the core logic has unit tests, and the app launches. The lock behavior itself (key blocking, force-quit blocking, live wallpaper, Touch ID on the cover) is still being verified on real sessions. Work through [docs/TEST-CHECKLIST.md](docs/TEST-CHECKLIST.md) before relying on it, and keep test mode on while you do (see below). See [What's new](#whats-new) for recent changes.

## What it does

- Lives in the menu bar (no Dock icon).
- Starts on demand, after a countdown, on a schedule, with an optional keyboard shortcut, or (experimental) when your Bluetooth devices leave range.
- Opens a full-screen cover on every display showing your current wallpaper, including live wallpapers from apps like Backdrop, and nothing else. An optional message and a clock are shown on top.
- Hides and freezes the mouse pointer and ignores the mouse and keyboard, except:
  - **Touch ID** (default) and/or your **4-digit PIN** to unlock.
  - **F1 / F2** so you can still change brightness.
- Cannot be minimized, hidden, switched away from, quit or force-quit with the normal shortcuts (Cmd+Tab, Cmd+Q, Cmd+Opt+Esc and so on).
- Keeps the Mac awake while active so background work and presence continue.
- Takes a webcam photo when any key other than F1, F2 or a number is pressed.
- Logs everything it does (locks, unlocks, settings changes, permission problems) to a file.

## What's new

**1.2.0**
- **Settings reorganized.** Shortcut, Updates and Logs moved into the General tab as sections, and a new Permissions section shows live permission status with Grant buttons. The "Setup & Permissions..." menu item is removed; a failed lock now opens Settings at the right place instead.

**1.1.0**
- **Open Snapshots Folder** menu item, next to Open Log Folder (the same button also exists in Settings > Security).
- **Fixed a crash** when the cover appeared (Start Now, Lock In and schedules all hit it). The cover window now uses the plain `NSWindow` initializer.
- **No permission prompts under the cover.** Screen Recording / ScreenCaptureKit is exercised once at app launch, while the screen is uncovered, so any macOS prompt appears where you can answer it. During a lock, live wallpaper is used only if that warm-up succeeded; otherwise the static wallpaper is shown. (The camera was already skipped unless previously granted.)
- **Stable code signing.** `build-app-bundle.sh` now signs with your `CODESIGN_IDENTITY`, else the first "Apple Development" certificate in your keychain, else ad-hoc (with a warning). A stable signature keeps Accessibility, Screen Recording and Camera grants across rebuilds. See [Signing and permissions](#signing-and-permissions).

## What it is not

A **privacy cover for the office**, not a replacement for the macOS lock screen. Someone with physical access can still hold the power button or kill the app remotely over SSH. A 4-digit PIN is fine for this use but is weak against a determined attacker.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (the installer offers to install them)

## Install

```bash
git clone <repo-url> org-screen-saver
cd org-screen-saver
./install.sh
```

This builds the app locally, installs it to `~/Applications/Org Screen Saver.app` and opens it. Building locally means macOS does not block it as "from an unidentified developer".

**From a GitHub release instead:** download `OrgScreenSaver-<version>.zip`, unzip, move the app to `~/Applications`, and run:

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Org Screen Saver.app"
```

### First-run setup

A setup window checks and requests each permission:

| Permission | Required | Used for |
|---|---|---|
| Accessibility | Yes | Blocking keys and shortcuts while active |
| Screen Recording | No (on by default) | Live wallpaper. Only the desktop wallpaper layer is captured, never your windows. Without it you get your static wallpaper |
| Camera | No (on by default) | Photo on foreign key presses |
| Touch ID | Auto-detected | Unlocking. If the Mac has no Touch ID, a PIN is required |
| Bluetooth | Only if you use proximity | Auto-lock when devices leave range |

Then optionally set a **PIN** and a **recovery code** (8 digits, typed on the cover if you forget the PIN and Touch ID fails). After granting Accessibility you may need to reopen the app once.

## Use it

Click the lock icon in the menu bar:

| Item | What it does |
|---|---|
| Start Screen Saver Now | Covers the screen immediately |
| Lock In... | Starts after 5, 15, 30 or 60 minutes |
| Schedule... | One-time or repeating (weekday) schedules |
| Next / Cancel next schedule | Shows and cancels the next scheduled run |
| Settings... | All options (below) |
| Open Snapshots Folder | Opens the folder with the webcam photos |
| Open Log Folder | Opens the log directory |
| Check for Updates... | Looks for a new GitHub release |
| Quit | Disabled while the cover is active |

Lock In... adds a one-time schedule for 5, 15, 30 or 60 minutes from now. It appears under Schedule and "Next:" like any other schedule, and can be cancelled the same way.

### Settings

Settings has four tabs: General, Security, Schedule and Proximity.

- **General:** one scrolling page with these sections:
  - *General:* launch at login, keep display awake, live wallpaper on/off, optional **message** on the cover (empty by default).
  - *Permissions:* live status (checked every second) and a Grant button for Accessibility, Screen Recording and Camera, plus Touch ID availability. Grant permissions here before locking: a macOS prompt that appears under the cover cannot be answered. Relaunch the app after granting Screen Recording so live wallpaper turns on.
  - *Shortcut:* an optional global shortcut to start the screen saver. **Off by default.** It must include Control, Option or Command.
  - *Updates:* current version, automatic check on/off, check now, install updates from GitHub releases. "Check for Updates..." in the menu jumps straight to this section.
  - *Logs:* view the recent log, refresh it, and open the folder.
- **Security:** Touch ID on/off, PIN set/change/remove, recovery code, camera snapshot options (on/off, retention days, open folder). At least one of Touch ID or PIN must stay enabled.
- **Schedule:** add and delete one-time and repeating schedules. The app must be running (enable Launch at login). If the Mac is asleep at the scheduled time, it still starts on wake if less than 10 minutes late; otherwise that run is skipped.
- **Proximity (experimental):** choose which paired Bluetooth devices to watch. When all of them disconnect for N seconds the screen saver starts. It only arms after a device has been seen connected, and needs the device to reconnect before it can trigger again. Works best with devices macOS reports as connected, like headphones. Phones and watches often do not show as connected, so results vary.

### Unlocking

Touch ID is offered automatically when the cover appears and again after any key press. If you use a PIN, just type it (there is no text box; dots fill as you type).

- Wrong PIN: the dots shake and clear. After 3 wrong tries there is a 30-second wait, from the 6th a 5-minute wait.
- With a recovery code enabled, a wrong 4-digit entry stays pending until 8 digits are typed or 4 seconds pass.
- F1 / F2 adjust brightness at any time.

### Camera snapshots

Every key other than F1, F2 or a digit takes a photo, limited to one every 5 seconds and 100 per lock session. Photos are saved to `~/Library/Application Support/OrgScreenSaver/Snapshots/` (owner-only permissions) and deleted automatically after the retention period (30 days by default). The camera light turns on briefly each time. A video call using the camera can prevent a photo; this is logged.

## Signing and permissions

macOS ties Accessibility, Screen Recording and Camera approvals to the app's code signature. With the default ad-hoc signature every rebuild is a "new app" and the approvals stop working. To keep them across rebuilds, sign every build with the same certificate:

1. In Xcode: Settings > Accounts > add your Apple ID > Manage Certificates > **+** > **Apple Development**. (A self-signed code-signing certificate from Keychain Access also works: pass its name with `CODESIGN_IDENTITY`.)
2. Check it: `security find-identity -v -p codesigning` should list it.
3. Build as usual (`./install.sh`). The output shows `Signing (identity: Apple Development: ...)`. Override with `CODESIGN_IDENTITY="Name" ./install.sh`.
4. Grant the permissions once after the first signed build (remove stale entries in System Settings first).

Keep the certificate and its private key in your login keychain. Development certificates expire after a year, and a new certificate means granting permissions again.

**If the identity is listed as invalid** (`0 valid identities found`, or `codesign` fails with `errSecInternalComponent`): macOS is missing Apple's intermediate certificate. Download *Worldwide Developer Relations - G3* from <https://www.apple.com/certificateauthority/> and import it into the login keychain (`security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`).

Downloaded release builds are signed by the maintainer, not by you, and may need `xattr -dr com.apple.quarantine` (see Install). Local builds are never quarantined.

### Permission prompts and the cover

The cover sits above everything and blocks the mouse and keyboard, so a macOS permission prompt that appears while it is up cannot be seen or answered. Grant permissions in the setup window before locking. If you ever get stuck behind one, unlock with your PIN or Touch ID; the prompt is waiting once the cover is gone.

## Test mode (for development)

Test mode is **off by default** and is **not available in the app's menus or settings**. To enable it, edit:

```
~/Library/Application Support/OrgScreenSaver/config.json
```

```json
{
  "testMode": true,
  "testAutoUnlockMinutes": 5
}
```

The file is created automatically on first launch. It is read every time the cover starts, so no restart is needed. While test mode is on, **ESC unlocks immediately**, the cover auto-unlocks after `testAutoUnlockMinutes`, and a yellow "TEST MODE" label is shown. Set it back to `false` for normal use. Whether test mode was on is written to the log each time.

## Logs

`~/Library/Logs/OrgScreenSaver/orgscreensaver.log`, rotated at 5 MB (5 files kept). Records app start and quit, lock and unlock (with reason and duration), foreign key presses (key code only), wrong PIN attempts, settings changes, schedule events, proximity events, snapshots, permission problems and update checks. **PIN digits, recovery codes and typed characters are never logged.**

## Updates

Releases are published on GitHub. The app checks `https://api.github.com/repos/<owner>/<repo>/releases/latest` (on start and daily, if enabled), and **Settings > Updates > Install** downloads the zip, verifies its SHA-256 against the release's `.sha256` file, verifies the code signature, replaces the app and relaunches. Installing is refused while locked and if the checksum asset is missing. This is the only network access the app makes.

Maintainers: see [docs/RELEASING.md](docs/RELEASING.md).

## Troubleshooting

| Problem | Fix |
|---|---|
| "Accessibility permission needed" | Grant it in System Settings > Privacy & Security > Accessibility, then reopen the app |
| Shortcuts or permissions stop working after a rebuild | The build was signed ad-hoc or with a different certificate. Sign with a stable certificate (see [Signing and permissions](#signing-and-permissions)), then remove and re-add the app in Accessibility |
| Wallpaper is black or static | Grant Screen Recording and relaunch the app (live wallpaper is warmed up at launch); check the log for "live wallpaper" lines |
| A permission prompt appeared under the cover | Unlock with PIN / Touch ID, answer the prompt, and grant permissions in Settings > General > Permissions before locking |
| App crashes when the cover starts | Update to 1.1.0 or later (fixes a `CoverWindow` initializer crash). Crash reports are in `~/Library/Logs/DiagnosticReports` |
| `0 valid identities` when signing | Install Apple's WWDR G3 intermediate certificate (see [Signing and permissions](#signing-and-permissions)) |
| No snapshots | Grant Camera permission; check the log for "snapshot" lines |
| Touch ID does nothing on the cover | Check the log for "Touch ID not accepted"; set a PIN as a fallback |
| Stuck and cannot unlock | From another Mac via SSH: `pkill -f OrgScreenSaver`. Last resort: hold the power button |

## Uninstall

```bash
./uninstall.sh
```

Removes the app, settings, snapshots, logs and Keychain entries.

## Privacy

Everything stays on your Mac. The PIN and recovery code are stored only as salted PBKDF2 hashes in your Keychain. Screen Recording reads only desktop-level windows (the wallpaper). The only network request is the optional GitHub update check.

## For developers

```bash
swift test          # unit tests for the core logic
make app            # builds dist/Org Screen Saver.app (honors CODESIGN_IDENTITY, UPDATE_REPO)
make release        # builds dist/OrgScreenSaver-<version>.zip and .sha256
```

See [docs/PLAN.md](docs/PLAN.md) for architecture and diagrams.
