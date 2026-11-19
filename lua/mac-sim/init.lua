-- lua/mac-sim/init.lua
-- Core plugin module for tekibo/mac-sim.nvim

local M = {}
local uv = vim.uv or vim.loop

M.config = {
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
  live_reload = true,
  device = "slim-1",
}

M.state = {
  view_job = nil,
  active_project = nil,
  live_autocmd = nil,
  is_reloading = false,
}

-- Resolve absolute path to bin/mac-sim-view
local function get_bin_path()
  local info = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  return vim.fs.joinpath(root, "bin", "mac-sim-view")
end

local function get_inject_bin()
  local info = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  local bin = vim.fs.joinpath(root, "bin", "mac-sim-inject")
  if vim.fn.executable(bin) == 1 then
    return bin
  end
  local host_bin = vim.fn.exepath("mac-sim-inject")
  if host_bin ~= "" then
    return host_bin
  end
  return bin
end

local function get_bridge_bin()
  local info = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  return vim.fs.joinpath(root, "bin", "mac-sim-bridge")
end

local function get_bundle_dir()
  local info = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  return vim.fs.joinpath(root, "bundles", "iOSInjection.bundle")
end

local function mac_sim_job(cmd, opts)
  opts = opts or {}
  local env = opts.env or {}
  if M.config.device and M.config.device ~= "" then
    env["MAC_SIM_DEVICE"] = M.config.device
  end
  opts.env = env
  return vim.fn.jobstart(cmd, opts)
end

local function ssh_cmd(args)
  local base = {
    "ssh",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=/tmp/mac_sim_ssh_mux",
    "-o", "ControlPersist=10m",
    "-o", "ConnectTimeout=2",
    M.config.ssh_host,
  }
  for _, a in ipairs(args) do
    table.insert(base, a)
  end
  return base
end

local function scp_cmd(src, dest, recursive)
  local base = {
    "scp",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=/tmp/mac_sim_ssh_mux",
    "-o", "ControlPersist=10m",
    "-o", "ConnectTimeout=2",
    "-q",
  }
  if recursive then
    table.insert(base, "-r")
  end
  table.insert(base, src)
  table.insert(base, dest)
  return base
end

local function ensure_remote_bundle(cb)
  local check = ssh_cmd({ "test -d ~/.mac-sim/bundles/iOSInjection.bundle" })
  vim.fn.jobstart(check, {
    on_exit = function(_, code)
      if code == 0 then
        return cb(true)
      end

      local local_bundle = get_bundle_dir()
      if vim.fn.isdirectory(local_bundle) ~= 1 then
        return cb(true)
      end

      local prep = ssh_cmd({ "mkdir -p ~/.mac-sim/bundles" })
      vim.fn.jobstart(prep, {
        on_exit = function()
          local copy = scp_cmd(local_bundle, string.format("%s:~/.mac-sim/bundles/", M.config.ssh_host), true)
          vim.fn.jobstart(copy, {
            on_exit = function()
              cb(true)
            end,
          })
        end,
      })
    end,
  })
end

-- Ensure hot-reload bridge daemon is alive on Macbox
function M.ensure_bridge(cb)
  ensure_remote_bundle(function()
    local check = ssh_cmd({ "test -S /tmp/hotreload_control.sock" })
    vim.fn.jobstart(check, {
      on_exit = function(_, code)
        if code == 0 then
          return cb(true)
        end

        local bridge_src = get_bridge_bin()
        local prep = ssh_cmd({ "mkdir -p ~/.mac-sim/bin" })
        vim.fn.jobstart(prep, {
          on_exit = function()
            local copy = scp_cmd(bridge_src, string.format("%s:~/.mac-sim/bin/mac-sim-bridge", M.config.ssh_host), false)
            vim.fn.jobstart(copy, {
              on_exit = function(_, scp_code)
                if scp_code ~= 0 then
                  vim.notify("[mac-sim] Warning: Failed to copy bridge to " .. M.config.ssh_host, vim.log.levels.WARN)
                  return cb(false)
                end
                local start = ssh_cmd({ "chmod +x ~/.mac-sim/bin/mac-sim-bridge; pkill -9 -f mac-sim-bridge 2>/dev/null || true; nohup /usr/bin/python3 -u ~/.mac-sim/bin/mac-sim-bridge > /tmp/injection_bridge.log 2>&1 &" })
                vim.fn.jobstart(start, {
                  on_exit = function(_, start_code)
                    vim.defer_fn(function()
                      cb(start_code == 0)
                    end, 600)
                  end,
                })
              end,
            })
          end,
        })
      end,
    })
  end)
end

-- Asynchronous TCP check
local function check_port(port, cb)
  local client = uv.new_tcp()
  client:connect("127.0.0.1", port, function(err)
    client:close()
    vim.schedule(function()
      cb(not err)
    end)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.live_reload then
    M.enable_live_reload()
  end
end

-- Ensure background SSH tunnel is forwarding the port
function M.ensure_tunnel(cb)
  if not M.config.auto_tunnel then
    return cb(true)
  end

  check_port(M.config.port, function(open)
    if open then
      return cb(true)
    end

    local cmd = {
      "ssh", "-f", "-N",
      "-L", string.format("%d:127.0.0.1:%d", M.config.port, M.config.port),
      "-o", "ExitOnForwardFailure=yes",
      M.config.ssh_host,
    }

    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        if code == 0 then
          vim.defer_fn(function()
            check_port(M.config.port, cb)
          end, 200)
        else
          vim.notify("[mac-sim] Failed to establish SSH tunnel to " .. M.config.ssh_host, vim.log.levels.ERROR)
          cb(false)
        end
      end,
    })
  end)
end

-- Ensure Expo Device Hub is alive on Macbox
function M.ensure_hub(cb, quiet)
  if not M.config.auto_hub then
    return cb(true)
  end

  local url = string.format("http://127.0.0.1:%d/api/devices", M.config.port)
  vim.fn.jobstart({ "curl", "-s", "-m", "1", "-o", "/dev/null", url }, {
    on_exit = function(_, code)
      if code == 0 then
        return cb(true)
      end

      if not quiet then
        vim.notify("[mac-sim] Starting Expo Device Hub on " .. M.config.ssh_host .. "...", vim.log.levels.INFO)
      end
      local remote_cmd = string.format(
        "nohup %s --port %d --platform ios > ~/.t3/hub.log 2>&1 &",
        M.config.hub_cmd,
        M.config.port
      )

      vim.fn.jobstart(ssh_cmd({ remote_cmd }), {
        on_exit = function(_, exit_code)
          if exit_code == 0 then
            vim.defer_fn(function()
              cb(true)
            end, 1000)
          else
            vim.notify("[mac-sim] Failed to start device hub on " .. M.config.ssh_host, vim.log.levels.ERROR)
            cb(false)
          end
        end,
      })
    end,
  })
end

local PID_FILE = "/tmp/mac-sim-view.pid"

local function get_view_pid()
  local f = io.open(PID_FILE, "r")
  if not f then return nil end
  local content = f:read("*l")
  f:close()
  local pid = tonumber(content)
  if pid and uv.kill(pid, 0) == 0 then
    return pid
  end
  pcall(os.remove, PID_FILE)
  return nil
end

function M.is_open()
  return get_view_pid() ~= nil
end

-- Open the native WebKitGTK window (detached from terminal session)
function M.open(quiet)
  if M.is_open() then
    if not quiet then
      vim.notify("[mac-sim] Simulator viewer is already running", vim.log.levels.WARN)
    end
    return
  end

  M.ensure_tunnel(function(tunnel_ok)
    if not tunnel_ok then return end

    M.ensure_hub(function(hub_ok)
      if not hub_ok then return end

      local bin = get_bin_path()
      local url = M.config.url or string.format("http://127.0.0.1:%d", M.config.port)
      local cmd = {
        bin,
        url,
        tostring(M.config.width),
        tostring(M.config.height),
        M.config.title,
      }

      vim.fn.jobstart(cmd, {
        detach = true,
      })
    end, quiet)
  end)
end

-- Close the native viewer window
function M.close()
  local pid = get_view_pid()
  if pid then
    uv.kill(pid, 15)
    pcall(os.remove, PID_FILE)
    vim.notify("[mac-sim] Simulator viewer closed", vim.log.levels.INFO)
  else
    vim.notify("[mac-sim] No active simulator viewer to close", vim.log.levels.WARN)
  end
end

-- Toggle viewer window
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Restart hub to fix desynced touches
function M.restart_hub()
  vim.notify("[mac-sim] Restarting Expo Device Hub on " .. M.config.ssh_host .. "...", vim.log.levels.INFO)
  local remote_cmd = string.format(
    "pkill -f expo-device-hub 2>/dev/null; sleep 1; nohup %s --port %d --platform ios > ~/.t3/hub.log 2>&1 &",
    M.config.hub_cmd,
    M.config.port
  )

  vim.fn.jobstart(ssh_cmd({ remote_cmd }), {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Hub restarted. Taps/gestures resynced.", vim.log.levels.INFO)
      else
        vim.notify("[mac-sim] Failed to restart hub", vim.log.levels.ERROR)
      end
    end,
  })
end

-- Check mac-sim status
function M.status()
  mac_sim_job({ "mac-sim", "status" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        local output = table.concat(data, "\n")
        vim.notify(output, vim.log.levels.INFO, { title = "mac-sim status" })
      end
    end,
  })
end

-- Boot simulator
function M.up(kind, cwd, cb, quiet)
  if type(kind) == "function" then
    cb = kind
    kind = nil
    cwd = nil
  elseif type(cwd) == "function" then
    cb = cwd
    cwd = nil
  end
  local cmd = { "mac-sim", "up" }
  if kind and kind ~= "" then
    table.insert(cmd, kind)
  end
  if not quiet then
    vim.notify("[mac-sim] Booting simulator...", vim.log.levels.INFO)
  end
  local err_lines = {}
  mac_sim_job(cmd, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local text = table.concat(data, "\n")
        if text:gsub("%s+", "") ~= "" then
          table.insert(err_lines, text)
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 and #err_lines > 0 then
        vim.notify("[mac-sim] " .. table.concat(err_lines, "\n"), vim.log.levels.ERROR)
      elseif not quiet and code == 0 then
        vim.notify("[mac-sim] Simulator booted", vim.log.levels.INFO)
      end
      if cb then cb(code == 0) end
    end,
  })
end

-- Shut down simulator
function M.down()
  vim.notify("[mac-sim] Stopping simulator...", vim.log.levels.INFO)
  mac_sim_job({ "mac-sim", "down" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        vim.notify(table.concat(data, "\n"), vim.log.levels.INFO)
      end
    end,
  })
end

-- Release all pool claims
function M.reset_pool()
  vim.notify("[mac-sim] Releasing simulator pool claims...", vim.log.levels.INFO)
  local script = "for d in slim-1 slim-2 full sharp small; do MAC_SIM_DEVICE=$d mac-sim down >/dev/null 2>&1 || true; done"
  vim.fn.jobstart({ "bash", "-c", script }, {
    on_exit = function()
      vim.notify("[mac-sim] Simulator pool claims released", vim.log.levels.INFO)
    end,
  })
end

-- Take screenshot to /tmp or given path
function M.shot(path)
  path = path or string.format("/tmp/sim-shot-%d.png", os.time())
  vim.notify("[mac-sim] Capturing screenshot to " .. path .. "...", vim.log.levels.INFO)
  mac_sim_job({ "mac-sim", "shot", path }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Screenshot saved: " .. path, vim.log.levels.INFO)
      else
        vim.notify("[mac-sim] Screenshot failed", vim.log.levels.ERROR)
      end
    end,
  })
end

-- -----------------------------------------------------------------------------
-- Swift / SwiftUI Live Hot-Reload Support (xtool / Xcode)
-- -----------------------------------------------------------------------------

local function find_project_root(buf_file)
  local file = buf_file or vim.api.nvim_buf_get_name(0)
  -- 1. If buffer has a file, walk upward from buffer's directory
  if file and file ~= "" then
    local abs_file = vim.fn.fnamemodify(file, ":p")
    local start_dir = vim.fs.dirname(abs_file)
    local root = vim.fs.root(start_dir, { "Package.swift", "xtool.yml", "*.xcodeproj", "*.xcworkspace" })
    if root then
      return root
    end
  end

  -- 2. Check getcwd() itself
  local cwd = vim.fn.getcwd()
  local root = vim.fs.root(cwd, { "Package.swift", "xtool.yml", "*.xcodeproj", "*.xcworkspace" })
  if root then
    return root
  end

  -- 3. Monorepo downward search: check common monorepo locations (apps/ios, ios, etc.)
  for _, sub in ipairs({ "apps/ios", "ios", "apple", "App" }) do
    local sub_dir = vim.fs.joinpath(cwd, sub)
    if vim.fn.filereadable(vim.fs.joinpath(sub_dir, "Package.swift")) == 1 or
       vim.fn.filereadable(vim.fs.joinpath(sub_dir, "xtool.yml")) == 1 then
      return sub_dir
    end
  end

  -- 4. Deep search for Package.swift or xtool.yml in subdirectories
  local matches = vim.fs.find({ "Package.swift", "xtool.yml" }, { path = cwd, type = "file", limit = 1, upward = false })
  if #matches > 0 then
    return vim.fs.dirname(matches[1])
  end

  return cwd
end

local function detect_project_type(root)
  if vim.fn.filereadable(vim.fs.joinpath(root, "xtool.yml")) == 1 then
    return "xtool"
  end
  local xcode_proj = vim.fs.find(function(name)
    return name:match("%.xcodeproj$") or name:match("%.xcworkspace$")
  end, { path = root, type = "directory" })
  if #xcode_proj > 0 then
    return "xcode"
  end
  return "xtool"
end

local function get_project_meta(root)
  local name = vim.fs.basename(root)
  local bundle_id = "com.macsim." .. string.lower(name:gsub("[^%w]", ""))

  local xtool_path = vim.fs.joinpath(root, "xtool.yml")
  if vim.fn.filereadable(xtool_path) == 1 then
    for _, line in ipairs(vim.fn.readfile(xtool_path)) do
      local id = line:match("^bundleID:%s*(%S+)")
      if id then
        bundle_id = id
        break
      end
    end
  end

  local pkg_path = vim.fs.joinpath(root, "Package.swift")
  if vim.fn.filereadable(pkg_path) == 1 then
    for _, line in ipairs(vim.fn.readfile(pkg_path)) do
      local pkg_name = line:match('name:%s*"([^"]+)"')
      if pkg_name then
        name = pkg_name
        break
      end
    end
  end

  return name, bundle_id
end

local function get_xtool_app_path(root, name)
  local direct = vim.fs.joinpath(root, "xtool", name .. ".app")
  if vim.fn.isdirectory(direct) == 1 then
    return direct
  end
  local found = vim.fs.find(function(entry) return entry:match("%.app$") end, { path = vim.fs.joinpath(root, "xtool"), type = "directory" })
  if #found > 0 then
    return found[1]
  end
  return direct
end

local function get_xtool_build_cmd()
  if M.config.xtool_cmd then
    return type(M.config.xtool_cmd) == "table" and M.config.xtool_cmd or vim.split(M.config.xtool_cmd, "%s+")
  end
  if vim.fn.executable("idev") == 1 then
    return { "idev", "xtool", "dev", "build", "--triple", M.config.build_triple }
  end
  return { "xtool", "dev", "build", "--triple", M.config.build_triple }
end

function M.swift_reload(opt_root, opt_file)
  if M.state.is_reloading then return end

  local root = opt_root or (M.state.active_project and M.state.active_project.root) or find_project_root()
  local p_type = detect_project_type(root)
  local name, bundle_id = get_project_meta(root)
  M.state.active_project = { root = root, name = name, bundle_id = bundle_id, p_type = p_type }

  local p = M.state.active_project
  M.state.is_reloading = true

  if p.p_type == "xtool" then
    local inject_bin = get_inject_bin()
    local cmd = { inject_bin, p.root, p.name, M.config.build_triple }
    if opt_file then
      table.insert(cmd, opt_file)
    end
    local err_lines = {}
    vim.fn.jobstart(cmd, {
      cwd = p.root,
      stderr_buffered = true,
      on_stderr = function(_, data)
        if data and #data > 0 then
          local text = table.concat(data, "\n")
          if text:gsub("%s+", "") ~= "" then
            table.insert(err_lines, text)
          end
        end
      end,
      on_exit = function(_, code)
        M.state.is_reloading = false
        if code == 0 then
          vim.api.nvim_echo({ { "[mac-sim] ", "Title" }, { "live reloaded " .. p.name, "Normal" } }, false, {})
        else
          local msg = #err_lines > 0 and table.concat(err_lines, "\n") or "Live injection failed"
          vim.notify("[mac-sim] " .. msg, vim.log.levels.WARN)
        end
      end,
    })
  else
    local xcmd = M.config.xcode_cmd or string.format("mac-sim mac 'xcodebuild -scheme %s build'", p.name)
    local cmd = type(xcmd) == "table" and xcmd or vim.split(xcmd, "%s+")
    vim.fn.jobstart(cmd, {
      cwd = p.root,
      on_exit = function(_, code)
        M.state.is_reloading = false
        if code == 0 then
          vim.api.nvim_echo({ { "[mac-sim] ", "Title" }, { "reloaded " .. p.name, "Normal" } }, false, {})
        else
          vim.notify("[mac-sim] Reload build failed", vim.log.levels.WARN)
        end
      end,
    })
  end
end

function M.enable_live_reload(root)
  if M.state.live_autocmd then
    pcall(vim.api.nvim_del_autocmd, M.state.live_autocmd)
  end

  local group = vim.api.nvim_create_augroup("MacSimLiveReload", { clear = true })
  M.state.live_autocmd = vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.swift",
    callback = function(ev)
      local buf_path = ev.file or vim.api.nvim_buf_get_name(0)
      local full_buf_path = vim.fn.fnamemodify(buf_path, ":p")
      local proj_root = root or find_project_root(full_buf_path)
      local full_proj_root = vim.fn.fnamemodify(proj_root, ":p")
      if not root or vim.startswith(full_buf_path, full_proj_root) then
        M.swift_reload(proj_root, full_buf_path)
      end
    end,
  })
end

function M.disable_live_reload()
  if M.state.live_autocmd then
    pcall(vim.api.nvim_del_autocmd, M.state.live_autocmd)
    M.state.live_autocmd = nil
  end
  M.config.live_reload = false
  vim.notify("[mac-sim] Live reload disabled", vim.log.levels.INFO)
end

function M.toggle_live_reload()
  if M.state.live_autocmd then
    M.disable_live_reload()
  else
    M.config.live_reload = true
    M.enable_live_reload()
    vim.notify("[mac-sim] Live reload enabled", vim.log.levels.INFO)
  end
end

function M.init_project()
  local root = find_project_root()
  local name = select(1, get_project_meta(root))
  local info = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(info)))
  local template_src = vim.fs.joinpath(plugin_root, "templates", "HotReload.swift")

  local target_dir = vim.fs.joinpath(root, "Sources", name)
  if vim.fn.isdirectory(target_dir) ~= 1 then
    if vim.fn.isdirectory(vim.fs.joinpath(root, "Sources")) == 1 then
      target_dir = vim.fs.joinpath(root, "Sources")
    else
      target_dir = root
    end
  end

  local dest = vim.fs.joinpath(target_dir, "HotReload.swift")
  if vim.fn.filereadable(dest) ~= 1 and vim.fn.filereadable(template_src) == 1 then
    local lines = vim.fn.readfile(template_src)
    vim.fn.writefile(lines, dest)
    vim.notify(string.format("[mac-sim] Created %s", dest), vim.log.levels.INFO)
  else
    vim.notify(string.format("[mac-sim] %s already exists", dest), vim.log.levels.INFO)
  end

  local pkg_path = vim.fs.joinpath(root, "Package.swift")
  if vim.fn.filereadable(pkg_path) == 1 then
    local content = table.concat(vim.fn.readfile(pkg_path), "\n")
    if not content:find("-interposable") then
      vim.notify("[mac-sim] Note: Add .unsafeFlags([\"-Xlinker\", \"-interposable\"]) to target linkerSettings in Package.swift for live hot-reload support.", vim.log.levels.WARN)
    end
  end

  M.ensure_bridge(function(ok)
    if ok then
      vim.notify("[mac-sim] Hot reload initialized and Macbox bridge ready.", vim.log.levels.INFO)
    else
      vim.notify("[mac-sim] Hot reload initialized, but bridge setup failed on Macbox.", vim.log.levels.WARN)
    end
  end)
end

function M.swift_run()
  local root = find_project_root()
  local p_type = detect_project_type(root)
  local name, bundle_id = get_project_meta(root)
  M.state.active_project = { root = root, name = name, bundle_id = bundle_id, p_type = p_type }

  vim.notify(string.format("[mac-sim] Building & launching %s...", name), vim.log.levels.INFO)

  local function do_build_and_launch()
    if p_type == "xtool" then
      local build_cmd = get_xtool_build_cmd()
      local build_errs = {}
      vim.fn.jobstart(build_cmd, {
        cwd = root,
        stderr_buffered = true,
        on_stderr = function(_, data)
          if data and #data > 0 then
            local text = table.concat(data, "\n")
            if text:gsub("%s+", "") ~= "" then
              table.insert(build_errs, text)
            end
          end
        end,
        on_exit = function(_, build_code)
          if build_code ~= 0 then
            local msg = #build_errs > 0 and table.concat(build_errs, "\n") or "xtool build failed"
            vim.notify("[mac-sim] " .. msg, vim.log.levels.ERROR)
            return
          end

          local app_path = get_xtool_app_path(root, name)
          local inst_errs = {}
          mac_sim_job({ "mac-sim", "install", app_path }, {
            cwd = root,
            stderr_buffered = true,
            on_stderr = function(_, data)
              if data and #data > 0 then
                local text = table.concat(data, "\n")
                if text:gsub("%s+", "") ~= "" then
                  table.insert(inst_errs, text)
                end
              end
            end,
            on_exit = function(_, install_code)
              if install_code == 0 then
                vim.notify(string.format("[mac-sim] %s running on simulator", name), vim.log.levels.INFO)
                M.open(true)
                if M.config.live_reload then
                  M.enable_live_reload(root)
                end
              else
                local msg = #inst_errs > 0 and table.concat(inst_errs, "\n") or "mac-sim install failed"
                vim.notify("[mac-sim] " .. msg, vim.log.levels.ERROR)
              end
            end,
          })
        end,
      })
    else
      local xcmd = M.config.xcode_cmd or string.format("mac-sim mac 'xcodebuild -scheme %s build'", name)
      local cmd = type(xcmd) == "table" and xcmd or vim.split(xcmd, "%s+")
      vim.fn.jobstart(cmd, {
        cwd = root,
        on_exit = function(_, build_code)
          if build_code == 0 then
            vim.notify(string.format("[mac-sim] %s running on simulator", name), vim.log.levels.INFO)
            M.open(true)
            if M.config.live_reload then
              M.enable_live_reload(root)
            end
          else
            vim.notify("[mac-sim] xcode build failed", vim.log.levels.ERROR)
          end
        end,
      })
    end
  end

  M.ensure_bridge(function(bridge_ok)
    if not bridge_ok then
      vim.notify("[mac-sim] Bridge unreachable on " .. M.config.ssh_host, vim.log.levels.ERROR)
      return
    end

    mac_sim_job({ "mac-sim", "status" }, {
      cwd = root,
      stdout_buffered = true,
      on_stdout = function(_, data)
        local text = table.concat(data or {}, "\n")
        local target = M.config.device or "slim-1"
        local is_up = text:find(target .. "%s*%(.-%)%s*:%s*up") ~= nil
        if is_up then
          do_build_and_launch()
        else
          M.up(nil, root, function(up_ok)
            if up_ok then
              do_build_and_launch()
            else
              vim.notify("[mac-sim] Failed to boot simulator", vim.log.levels.ERROR)
            end
          end, true)
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          M.up(nil, root, function(up_ok)
            if up_ok then do_build_and_launch() end
          end, true)
        end
      end,
    })
  end)
end

function M.swift_stop()
  if M.state.live_autocmd then
    pcall(vim.api.nvim_del_autocmd, M.state.live_autocmd)
    M.state.live_autocmd = nil
  end
  if M.state.active_project then
    local p = M.state.active_project
    mac_sim_job({ "mac-sim", "mac", string.format("xcrun simctl terminate booted %s 2>/dev/null", p.bundle_id) }, {
      cwd = p.root,
    })
    M.state.active_project = nil
    vim.notify("[mac-sim] Live reload stopped", vim.log.levels.INFO)
  end
end

return M
