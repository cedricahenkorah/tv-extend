# tv-extend

Use a Google TV as a wireless **extended display** for a Mac: a real second screen you can
drag windows onto, arrange next to your other monitors and use with Spaces and full-screen
apps. No HDMI cable, and not just mirroring.

It's two small apps that talk to each other over your home network:

- **TV Extend for Mac** (`mac/`): adds a virtual display to macOS and streams it.
- **TV Extend for TV** (`tv/`): shows that stream full screen on the TV.

---

## Everyday use

1. **On the TV:** open **TV Extend** from the Apps row. It shows "Waiting for your Mac…".
2. **On the Mac:** open **TV Extend**. Its controls are in two places:
   - the **TV icon** in the menu bar (top right), and
   - the **Dock icon**: right-click it.
3. Under **TVs on Your Network**, click your TV.

A new display named after your TV appears and the TV starts showing it. Use it like any
monitor: drag windows onto it, or move the mouse past the edge of your screen.

When you're done, choose **Disconnect** (or quit either app). The display disappears and its
windows move back to your Mac.

**Good to know**

- **Where the TV sits:** the first time, set its position in System Settings → Displays
  (drag it to the left, right or above your other screens). macOS remembers this.
- **It reconnects by itself.** If Wi-Fi drops or the TV app restarts, the display stays put
  for up to a minute while it reconnects, so your windows don't jump back to the Mac.
- **It connects by itself.** With **Connect Automatically** on (the default), opening the TV
  app is enough: the Mac connects to the TV you used last. After you click **Disconnect**, it
  waits until you close and reopen the TV app before connecting again.
- **Status:** the first line of the menu shows what's happening, for example
  `Streaming to Living Room TV · 12 ms · 6.4 Mbps`. The ms figure is the network round trip.
  A "dropped" count means Wi-Fi is struggling.
- **Keyboard and mouse** stay on the Mac. The TV remote doesn't control the extended display.

## Settings

All in the same menu:

| Setting | What it does |
|---|---|
| **Display Size** | **Default** behaves like a 1920×1080 monitor. **Larger Text** (looks like 1280×720) and **Largest Text** (looks like 960×540) make everything bigger and Retina-sharp, which helps when reading from the couch. |
| **Video Quality** | 10, 20 (default) or 30 Mbps. Higher is sharper; lower is easier on a busy Wi-Fi network. |
| **Connect Automatically** | Connect to the last TV as soon as it appears on the network. |
| **Launch at Login** | Start TV Extend when you log in. Install the app in `/Applications` first (see setup). |
| **Save Debug Recording** | Also save each session to `~/Movies/TV Extend/` (a `.mov` for QuickTime plus the raw stream). Off by default; only needed for debugging. |

Display Size and Video Quality apply the next time you connect.

---

## One-time setup

You need the Mac and the TV on the **same network**. 5 GHz Wi-Fi or Ethernet on the TV gives
the best results.

### 1. Install the tools on the Mac

- **Xcode** (App Store)
- **XcodeGen:** `brew install xcodegen`
- **Android Studio:** `brew install --cask android-studio`. Open it once so it installs the
  Android SDK.
- Put `adb` on your PATH by adding this line to `~/.zshrc`, then open a new terminal:
  ```sh
  export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
  ```

### 2. Prepare the TV

1. **Turn on Developer options:** Settings → System → About, then press OK on
   **Android TV OS build** 7 times until it says you're a developer.
2. **Turn on debugging:** Settings → System → Developer options → **USB debugging** (on some
   TVs, also **Wireless debugging**).
3. **Find the TV's IP address:** Settings → Network & Internet → your network → **IP address**.
4. **Connect from the Mac:**
   ```sh
   adb connect <tv-ip>:5555
   ```
   On the TV, tick **Always allow from this computer** and choose **Allow**. Check with
   `adb devices`: the TV should be listed as `device`.

### 3. Install the TV app

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd tv
./gradlew installDebug
```

**TV Extend** now appears in the TV's Apps row. You only need `adb` again to update the app.

### 4. Set up signing for the Mac app

macOS ties permissions to the app's signature. With a stable signature you grant them once;
without one, macOS forgets them after every rebuild.

1. In Xcode → Settings → **Accounts**, add your Apple ID (free). Select your Personal Team →
   **Manage Certificates…** → **+** → **Apple Development**.
2. Copy the example config and fill in your team ID (shown in Xcode → Settings → Accounts):
   ```sh
   cp mac/Config/Local.xcconfig.example mac/Config/Local.xcconfig
   ```
   `Local.xcconfig` is gitignored, so your team ID stays out of the repo.

### 5. Build and install the Mac app

```sh
cd mac
xcodegen generate
xcodebuild -project TVExtend.xcodeproj -scheme TVExtend -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/TVExtend.app /Applications/
open /Applications/TVExtend.app
```

### 6. Grant permissions (first connection only)

The first time you connect, macOS asks for two permissions:

1. **Local Network:** click **Allow**. This lets the app find and reach the TV.
2. **Screen & System Audio Recording:** click **Open System Settings** and turn on
   **TVExtend**. macOS then asks you to quit and reopen the app. Do that and connect again.

The app only captures its own virtual display, never your other screens, and nothing is saved
to disk (unless you turn on Save Debug Recording).

---

## Troubleshooting

**The TV isn't listed under "TVs on Your Network"**
- Make sure TV Extend is open on the TV and both devices are on the same network (not a guest
  network).
- Some routers and mesh systems block Bonjour discovery. Use **Connect by IP Address…** with
  the address shown on the TV instead.
- Check that **TVExtend** is allowed under System Settings → Privacy & Security → **Local
  Network**.

**"TV Extend couldn't connect" or a permissions error**
- Check System Settings → Privacy & Security → **Screen & System Audio Recording**. If
  TVExtend appears twice, remove both with **−**, then reconnect and allow it again.
- If permissions keep resetting after rebuilds, the app is signed ad hoc. Check that
  `mac/Config/Local.xcconfig` exists with your team ID (setup step 4).

**Laggy or soft picture**
- Switch the TV's picture mode to **Game** (or turn off motion smoothing). TV image processing
  can add a lot of delay.
- Use 5 GHz Wi-Fi, or Ethernet on the TV. If the menu shows "dropped" frames, try
  **Video Quality → 10 Mbps**.
- For small text, try **Display Size → Larger Text**.

**`adb` says "offline" or can't connect**
- The TV is probably asleep. Wake it, then run `adb disconnect` followed by
  `adb connect <tv-ip>:5555`.
- The TV's IP may have changed. Check it again in the TV's network settings.

**The menu-bar icon is missing**
- On MacBooks with a notch, extra menu-bar icons hide behind it. Use the Dock icon instead,
  or allow TVExtend under System Settings → **Menu Bar**.

---

## Development

See [protocol.md](protocol.md) for the wire format both apps speak.

```
mac/     Swift menu-bar app (Xcode project generated by XcodeGen from project.yml)
tv/      Kotlin Android TV app (Gradle)
tools/   Go dev tools
```

**Mac app:** run `xcodegen generate` after adding or removing files or editing `project.yml`,
then open `TVExtend.xcodeproj` and press ⌘R. Debug builds land in
`mac/build/Build/Products/Debug/` when built from the terminal with `-derivedDataPath build`.

**TV app:** `./gradlew installDebug` from `tv/` builds and installs it, and
`adb logcat -s "TVExtend/Server" "TVExtend/Decoder" "TVExtend/Advertiser"` shows its logs.

**Test the TV app on its own:** `tools/sendfile` streams a saved recording (from Save Debug
Recording) to the TV:

```sh
cd tools
go run ./sendfile -tv <tv-ip>          # newest recording in ~/Movies/TV Extend
go run ./sendfile -tv <tv-ip> -loop    # repeat until Ctrl-C
```

**Icons:** both apps' icons are drawn in code. After editing `mac/Tools/make-icon.swift`:

```sh
cd mac
swift Tools/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset   # Mac
swift Tools/make-icon.swift --android ../tv/app/src/main/res             # TV
```
