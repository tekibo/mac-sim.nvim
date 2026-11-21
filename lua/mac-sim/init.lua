-- lua/mac-sim/init.lua
-- Public API facade for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local simulator = require("mac-sim.simulator")
local viewer = require("mac-sim.viewer")
local runner = require("mac-sim.runner")
local preview = require("mac-sim.preview")

local M = {}

M.config = config.values
M.state = config.state

function M.setup(opts)
  config.setup(opts)
  M.config = config.values
  M.state = config.state

  local group = vim.api.nvim_create_augroup("MacSimDaemonCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      preview.stop_daemon()
    end,
  })
end

-- Simulator lifecycle
M.status = simulator.status
M.up = simulator.up
M.down = simulator.down
M.reset_pool = simulator.reset_pool
M.shot = simulator.shot

-- Desktop WebKitGTK and Expo Device Hub viewer
M.open = viewer.open
M.close = viewer.close
M.toggle = viewer.toggle
M.restart_hub = viewer.restart_hub
M.ensure_tunnel = viewer.ensure_tunnel
M.ensure_hub = viewer.ensure_hub
M.is_open = viewer.is_open

-- Swift project runner and remote management
M.swift_run = runner.swift_run
M.swift_stop = runner.swift_stop
M.setup_remote = runner.setup_remote
M.clean_remote = runner.clean_remote

-- Isolated SwiftUI canvas preview
M.preview_toggle = preview.toggle
M.preview_refresh = preview.refresh
M.preview_restart = preview.restart
M.close_preview = preview.close
M.is_preview_open = preview.is_open
M.stop_preview_daemon = preview.stop_daemon

return M
