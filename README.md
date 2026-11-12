# LTEWatch

A native macOS menu bar prototype for quiet LTE connection monitoring.

### Version 0.1.8

The menu bar item is now a standard macOS menu. It opens with a single status line (Connection Good, Slow Connection, Unstable Connection, Weak LTE Signal, LTE Signal Unavailable, No Connection or Not Checked Yet) and one detail line with the latest ping and check time, followed by Check Now, Show History…, Settings… and Quit LTEWatch. Automatic checks now always run while the app is running, starting 30 seconds after launch or wake; the on/off switch has been removed.

The History window shows the same status as its heading, with Check Now and Export on the same row. It opens on the 6-hour range. Charts use plain-language labels (Ping, LTE Signal; Strength, Quality, Signal-to-Noise), show empty-state notes inside the chart, and keep time labels inside the chart edges. The LTE Signal chart can show excellent, good and poor threshold bands for all three measurements, using the TP-Link guidance values; a Thresholds checkbox turns them on or off and the choice is remembered. Its scale is tighter by default and widens only to keep outlying readings visible. Messages appear as dismissible notices. In Settings, Save and Cancel respond to Return and Esc; changing the router address removes the old address's password from Keychain, and turning off LTE readings removes the saved password.

The speed test has been removed completely: its menu item, History button, tiles and chart, Settings text, the `networkQuality` tool call, and the `download_mbps` and `upload_mbps` CSV columns. Existing history still loads; download and upload values saved by earlier versions are dropped the next time history is saved.

Reliability fixes: if a router login reply is lost after the router accepted it, logout is still attempted so the router isn't left with an open management session. Stopping a check or putting the Mac to sleep no longer shows a misleading "Could not reach the router" message. Pausing logins after a rejected password no longer depends on matching message text. History is written as compact JSON in the background, and the router password is read from Keychain in the background, so a Keychain permission prompt no longer freezes the app. App Transport Security no longer allows arbitrary loads; only local networking is permitted.

Release compilation and 25 automated checks passed, covering the new status rules, threshold scales, schedule, history compatibility, lost login replies, cancellation and the background Keychain read. The new windows and menu have not been checked by automated tests.

### Version 0.1.7

CSV export now presents a Save sheet attached to the history window, activates the app for presentation, and displays a visible success or detailed file-writing error. Repeated clicks reuse the open panel. The reported missing dialog was traced to an instance still running from a removed build bundle; installation now checks the actual running executable path before cleanup.

### Version 0.1.6

Adds a teal app icon with the same antenna SF Symbol as the menu bar. The icon is bundled at standard and Retina resolutions, replacing the generic macOS application icon. To regenerate it, run `swift Tools/generate-icon.swift work/AppIcon.iconset`, then `iconutil -c icns work/AppIcon.iconset -o Resources/AppIcon.icns`.

### Version 0.1.5

Finishes both four-packet latency samples before logging into the router and reading LTE status, for scheduled checks, manual checks and speed-test baselines. Previously, router login and LTE queries overlapped the pings and could affect their results. This removes that possible source of interference; it does not establish the cause of every historical spike. Ping results remain the system ping command's average, including slow replies. Cancelling during the ping phase skips the subsequent router connection.

### Version 0.1.4

Fixes false “another management session is active” errors when the MR600 reports `isLogined=0, isBusy=1`. The supplied router's unauthenticated login-page JavaScript was inspected on 2026-09-18: it sends a normal login when `isLogined=0`, regardless of `isBusy`. LTEWatch now follows that rule and continues to skip login when `isLogined=1`; it does not force another session out. Regression checks cover login/read/logout with the idle busy flag and protect active sessions with either busy-flag value. Only the public page and status endpoint were inspected on the physical router; authenticated validation remains with the user.

The menu bar keeps the current ping value visible while checking instead of displaying “Checking…”.

### Version 0.1.3

Hides the visible “Time range” selector label while retaining its accessibility label. Adds a 6-hour history range alongside 24 hours, 7 days and 30 days; the default remains 24 hours. The selector is wider to accommodate all four options.

### Version 0.1.2

All history action buttons now share the top row: ping/LTE check, speed test, Stop during a check, Export CSV, Pause/Start monitoring, and Settings. The subtitle sits below that row, and the minimum window width matches the 940 pt default to give the controls room.

Hides the visible “LTE measurement” label beside the RSRP / RSRQ / SNR control, keeping the label available for accessibility.

The LTE chart now shows a brief explanation inline after the “LTE quality” heading, matching the Latency heading style. It updates for the selected measurement, with approximate good/excellent thresholds from [TP-Link's LTE router guide](https://community.tp-link.com/en/home/stories/detail/798): RSRP −90/−80 dBm, RSRQ −15/−10 dB, and SNR 4.5/13 dB. Higher values are better; these are signal guidelines, not speed guarantees.

The schedule interval is now an editable field accepting any whole number from 1 to 60 minutes. Invalid or empty input shows an inline message and prevents saving. The default remains 30 minutes; scheduled checks still include ping and LTE only.

Each plotted measurement has a native tooltip with its metric, value, unit and timestamp, using a 44 × 44 pt target. There is no chart-wide hover tracking, click selection or highlight. Visible markers are slightly larger, and the separate details panel below the graphs has been removed. Version 0.1.2 compiled successfully and all 15 automated checks passed, including the updated 1–60 minute scheduling checks. The app has not been launched for visual verification; launching it is left to the user.

### Version 0.1.1

Fixed rejection of JSON login parameters: the first build only recognized JavaScript variable assignments. The parser now supports JSON and legacy responses, quoted or numeric sequence values, and hexadecimal exponents with or without a leading zero. Login result codes and session-token variants are handled consistently. Unrecognized responses now show a short, non-sensitive format classification. The menu summary wraps instead of truncating.

Quit the old app, replace it with this build, then launch it and select **Check ping & LTE**. The bundle identifier and history location are unchanged. The physical router still needs the user's first successful LTE check; the screenshot alone does not establish which response format the router returned.

## Use

1. Open **LTEWatch.app** and choose **Settings…** from its menu bar item.
2. Enter your router's local IPv4 address (default `192.168.1.1`). Enable LTE readings and enter the **local administrator password**. It is stored in macOS Keychain, not in the history file.
3. Save settings and choose **Check Now** to verify the first connection. If another router webpage or Tether session is active, log out of that session and try again.
4. Quiet checks run automatically every 30 minutes by default while the app is running. In Settings, enter any whole-number interval from 1 to 60 minutes.

Automatic checks start 30 seconds after the app launches and run for as long as it is running; there is no separate on/off switch. Close the history window to leave it in the menu bar; use **Quit** to stop it. You can add the app to macOS Login Items yourself if you want it to start when you sign in.

## What the graphs mean

- **Ping:** four ICMP pings to the chosen internet target and router. Missing replies are recorded; complete packet loss has a red cross. This is a brief sample, not continuous outage detection. The exported jitter field is ping's standard deviation.
- **LTE Signal:** strength (RSRP), quality (RSRQ) and signal-to-noise (SNR), selectable individually, with optional excellent/good/poor threshold bands. They describe the LTE link to the mobile network, not your Mac's Wi-Fi signal. The MR-series SNR field is converted from tenths of dB.
- **Inspect/export:** hover over a measurement point to see its value and timestamp in a native tooltip. CSV export includes timestamps, measurement type, latency, packet loss, LTE values and errors.

LTEWatch does not measure bandwidth; use a speed-test service for that. Signal and ping can show degradation but cannot establish available bandwidth or identify tower congestion conclusively.

## Load, storage and sleep

Between scheduled checks the app sends no monitoring traffic. Its timer only checks the local schedule. A scheduled observation sends four pings to each target and, if enabled, opens one short router session, discovers the LTE interface, reads one LTE snapshot, and attempts logout. Requests are serialized and not retried in a burst. Existing management sessions are not deliberately displaced.

The app does not wake the Mac. Checks only run while the app is running and the Mac is awake. Overdue checks resume after a settling delay without replaying missed checks. Graphs leave gaps across long intervals or missing measurements. Sleep/cancelled measurements are not reported as outages.

History is stored locally in `~/Library/Application Support/LTEWatch/history.json` for up to one year. Credentials, session cookies and raw router responses are not written into this file. Bad login responses pause future automatic LTE authentication until you verify and save Settings again. Ping monitoring can continue. There are no notification banners or accounts.

## Compatibility and validation limits

- **macOS 14 or later**. The included build is for Apple Silicon; the source can be built on an Intel Mac.
- TP-Link lists **Archer MR600(EU) V3 1.3.0 Build 250915**, matching the supplied firmware version `1.3.0 0.9.1 v0001.0 Build 250915 Rel.50622n`.
- The prototype implements the MR-series **RSA/AES-CBC local web protocol**, including busy-session detection, login, WAN stack discovery, LTE reads and logout. It does not implement GCM or ECC firmware variants, router configuration writes, band locking or cloud/Tether login.
- **The supplied physical router and password have not been tested.** A first successful LTE check is still required to validate this exact firmware. If it uses a different login format, the app reports that rather than claiming compatibility.
- Version 0.1.4 release compilation and 17 automated checks passed. These cover measurements, history and scheduling, AES-CBC and 512-bit RSA test fixtures, JSON/legacy parameter and result parsing, malformed responses, and complete simulated login/read/logout exchanges. The simulated-router tests also verify that busy management sessions are skipped and rejected passwords are attempted only once. Launching the app and testing the physical router are left to the user.
- This is a local development build with an ad-hoc signature, not an Apple-notarized distribution. It has no third-party runtime dependencies. macOS may request Local Network or Keychain access when you use the relevant feature.

## Build and checks

Requires Apple's Command Line Tools or Xcode. From this folder:

```sh
zsh check.sh
zsh build.sh
open dist/LTEWatch.app
```

Build intermediates go to `work/`; the app goes to `dist/`. Override these with `LTEWATCH_BUILD_DIR` and `LTEWATCH_OUTPUT_DIR`. The checks use a standalone Swift executable so they also work with Command Line Tools installations that do not include XCTest.

`LTEWATCH_DATA_DIR` overrides the history directory for isolated development. `--preview` disables measurements, scheduling and settings writes and labels the UI as synthetic example data; it is only for visual verification with a separate fixture history.

## Protocol and platform references

- [TP-Link MR600 V3 firmware](https://www.tp-link.com/en/support/download/archer-mr600/v3/)
- [MR-series client protocol reference](https://github.com/AlexandrErohin/TP-Link-Archer-C6U/blob/main/tplinkrouterc6u/client/mr.py)
- [MR-series encryption reference](https://github.com/AlexandrErohin/TP-Link-Archer-C6U/blob/main/tplinkrouterc6u/common/encryption.py)
- [NetPulse MR600 integration observations](https://github.com/CosmicOlorin/NetPulse-Monitor/blob/main/docs/MR600-INTEGRATION.md)
- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- Installed macOS manual page: `ping(8)`.

The Swift code is written for this prototype using the documented wire formats. No firmware, router credentials or proprietary router assets are included.
