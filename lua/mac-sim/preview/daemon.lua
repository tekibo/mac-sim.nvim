-- lua/mac-sim/preview/daemon.lua
-- Background daemon process management for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local render = require("mac-sim.preview.render")
local uv = vim.uv or vim.loop

local M = {}
local daemon_stdout_buf = ""
local daemon_stopping_intentionally = false

function M.is_alive()
  if not config.state.preview_daemon_job then
    return false
  end
  return vim.fn.jobwait({ config.state.preview_daemon_job }, 0)[1] == -1
end

function M.extract_clean_errors(lines)
  local clean = {}
  local seen = {}
  for _, line in ipairs(lines or {}) do
    if not line:match("^%s*Args:") and
       not line:match("^%s*Usage:") and
       not line:match("^%s*Flags:") and
       not line:match("^%s*Available Commands:") and
       not line:match("^%s*%[tryFastEmitLibrary%]") and
       not line:match("^%s*%[axe%-swiftc") and
       not line:match("^%s*xcrun swiftc") and
       not line:match("^%s*Daemon listening") and
       not line:match("^%s*exit status") then
      if line:match("error:") or line:match("Error:") then
        local trimmed = vim.trim(line)
        if not seen[trimmed] then
          seen[trimmed] = true
          table.insert(clean, trimmed)
        end
      end
    end
  end
  return clean
end

function M.handle_stdout(data, on_frame, on_error)
  if not data or #data == 0 then
    return
  end

  data[1] = daemon_stdout_buf .. data[1]
  daemon_stdout_buf = data[#data]

  for i = 1, #data - 1 do
    local line = data[i]
    if line:match("^FRAME ") then
      local b64 = line:sub(7):gsub("%s+", "")
      local ok, raw = pcall(vim.base64.decode, b64)
      if ok and raw and #raw > 0 then
        local next_file = render.get_next_preview_cache_file()
        local f = io.open(next_file, "wb")
        if f then
          f:write(raw)
          f:close()
        end

        config.state.current_cache_file = next_file

        local duration = ""
        if config.state.preview_reload_start_time then
          duration = string.format(" (%.2fs)", (uv.hrtime() - config.state.preview_reload_start_time) / 1e9)
          config.state.preview_reload_start_time = nil
        end
        config.state.preview_is_reloading = false

        if on_frame then
          on_frame(duration)
        end
      end
    elseif line:match("^ERROR ") then
      config.state.preview_is_reloading = false
      if on_error then
        on_error(line)
      else
        vim.schedule(function()
          vim.notify("[mac-sim] " .. line, vim.log.levels.WARN)
        end)
      end
    end
  end
end

function M.start(file, force_rebuild, quiet, on_frame, on_compile_error, on_exit)
  local preview_bin = config.get_preview_bin_path()
  if vim.fn.filereadable(preview_bin) ~= 1 then
    vim.notify("[mac-sim] Preview runner not found: " .. preview_bin, vim.log.levels.ERROR)
    return false
  end

  if not quiet then
    vim.notify("[mac-sim] Launching SwiftUI preview daemon...", vim.log.levels.INFO)
  end

  daemon_stopping_intentionally = false
  config.state.preview_reload_start_time = uv.hrtime()
  config.state.preview_is_reloading = true
  config.state.preview_daemon_file = file

  local errs = {}
  local recent_errs = {}
  local error_timer = nil

  config.state.preview_daemon_job = vim.fn.jobstart({ preview_bin, "--daemon", file, render.get_preview_cache_png() }, {
    env = {
      MAC_SIM_HOST = config.values.ssh_host or "macbox",
      MAC_SIM_DEVICE = config.values.device or "slim-1",
      MAC_SIM_REBUILD = force_rebuild and "1" or "0",
    },
    on_stdout = function(_, data)
      if data then
        M.handle_stdout(data, on_frame, on_compile_error)
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        for _, line in ipairs(data) do
          if line:match("%S") then
            table.insert(errs, line)
            table.insert(recent_errs, line)
            if #recent_errs > 80 then
              table.remove(recent_errs, 1)
            end
            if line:match("error:") or line:match("failed:") or line:match("Error:") then
              config.state.preview_is_reloading = false
              if error_timer then
                pcall(error_timer.stop, error_timer)
                pcall(error_timer.close, error_timer)
              end
              error_timer = vim.defer_fn(function()
                local clean = M.extract_clean_errors(recent_errs)
                if #clean > 0 and on_compile_error then
                  on_compile_error(clean)
                end
                recent_errs = {}
              end, 120)
            end
          end
        end
      end
    end,
    on_exit = function(_, code)
      if error_timer then
        pcall(error_timer.stop, error_timer)
        pcall(error_timer.close, error_timer)
        error_timer = nil
      end
      local was_intentional = daemon_stopping_intentionally
      config.state.preview_daemon_job = nil
      config.state.preview_daemon_file = nil
      config.state.preview_is_reloading = false
      daemon_stdout_buf = ""
      if code ~= 0 and not was_intentional then
        local clean = M.extract_clean_errors(errs)
        if #clean > 0 and on_compile_error then
          on_compile_error(clean)
        end
      end
      if on_exit then
        on_exit(code)
      end
    end,
  })

  return true
end

function M.push(remote_target, b64_content)
  if not M.is_alive() then
    return false
  end
  vim.fn.chansend(config.state.preview_daemon_job, string.format("push %s %s\n", remote_target, b64_content))
  return true
end

function M.stop()
  daemon_stopping_intentionally = true
  if config.state.preview_daemon_job then
    local job = config.state.preview_daemon_job
    config.state.preview_daemon_job = nil
    config.state.preview_daemon_file = nil
    config.state.preview_is_reloading = false
    config.state.preview_pending_reload = false
    daemon_stdout_buf = ""

    pcall(vim.fn.chansend, job, "quit\n")
    pcall(vim.fn.jobstop, job)
  end
end

-- Ensure preview daemon is cleanly terminated when Neovim exits
local cleanup_group = vim.api.nvim_create_augroup("MacSimDaemonGlobalCleanup", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = cleanup_group,
  callback = function()
    M.stop()
  end,
})

return M
