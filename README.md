# mac-sim.nvim

Native iOS Simulator viewer and live SwiftUI canvas preview for Neovim on Linux.

## Features

* **Live SwiftUI Canvas Preview**: Isolated, Xcode-style canvas preview rendered directly inside a Neovim split via the Kitty graphics protocol (`snacks.image`). Updates live on save without restarting the app or navigating.
* **Interactive Desktop Viewer**: Fast, native WebKitGTK desktop window for interacting with the booted iOS Simulator (touch, gestures, and hardware controls).
* **One-Key Build and Run**: Build and deploy Swift/SwiftUI projects to the simulator directly from your editor.
* **Simulator Management**: Boot, shut down, inspect status, capture screenshots, and manage device claims over SSH.

## Prerequisites

### Local Linux Machine
* **Neovim** >= 0.9.0
* **Terminal** supporting the Kitty graphics protocol (e.g. Ghostty, Kitty, WezTerm)
* **[snacks.nvim](https://github.com/folke/snacks.nvim)** (required for canvas image rendering)
* **Desktop Viewer Libraries** (GTK 3, WebKit2GTK 4.1, and LuaJIT for the interactive window):
  * **Arch / Manjaro**: `sudo pacman -S luajit webkit2gtk-4.1 gtk3`
  * **Ubuntu / Debian**: `sudo apt install luajit libwebkit2gtk-4.1-0 libgtk-3-0`
  * **Fedora**: `sudo dnf install luajit webkit2gtk4.1 gtk3`

### Remote macOS Host (Mac or Macbox)
* macOS VM or host (e.g. Macbox with Reims vGPU) with Xcode and iOS Simulator installed
* SSH access configured in `~/.ssh/config` (default alias: `Host macbox`)
* `mac-sim` CLI on system `$PATH` (`~/.local/bin/mac-sim`)
* `idev` on system `$PATH` for xtool projects (`idev swift generate-xcode-project`)
* Patched `expo-device-hub` on remote host (provisioned by `./macbox t3 fix-hub`) for interactive WebRTC viewing

## Installation

### Neovim with LazyVim / lazy.nvim

Add `~/.config/nvim/lua/plugins/mac-sim.lua`:

```lua
return {
  "tekibo/mac-sim.nvim",
  dependencies = { "folke/snacks.nvim" },
  ft = { "swift", "typescript", "typescriptreact" },
  cmd = {
    "MacSim",
    "MacSimView",
    "MacSimOpen",
    "MacSimClose",
    "MacSimToggle",
    "MacSimRun",
    "MacSimStop",
    "MacSimUp",
    "MacSimDown",
    "MacSimStatus",
    "MacSimShot",
    "MacSimRestartHub",
    "MacSimResetPool",
    "MacSimPreview",
    "MacSimPreviewToggle",
    "MacSimPreviewRestart",
    "MacSimPreviewStop",
    "MacSimSetup",
    "MacSimClean",
  },
  keys = {
    { "<leader>mp", "<cmd>MacSimPreview<cr>", desc = "iOS Simulator: Live SwiftUI Preview" },
    { "<leader>mv", "<cmd>MacSimView<cr>", desc = "iOS Simulator: Toggle Viewer" },
    { "<leader>mr", "<cmd>MacSimRun<cr>", desc = "iOS Simulator: Build and Run App" },
    { "<leader>ms", "<cmd>MacSim<cr>", desc = "iOS Simulator: Open Viewer" },
  },
  build = "./install.sh", -- installs ~/.local/bin/mac-sim-view
  opts = {
    ssh_host = "macbox", -- remote Mac hostname in ~/.ssh/config
    width = 410,
    height = 840,
    show_timing = true,  -- show save-to-frame time in the canvas winbar
  },
}
```

After installing, run `:MacSimSetup` once to deploy helper tools (`axe` and `idb_companion`) to your remote Mac host.

### Standalone Desktop Viewer

To install only the standalone desktop viewer CLI without Neovim:

```bash
curl -fsSL https://raw.githubusercontent.com/tekibo/mac-sim.nvim/main/install.sh | bash
```

Usage:
```bash
mac-sim-view [url] [width] [height] [title]
```
Defaults: `http://127.0.0.1:3400`, `410x840`.

## Neovim Commands

| Command | Keymap | Description |
|---|---|---|
| `:MacSimPreview` / `:MacSimPreviewToggle` | `<leader>mp` | Show or hide the canvas; the warm server stays alive |
| `:MacSimPreviewRestart` | | Restart the preview server and force a rebuild |
| `:MacSimPreviewStop` | | Stop the preview server and close the split |
| `:MacSimView` / `:MacSimToggle` | `<leader>mv` | Open or close the interactive simulator window |
| `:MacSimRun` | `<leader>mr` | Build and launch current project on the simulator |
| `:MacSimStop` | | Stop running app on the simulator |
| `:MacSimUp [kind]` | | Boot iOS simulator (`mac-sim up`) |
| `:MacSimDown` | | Shut down simulator (`mac-sim down`) |
| `:MacSimStatus` | | Show simulator pool status |
| `:MacSimShot [path]` | | Capture simulator screenshot |
| `:MacSimResetPool` | | Clear stale simulator lock claims |
| `:MacSimRestartHub` | | Restart touch and pointer event hub |
| `:MacSimSetup` | | Deploy vendored tools to remote Mac (`~/.local/lib/mac-sim.nvim/`) |
| `:MacSimClean` | | Clean remote binaries and preview cache on Mac |
