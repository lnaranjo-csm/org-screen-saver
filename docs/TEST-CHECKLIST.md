# Manual test checklist

The lock behavior depends on macOS permissions and the real window server, so it cannot be covered by unit tests. Work through this in order.

**Before you start**

1. Edit `~/Library/Application Support/OrgScreenSaver/config.json` and set `"testMode": true`. ESC now unlocks and the cover auto-unlocks after 5 minutes.
2. Have a second way in: SSH from another machine, or know that `pkill -f OrgScreenSaver` stops it.
3. Tail the log in another window: `tail -f ~/Library/Logs/OrgScreenSaver/orgscreensaver.log`

Record pass/fail and any log lines for each failure.

## 1. Setup and permissions
- [ ] Setup window opens on first launch
- [ ] Accessibility: Grant opens the prompt, the row turns green after approval
- [ ] Screen Recording and Camera prompts appear and rows update
- [ ] Touch ID row shows available on this Mac
- [ ] Done is disabled until Accessibility is granted
- [ ] If MDM blocks Accessibility: note the exact behavior (this is the main unknown)

## 2. Basic lock and unlock (test mode on)
- [ ] Start Screen Saver Now covers every display
- [ ] Menu bar and Dock are hidden, pointer is hidden and does not move
- [ ] ESC unlocks, cursor and Dock return, log shows LOCKED then UNLOCKED
- [ ] Auto-unlock after 5 minutes works when you do nothing
- [ ] Touch ID prompt appears on its own, and is **visible above the cover** (key risk)
- [ ] Touch ID unlock works
- [ ] PIN unlock works (set a PIN first), wrong PIN shakes, 3 wrong tries gives the 30 s wait

## 3. Blocking (all of these must do nothing while locked)
- [ ] Cmd+Tab, Cmd+Space, Cmd+Q, Cmd+W, Cmd+M, Cmd+H
- [ ] **Cmd+Opt+Esc (Force Quit window)**
- [ ] Ctrl+Cmd+Q (macOS lock), Ctrl+Up / Mission Control, Ctrl+Left/Right (Spaces)
- [ ] Mouse clicks, scroll, trackpad gestures (four-finger swipe, pinch)
- [ ] Volume and media keys
- [ ] Hot corners
- [ ] Activity Monitor cannot be reached
- [ ] F1 and F2 change brightness, and brightness change is visible

## 4. Wallpaper and cover background
- [ ] Normal static wallpaper shows on the cover
- [ ] No Screen Recording prompt appears and Screen Recording is not listed under Permissions
- [ ] Settings > General > Cover background: Choose File… with an image shows that image on the cover; Remove returns to the desktop wallpaper
- [ ] Choosing a video plays it muted and looping with no visible gap, on every display, and it stops after unlock
- [ ] Choosing a non-media file shows "Couldn't use that file" and keeps the previous background
- [ ] Moving or deleting the original file does not affect the cover
- [ ] Second display gets the background too

## 5. Everything keeps running
- [ ] A download or a timer keeps progressing behind the cover
- [ ] Slack / Omni-Channel status unchanged after a 10-minute lock
- [ ] A call or screen share continues, audio continues
- [ ] Mac does not sleep during a long lock

## 6. Snapshots
- [ ] Pressing a letter key takes a photo (Snapshots folder, log line)
- [ ] The photo is properly exposed, not black (taken after the camera adjusts)
- [ ] Pressing digits, F1 or F2 takes no photo
- [ ] Holding a key does not create more than one photo per 5 s
- [ ] Camera in use by a video call: failure is logged, nothing crashes

## 7. Crash recovery
- [ ] While locked, `pkill -9 -x OrgScreenSaver` (kills only the app): guard relaunches into locked state
- [ ] Note the gap in seconds during which the screen is exposed
- [ ] While locked, `kill -STOP $(pgrep -x OrgScreenSaver)` (freezes the app without killing it): after about 15 s the guard force-quits it and relaunches into locked state; log shows `app unresponsive`
- [ ] Mac sleep and wake while locked does not trigger a false `app unresponsive` kill
- [ ] `pkill -f OrgScreenSaver` kills both, so you are free again

## 8. Displays and power
- [ ] Unplug or plug an external display while locked: covers update once (a single `display configuration changed` log line) and a custom background video keeps playing on the displays that did not change
- [ ] After plugging or unplugging a display while locked, Touch ID still unlocks (the log may show `Touch ID prompt had no result; restarting it`)
- [ ] Lid close and open while locked: cover still active, Touch ID prompt returns
- [ ] Sleep and wake with a schedule pending: schedule fires on wake if inside 10 min

## 9. Schedule, shortcut, proximity
- [ ] "Lock In 5 minutes" starts on time, a repeating schedule fires on the right weekdays
- [ ] Missed schedule (Mac asleep > 10 min) is skipped and logged
- [ ] Shortcut is off by default; once enabled and recorded it starts the screen saver
- [ ] Proximity: selected headphones appear in the list; turning them off locks after the configured delay

## 10. Install and update
- [ ] `./install.sh` on a clean user account works end to end
- [ ] `./uninstall.sh` removes everything
- [ ] Create a test release and confirm Settings > Updates installs it and relaunches
- [ ] After the update, are Accessibility and Screen Recording still granted? (depends on signing)
