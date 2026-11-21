-- lua/mac-sim/simulator.lua
-- Simulator lifecycle and pool management for tekibo/mac-sim.nvim

local config = require("mac-sim.config")

local M = {}

function M.status()
  config.mac_sim_job({ "mac-sim", "status" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        local output = table.concat(data, "\n")
        vim.notify(output, vim.log.levels.INFO, { title = "mac-sim status" })
      end
    end,
  })
end

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
  config.mac_sim_job(cmd, {
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

function M.down()
  vim.notify("[mac-sim] Stopping simulator...", vim.log.levels.INFO)
  config.mac_sim_job({ "mac-sim", "down" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        vim.notify(table.concat(data, "\n"), vim.log.levels.INFO)
      end
    end,
  })
end

function M.reset_pool()
  vim.notify("[mac-sim] Releasing simulator pool claims...", vim.log.levels.INFO)
  local script = 'state_dir="${MAC_SIM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/macbox/mac-sim}"; if [ -d "$state_dir/claims" ]; then for f in "$state_dir/claims/"*; do [ -f "$f" ] && d=$(basename "$f") && MAC_SIM_DEVICE="$d" mac-sim down >/dev/null 2>&1 || true; done; fi'
  vim.fn.jobstart({ "bash", "-c", script }, {
    on_exit = function()
      vim.notify("[mac-sim] Simulator pool claims released", vim.log.levels.INFO)
    end,
  })
end

function M.shot(path)
  path = path or vim.fs.joinpath(config.get_runtime_dir(), string.format("sim-shot-%d.png", os.time()))
  vim.notify("[mac-sim] Capturing screenshot to " .. path .. "...", vim.log.levels.INFO)
  config.mac_sim_job({ "mac-sim", "shot", path }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Screenshot saved: " .. path, vim.log.levels.INFO)
      else
        vim.notify("[mac-sim] Screenshot failed", vim.log.levels.ERROR)
      end
    end,
  })
end

return M
