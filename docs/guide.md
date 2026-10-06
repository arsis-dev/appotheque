# Appothèque user guide

Appothèque has two surfaces plus Settings: the **launcher**, to open an app quickly, and a single **window** for everything else (details, build log, editing recipes, discovery, iOS destinations).

## Launcher

Open it from the menu bar icon or with the global shortcut, ⌃⌥Space by default.

- Clicking an app selects it and shows its card at the bottom: branch, last build, state, and the main button. The button says what a click will do: **Launch**, **Build & Launch**, **Show**, **Try Again** or **Choose & Launch**. The round buttons open the build log and the project folder. Hovering only highlights a row.
- **Double-click**, **Return** or the main button build the app if needed, then open it. While it builds, the row and the card show the current step, the elapsed time and the last line of the log.
- After a failure, the card shows the error with **Show Log** and, when one exists, **Last Successful Build**.
- The `…` menu of a row (on hover) and its context menu offer favorites, ordering, a forced build, the previous build, the log, the project folder, **Edit…** and **Hide from Launcher**.
- **Add** offers **Discover Apps…** or **Add Manually…**, with the number of new proposals. The sidebar button opens the window; `…` holds **Settings…**, **Refresh States and Projects** and **Quit**.

From the global shortcut, the launcher opens as a floating panel above your windows with the search field focused. Type a name, use the up and down arrows if needed, then press Return. Escape clears the search, then closes the panel; it also closes when you click elsewhere. Opening Appothèque from the Finder while it runs shows the same panel, or the window when the Dock icon is enabled.

### States

Each row shows a short state: **Needs build**, **Ready**, **Running**, **Changed**, **Destination** (an iOS app without a destination yet) or **Failed**. A dot or symbol goes with it; color never carries the information alone. States are refreshed when the launcher opens and with **Refresh States and Projects**. A launch always checks the files again.

## Window

Open it from the launcher's sidebar button, with ⌘0, from the Dock icon, or from any action that needs more room. The sidebar holds the search field and four sections: **Favorites**, **Apps**, **Hidden** and **Proposals**. Double-click or Return launches an app; the context menu offers the launcher's actions.

- **Detail**: state, branch, folder, current and previous builds (**Open**), **Force Build & Launch**, and the iOS destination. The toolbar holds favorite, folder, **Edit** (⌘E), **Log** (⌘L) and the main button (⌘Return).
- **Since the Last Build**: shown when the code changed. The fingerprint of the current files sits next to the one of the last build, followed by the files modified, added or removed (the first eight, then a count), and a note when the recipe, the selected Xcode or the built app changed. Each build's fingerprint is drawn as a small 3×3 glyph: the same inputs always draw the same glyph. Builds made before version 0.5 have no file list; it appears after the next build.
- **Log**: an inspector on the right, read again every second during a build, with **Copy** and **Show in Finder**.
- **Edit**: the recipe is edited in place, with **Cancel** and **Save** (⌘S). It also holds **Show in Launcher**, **Pin to Favorites** and **Remove from List…** (after confirmation; the project's files stay on your Mac).
- **Hidden**: a hidden app stays in this section, dimmed. Use **Show in Launcher** from its context menu or the switch in **Edit**. This takes effect immediately and triggers no build.
- **Proposals**: each detected app opens in the detail with **Ignore** and **Configure…**.
- Apps are reordered by drag and drop within their group (favorites or other apps), or with **Move Up** and **Move Down**. Visibility, favorites and order survive relaunches and never change a recipe or its fingerprint.

## Settings

- **General**: show in the menu bar and/or in the Dock (at least one stays on), open at login, the global shortcut (⌃⌥Space, ⌃⌥D, ⌃⌥L or off; a conflict with another app is reported), the folders to search and **Show Ignored Proposals Again**.
- **Appearance**: **Automatic**, **Light** or **Dark**, and one of eight tints: Appothèque Green (default), Pine, Blue, Purple, Pink, Brick, Graphite, or the system accent. Changes apply immediately.
- **Icon**: four app icons (Fingerprint, Fingerprint on Grid, Fingerprint Stack, Lifted Stack) and the menu bar glyph: **Stack** keeps the system symbol, **Matching Icon** uses the glyph drawn with the chosen icon. During a build the hammer replaces it.

The Finder shows the chosen icon on the installed app through a custom icon file at the root of the bundle, outside `Contents`, so the signature stays valid. Reinstalling removes it; Appothèque applies it again at launch. Icon sources: `Resources/AppIcon.icns`, `Resources/Icons/AppIcon-<id>.png` (1024 px, macOS grid), `Resources/Icons/MenuBar-<id>@2x.png` (36 px template) and the drawing in `docs/icon/source/`.

## Discovery

Appothèque looks for new apps in the folders to search when the launcher opens, at most once a minute. Proposals appear in the window's **Proposals** section.

Manifests are read without running any script:

- **Xcode** projects and workspaces, macOS and iOS targets.
- **XcodeGen** `project.yml`, with `xcodegen generate` as the first step of the recipe.
- **Swift Package** executables that use SwiftUI or AppKit, through the project's `build.sh` when it exists, or a small bundle assembled from `swift build`.
- **Tauri** projects, including a note when they bundle helper executables.
- **Electron** projects. The packaging tool is read from `package.json` (Electron Forge, electron-builder or electron-packager); the recipe targets the Mac's architecture and runs the `build` script first when it exists and does not package the app already.

An Electron project without a packaging tool but with a `main` entry (usually started with `electron .`) is proposed too. After its `build` script, the recipe copies `Electron.app` from `node_modules` into `~/Library/Caches/Appotheque/Electron/`, gives it the project's name, identifier and `.icns` icon when one exists, and adds a bootstrap that runs the project's compiled `main` in place. The bootstrap uses the `PATH` of your login shell, so tools launched by the app (`uv`, `node`…) are found as in your terminal. The resulting app is about 300 MB, like a packaged Electron app.

Each proposal opens a pre-filled recipe to review before saving. Separate working copies of the same project stay separate proposals.

## iOS and iPadOS

Discovery proposes the iOS and iPadOS targets of Xcode and XcodeGen projects. It searches up to four levels deep in a project, for example `apps/mobile/ios`, and proposes the workspace that references the project when there is one. A multiplatform target can have a Mac entry and an iOS entry. Swift packages alone are not treated as iOS apps.

1. Select the proposal in the window, click **Configure…**, check the scheme and the `.app` bundle name, then **Save**.
2. Click the app in the launcher. On the first launch, the window asks for a **simulator** or a **paired device** before building anything.
3. Appothèque builds if needed, boots the simulator, installs the app and launches it. Later launches reuse the chosen destination. Change it from the card's destination line, the **Destination** section of the detail, or **… → Choose Destination…**.

The picker separates iPhone and iPad, shows the OS version, and marks destinations that are unavailable or incompatible. A missing destination produces an explicit message; no other destination is chosen in its place.

- Simulators need an iOS runtime installed in Xcode.
- A physical device must be paired with the Mac, reachable over cable or network, unlocked, and in Developer Mode. Signing and the Apple team must already be set up for the app in Xcode. Appothèque does not change accounts, pairing or Developer Mode.
- With Xcode 27, the simulator window opens in Device Hub; earlier versions use Simulator.app.

Builds are kept separate per project, device or simulator, and OS version. The cache also accounts for the scheme, the configuration and Xcode. A missing or expired provisioning profile triggers a new build; if the signature is still invalid, the error is shown with access to the log. A simulator build is never sent to a device. Installs update the app without uninstalling it first.

The manual editor offers **Platform → iOS / iPadOS**, a `.xcodeproj` or `.xcworkspace` path, a scheme, a configuration and the product bundle name. **Optional Preparation** runs before the build, for example `xcodegen generate`; Appothèque then runs `xcodebuild` for the chosen destination. Paths generated by XcodeGen are excluded from the fingerprint; its manifests and the dependency lockfiles stay watched.

## Previous builds

**… → Open Previous Build** opens the previous generation without building. After a failed build, **Open Last Successful Build** returns explicitly to the last usable app. The action is disabled when no copy exists. The next normal launch still follows the current code.

This changes the binary that runs, not the app's data. If the current version is already running, the launcher brings it to the front. After a new build, it asks the older version to quit normally, respects any save dialog, and never forces it to quit. A failed build never opens an older version in its place.
