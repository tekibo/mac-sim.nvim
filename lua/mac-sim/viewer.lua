-- lua/mac-sim/viewer.lua
-- Native WebKitGTK and Expo Device Hub viewer for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local uv = vim.uv or vim.loop

local M = {}

-- Asynchronous TCP check
local function check_port(port, cb)
  local client = uv.new_tcp()
  if not client then
    return cb(false)
  end
  client:connect("127.0.0.1", port, function(err)
    client:close()
    vim.schedule(function()
      cb(not err)
    end)
  end)
end

function M.get_view_pid()
  local pid_file = config.get_view_pid_file()
  local f = io.open(pid_file, "r")
  if not f then return nil end
  local content = f:read("*l")
  f:close()
  local pid = tonumber(content)
  if pid and uv.kill(pid, 0) == 0 then
    return pid
  end
  pcall(os.remove, pid_file)
  return nil
end

function M.is_open()
  return M.get_view_pid() ~= nil
end

-- Ensure background SSH tunnel is forwarding the port
function M.ensure_tunnel(cb)
  if not config.values.auto_tunnel then
    return cb(true)
  end

  check_port(config.values.port, function(open)
    if open then
      return cb(true)
    end

    local cmd = {
      "ssh", "-f", "-N",
      "-L", string.format("%d:127.0.0.1:%d", config.values.port, config.values.port),
      "-o", "ExitOnForwardFailure=yes",
      config.values.ssh_host,
    }

    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        if code == 0 then
          vim.defer_fn(function()
            check_port(config.values.port, cb)
          end, 200)
        else
          vim.notify("[mac-sim] Failed to establish SSH tunnel to " .. config.values.ssh_host, vim.log.levels.ERROR)
          cb(false)
        end
      end,
    })
  end)
end

-- Ensure Expo Device Hub is alive on remote host
function M.ensure_hub(cb, quiet)
  if not config.values.auto_hub then
    return cb(true)
  end

  local url = string.format("http://127.0.0.1:%d/api/devices", config.values.port)
  vim.fn.jobstart({ "curl", "-s", "-m", "1", "-o", "/dev/null", url }, {
    on_exit = function(_, code)
      if code == 0 then
        return cb(true)
      end

      if not quiet then
        vim.notify("[mac-sim] Starting Expo Device Hub on " .. config.values.ssh_host .. "...", vim.log.levels.INFO)
      end
      local remote_cmd = string.format(
        "nohup %s --port %d --platform ios > ~/.t3/hub.log 2>&1 &",
        config.values.hub_cmd,
        config.values.port
      )

      vim.fn.jobstart(config.ssh_cmd({ remote_cmd }), {
        on_exit = function(_, exit_code)
          if exit_code == 0 then
            vim.defer_fn(function()
              cb(true)
            end, 1000)
          else
            vim.notify("[mac-sim] Failed to start device hub on " .. config.values.ssh_host, vim.log.levels.ERROR)
            cb(false)
          end
        end,
      })
    end,
  })
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

      local bin = config.get_bin_path()
      local url = config.values.url or string.format("http://127.0.0.1:%d", config.values.port)
      local cmd = {
        bin,
        url,
        tostring(config.values.width),
        tostring(config.values.height),
        config.values.title,
      }

      vim.fn.jobstart(cmd, {
        detach = true,
      })
    end, quiet)
  end)
end

-- Close the native viewer window
function M.close()
  local pid = M.get_view_pid()
  if pid then
    uv.kill(pid, 15)
    pcall(os.remove, config.get_view_pid_file())
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
  vim.notify("[mac-sim] Restarting Expo Device Hub on " .. config.values.ssh_host .. "...", vim.log.levels.INFO)
  local remote_cmd = string.format(
    "pkill -f expo-device-hub 2>/dev/null; sleep 1; nohup %s --port %d --platform ios > ~/.t3/hub.log 2>&1 &",
    config.values.hub_cmd,
    config.values.port
  )

  vim.fn.jobstart(config.ssh_cmd({ remote_cmd }), {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Hub restarted. Taps and gestures resynced.", vim.log.levels.INFO)
      else
        vim.notify("[mac-sim] Failed to restart hub", vim.log.levels.ERROR)
      end
    end,
  })
end

return M
