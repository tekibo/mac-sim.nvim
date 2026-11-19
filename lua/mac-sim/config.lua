-- lua/mac-sim/config.lua
-- Configuration and shared state for tekibo/mac-sim.nvim

local M = {}

M.defaults = {
  port = 3400,
  width = 410,
  height = 820,
  title = "iOS Simulator",
  ssh_host = "macbox",
  url = nil,
  auto_hub = true,
  auto_tunnel = true,
  hub_cmd = "node ~/.t3/device/tools/expo-device-hub@0.24.0/node_modules/expo-device-hub/dist/server/cli.mjs",
  build_triple = "x86_64-apple-ios-simulator",
  device = "slim-1",
}

M.values = vim.deepcopy(M.defaults)

M.state = {
  view_job = nil,
  active_project = nil,
  preview_win = nil,
  preview_buf = nil,
  preview_autocmd = nil,
  preview_daemon_job = nil,
  preview_daemon_file = nil,
  preview_placement = nil,
  preview_last_file = nil,
  preview_last_mtime = nil,
  preview_is_reloading = false,
  preview_pending_reload = false,
  preview_reload_start_time = nil,
  current_cache_file = nil,
}

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

function M.get_plugin_root()
  local info = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
end

function M.get_bin_path()
  return vim.fs.joinpath(M.get_plugin_root(), "bin", "mac-sim-view")
end

function M.get_preview_bin_path()
  return vim.fs.joinpath(M.get_plugin_root(), "bin", "mac-sim-preview")
end

function M.get_runtime_dir()
  local base = os.getenv("XDG_RUNTIME_DIR") or vim.fn.expand("~/.cache")
  local dir = vim.fs.joinpath(base, "mac-sim.nvim")
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

function M.get_view_pid_file()
  return vim.fs.joinpath(M.get_runtime_dir(), "view.pid")
end

function M.get_ssh_mux_path()
  return vim.fs.joinpath(M.get_runtime_dir(), "ssh_mux")
end

function M.ssh_cmd(args)
  local base = {
    "ssh",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" .. M.get_ssh_mux_path(),
    "-o", "ControlPersist=10m",
    "-o", "ConnectTimeout=2",
    M.values.ssh_host,
  }
  for _, a in ipairs(args) do
    table.insert(base, a)
  end
  return base
end

function M.mac_sim_job(cmd, opts)
  opts = opts or {}
  local env = opts.env or {}
  if M.values.device and M.values.device ~= "" then
    env["MAC_SIM_DEVICE"] = M.values.device
  end
  opts.env = env
  return vim.fn.jobstart(cmd, opts)
end

return M
