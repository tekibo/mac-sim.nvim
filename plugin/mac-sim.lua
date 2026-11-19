-- plugin/mac-sim.lua
-- Auto-commands and User commands for tekibo/mac-sim.nvim

local mac_sim = require("mac-sim")

vim.api.nvim_create_user_command("MacSim", function()
  mac_sim.open()
end, { desc = "Open iOS Simulator viewer" })

vim.api.nvim_create_user_command("MacSimOpen", function()
  mac_sim.open()
end, { desc = "Open iOS Simulator viewer" })

vim.api.nvim_create_user_command("MacSimClose", function()
  mac_sim.close()
end, { desc = "Close iOS Simulator viewer" })

vim.api.nvim_create_user_command("MacSimView", function()
  mac_sim.toggle()
end, { desc = "Toggle iOS Simulator viewer" })

vim.api.nvim_create_user_command("MacSimToggle", function()
  mac_sim.toggle()
end, { desc = "Toggle iOS Simulator viewer" })

vim.api.nvim_create_user_command("MacSimRun", function()
  mac_sim.swift_run()
end, { desc = "Build and run current Swift/SwiftUI project on simulator (~2s)" })

vim.api.nvim_create_user_command("MacSimStop", function()
  mac_sim.swift_stop()
end, { desc = "Stop running app on simulator" })

vim.api.nvim_create_user_command("MacSimRestartHub", function()
  mac_sim.restart_hub()
end, { desc = "Restart Expo Device Hub to fix desynced touches" })

vim.api.nvim_create_user_command("MacSimStatus", function()
  mac_sim.status()
end, { desc = "Show mac-sim status" })

vim.api.nvim_create_user_command("MacSimUp", function(opts)
  mac_sim.up(opts.args)
end, { nargs = "?", desc = "Boot iOS simulator via mac-sim up" })

vim.api.nvim_create_user_command("MacSimDown", function()
  mac_sim.down()
end, { desc = "Shut down iOS simulator via mac-sim down" })

vim.api.nvim_create_user_command("MacSimResetPool", function()
  mac_sim.reset_pool()
end, { desc = "Release all simulator claims in the mac-sim pool" })

vim.api.nvim_create_user_command("MacSimShot", function(opts)
  mac_sim.shot(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Take screenshot of simulator" })

vim.api.nvim_create_user_command("MacSimPreview", function()
  mac_sim.preview_toggle()
end, { desc = "Toggle Xcode-style isolated SwiftUI canvas preview in split (<leader>mp)" })

vim.api.nvim_create_user_command("MacSimPreviewToggle", function()
  mac_sim.preview_toggle()
end, { desc = "Toggle Xcode-style isolated SwiftUI canvas preview in split (<leader>mp)" })

vim.api.nvim_create_user_command("MacSimPreviewRestart", function()
  mac_sim.preview_restart()
end, { desc = "Restart SwiftUI canvas preview daemon and force rebuild" })

vim.api.nvim_create_user_command("MacSimPreviewStop", function()
  mac_sim.close_preview()
end, { desc = "Stop SwiftUI canvas preview daemon and close split" })

vim.api.nvim_create_user_command("MacSimSetup", function()
  mac_sim.setup_remote()
end, { desc = "Deploy vendored axe & idb-companion to remote Mac (~/.local/lib/mac-sim/)" })

vim.api.nvim_create_user_command("MacSimClean", function()
  mac_sim.clean_remote()
end, { desc = "Clean remote binaries and preview cache on Mac" })
