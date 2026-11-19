# mac-sim.nvim

Native WebKitGTK desktop viewer and Neovim integration for iOS Simulators running on macbox, with sub-second SwiftUI live hot-reload.

## Prerequisites

### Linux Host
* **LuaJIT**, **GTK 3**, and **WebKit2GTK 4.1**:
  * **Arch / Manjaro**: `sudo pacman -S luajit webkit2gtk-4.1 gtk3`
  * **Ubuntu / Debian**: `sudo apt install luajit libwebkit2gtk-4.1-0 libgtk-3-0`
  * **Fedora**: `sudo dnf install luajit webkit2gtk4.1 gtk3`

### Macbox (or macOS Host)
* macOS with iOS Simulator installed and booted via `mac-sim`.
* SSH access configured (default: `ssh macbox`).
* Zero manual setup on Macbox. The plugin automatically transfers and provisions its background helper daemon and bundle.

### Editor
* Neovim >= 0.9.0.

## Installation

### Neovim with LazyVim

Add `~/.config/nvim/lua/plugins/mac-sim.lua`:

```lua
return {
  "tekibo/mac-sim.nvim",
  ft = { "swift", "typescript", "typescriptreact" },
  cmd = {
    "MacSim",
    "MacSimView",
    "MacSimOpen",
    "MacSimClose",
    "MacSimToggle",
    "MacSimRun",
    "MacSimReload",
    "MacSimLiveReload",
    "MacSimInit",
    "MacSimStop",
    "MacSimUp",
    "MacSimDown",
    "MacSimStatus",
    "MacSimShot",
    "MacSimRestartHub",
    "MacSimResetPool",
  },
  keys = {
    { "<leader>mv", "<cmd>MacSimView<cr>", desc = "iOS Simulator: Toggle View" },
    { "<leader>mr", "<cmd>MacSimRun<cr>", desc = "iOS Simulator: Run Swift App" },
    { "<leader>mR", "<cmd>MacSimReload<cr>", desc = "iOS Simulator: Reload App" },
    { "<leader>ms", "<cmd>MacSim<cr>", desc = "iOS Simulator: Open View" },
  },
  build = "./install.sh", -- installs ~/.local/bin/mac-sim-view
  opts = {
    width = 410,
    height = 840,
    device = "slim-1", -- simulator pool slot (default: slim-1)
    live_reload = true, -- sub-second SwiftUI hot-reload on save
  },
}
```

### Standalone CLI

To install only the standalone desktop viewer without Neovim:

```bash
curl -fsSL https://raw.githubusercontent.com/tekibo/mac-sim.nvim/main/install.sh | bash
```

## SwiftUI Live Hot-Reload

`mac-sim.nvim` provides true in-process SwiftUI live hot-reload for projects built with `idev`, `xtool`, or Xcode. Code changes inject dynamically in ~500ms without restarting the app or resetting navigation state.

### Setup in your Swift project

1. Run `:MacSimInit` in Neovim inside your iOS project. This generates `Sources/<AppName>/HotReload.swift`.
2. Add `.enableHotReload()` once to your root view in `@main` App:

```swift
import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .enableHotReload()
        }
    }
}
```

3. In screen views where UI structures and modifiers change rapidly during development, return `.eraseToAnyView()` on the view body. In Release builds, this compiles down to an `@inlinable` no-op (`return self`) with zero memory allocations and zero runtime cost:

```swift
struct ContentView: View {
    var body: some View {
        VStack {
            Text("Hello World")
        }
        .eraseToAnyView()
    }
}
```

4. Saving any `.swift` file (`:w`) automatically triggers single-file compilation and in-process view re-evaluation in ~500ms.

## CLI Usage

```bash
mac-sim-view [url] [width] [height] [title]
```

Defaults:
* URL: `http://127.0.0.1:3400`
* Dimensions: `410x840`

## Neovim Commands

| Command | Keymap | Description |
|---|---|---|
| `:MacSimView` / `:MacSimToggle` | `<leader>mv` | Open or close the simulator window |
| `:MacSimRun` | `<leader>mr` | Build and launch the app on the simulator |
| `:MacSimReload` | `<leader>mR` | Manual reload trigger (optional) |
| `:MacSimInit` | | Generate clean `HotReload.swift` template |
| `:MacSimLiveReload` | | Toggle automatic live reload on `:w` |
| `:MacSimStop` | | Stop running app on simulator |
| `:MacSimUp [kind]` | | Boot iOS simulator (`mac-sim up`) |
| `:MacSimDown` | | Shut down simulator (`mac-sim down`) |
| `:MacSimStatus` | | Show simulator pool status |
| `:MacSimResetPool` | | Clear stale simulator lock claims |
| `:MacSimShot` | | Capture lossless simulator screenshot |
| `:MacSimRestartHub` | | Restart touch/pointer event hub |
