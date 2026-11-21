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
  hub_cmd = nil,
  target_triple = nil,
  scheme = nil,
  device = nil,
  max_thunk_files = 1,
  show_timing = true,
}

M.values = vim.deepcopy(M.defaults)

M.state = {
  view_job = nil,
  active_project = nil,
  preview_win = nil,
  preview_buf = nil,
  preview_autocmd = nil,
  preview_placement = nil,
  preview_target = nil,
  preview_last_file = nil,
  preview_last_mtime = nil,
  preview_failure_notified = false,
  preview_pending_force = false,
  preview_reload_start_time = nil,
  preview_last_duration = "",
  preview_last_hash = nil,
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

local function version_key(path)
  local major, minor, patch = path:match("expo%-device%-hub@(%d+)%.(%d+)%.?(%d*)")
  if not major then
    return { 0, 0, 0 }
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) or 0 }
end

function M.get_hub_cmd()
  if M.values.hub_cmd then
    return M.values.hub_cmd
  end
  local matches = vim.fn.glob(
    "~/.t3/device/tools/expo-device-hub@*/node_modules/expo-device-hub/dist/server/cli.mjs",
    false, true)
  if #matches == 0 then
    return nil
  end
  table.sort(matches, function(a, b)
    local av, bv = version_key(a), version_key(b)
    for i = 1, 3 do
      if av[i] ~= bv[i] then
        return av[i] < bv[i]
      end
    end
    return a < b
  end)
  return "node " .. vim.fn.shellescape(matches[#matches])
end

function M.get_target_triple()
  if M.values.target_triple then
    return M.values.target_triple
  end
  local arch = vim.trim(vim.fn.system({ "ssh", M.values.ssh_host, "uname -m" }))
  if arch == "x86_64" then
    return "x86_64-apple-ios-simulator"
  end
  return "arm64-apple-ios-simulator"
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
  local root = opts.cwd or (M.state.active_project and M.state.active_project.root) or vim.fn.getcwd()
  opts.cwd = root
  local env = vim.tbl_extend("force", {}, opts.env or {})
  if M.values.device and M.values.device ~= "" then
    env["MAC_SIM_DEVICE"] = M.values.device
  end
  if next(env) ~= nil then
    opts.env = env
  else
    opts.env = nil
  end
  return vim.fn.jobstart(cmd, opts)
end

return M
