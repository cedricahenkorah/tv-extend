# tv-extend

Use a Google TV as a wireless **extended** display for a Mac (not just mirroring).

- `mac/`: Swift menu-bar app that creates a virtual display and streams it.
- `tv/`: Kotlin Android TV app that receives the stream and shows it.

See [PLAN.md](PLAN.md) for the roadmap and [protocol.md](protocol.md) for the wire format.

## Prerequisites

- Xcode, plus XcodeGen (`brew install xcodegen`) for the Mac app
- Android Studio + Android SDK, with `adb` on your PATH
- The TV with Developer options and USB/Wireless debugging on, connected with
  `adb connect <tv-ip>:5555`

## Mac app

**Signing (once):** copy `mac/Config/Local.xcconfig.example` to `mac/Config/Local.xcconfig` and
set your team ID. That file is gitignored. Without it the app is signed ad hoc, which still
runs, but macOS forgets its Screen Recording permission after every rebuild.

```sh
cd mac
xcodegen generate          # re-run after adding/removing files or editing project.yml
open TVExtend.xcodeproj    # then press ⌘R
```

Or build and launch from the terminal:

```sh
cd mac
xcodegen generate
xcodebuild -project TVExtend.xcodeproj -scheme TVExtend -derivedDataPath build build
open build/Build/Products/Debug/TVExtend.app
```

The app lives in the menu bar (TV icon). On first start, macOS asks for Screen Recording
permission: allow it, quit the app and open it again.

**Using it:** open TV Extend on the TV. On the Mac, the TV appears by name under **TVs on Your
Network** (menu-bar icon, Dock icon right-click, or the app menu); click it. A display named
after your TV appears; arrange it in System Settings → Displays. **Disconnect** removes it.
If the TV isn't listed (some routers block Bonjour), use **Connect by IP Address…** with the
address the TV shows.

- **Reconnects automatically:** if Wi-Fi drops or the TV app restarts, the display stays put
  for up to a minute while it reconnects, so your windows don't jump back to the Mac.
- **Connect Automatically** (on by default): connects to the last TV whenever it appears.
- **Display Size:** Default (1920×1080), or Larger/Largest Text (HiDPI, looks like
  1280×720 or 960×540) for reading from the couch. **Video Quality:** 10/20/30 Mbps.
- **Launch at Login:** registers the app where it currently is, so copy `TVExtend.app` to
  `/Applications` first.

**Save Debug Recording** (off by default) also writes each session to `~/Movies/TV Extend/`:
a `.mov` for QuickTime and the raw `.h264` stream used by `tools/sendfile`.

## TV app

Android Studio's bundled Java works for building; point `JAVA_HOME` at it once:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd tv
./gradlew installDebug     # builds and installs on the connected TV
adb shell am start -n local.tvextend.tv/.MainActivity
```

The app also appears in the TV's Apps row as **TV Extend**. It shows the address it is
listening on (`<tv-ip>:48100`).

## Test tools

`tools/sendfile` (Go) streams a Phase 1 recording to the TV app, to test the TV side on its own:

```sh
cd tools
go run ./sendfile -tv <tv-ip>          # newest recording in ~/Movies/TV Extend
go run ./sendfile -tv <tv-ip> -loop    # repeat until Ctrl-C
```
