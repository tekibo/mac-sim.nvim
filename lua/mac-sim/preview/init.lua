-- lua/mac-sim/preview/init.lua
-- SwiftUI canvas preview window and orchestration for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local render = require("mac-sim.preview.render")
local runner = require("mac-sim.runner")
local serve = require("mac-sim.preview.serve")
local uv = vim.uv or vim.loop

local M = {}

local diag_ns = vim.api.nvim_create_namespace("mac_sim_diagnostics")

local status_labels = {
  booting = "Booting",
  building = "Building",
  compiling_thunk = "Compiling",
  installing = "Installing",
  running = "Ready",
  degraded = "Degraded",
}

local function set_winbar(text, highlight)
  if not M.is_open() then
    return
  end
  local hl = highlight or "Comment"
  vim.wo[config.state.preview_win].winbar = "%#" .. hl .. "# macsim://canvas [" .. text .. "]"
end

local function mark_reload_start()
  config.state.preview_reload_start_time = uv.hrtime()
end

local function reload_duration()
  local started = config.state.preview_reload_start_time
  config.state.preview_reload_start_time = nil
  if not started then
    return ""
  end
  return string.format(" %.2fs", (uv.hrtime() - started) / 1e9)
end

local function set_source_diagnostics(message)
  vim.diagnostic.reset(diag_ns)
  if not message or message == "" then
    return
  end

  local diags_by_buf = {}
  for line in message:gmatch("[^\r\n]+") do
    local file, lnum, col, msg = line:match("^(.-):(%d+):(%d+):%s*error:%s*(.+)$")
    if file and lnum then
      local bufnr = vim.fn.bufnr(file)
      if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
        local base = vim.fs.basename(file)
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(b) and vim.fs.basename(vim.api.nvim_buf_get_name(b)) == base then
            bufnr = b
            break
          end
        end
      end
      if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
        diags_by_buf[bufnr] = diags_by_buf[bufnr] or {}
        table.insert(diags_by_buf[bufnr], {
          bufnr = bufnr,
          lnum = math.max(0, tonumber(lnum) - 1),
          col = math.max(0, tonumber(col) - 1),
          severity = vim.diagnostic.severity.ERROR,
          message = msg,
          source = "axe",
        })
      end
    end
  end

  for bufnr, items in pairs(diags_by_buf) do
    vim.diagnostic.set(diag_ns, bufnr, items, {})
  end
end

local function buffer_has_preview(buf)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find("#Preview", 1, true) then
      return true
    end
  end
  return false
end

local function buffer_hash(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

local function timing_suffix()
  if not config.values.show_timing then
    return ""
  end
  return config.state.preview_last_duration or ""
end

local function frame_extension(bytes)
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "png"
  end
  return "jpg"
end

local function show_frame(bytes)
  if not bytes or #bytes == 0 then
    return
  end
  local path = render.get_next_preview_cache_file(frame_extension(bytes))
  local file = io.open(path, "wb")
  if not file then
    return
  end
  file:write(bytes)
  file:close()

  config.state.current_cache_file = path
  config.state.preview_failure_notified = false

  if M.is_open() and config.state.preview_buf then
    render.render_canvas_image(config.state.preview_buf, path)
  end
end

local function notify_failure(message)
  if config.state.preview_failure_notified then
    return
  end
  config.state.preview_failure_notified = true
  vim.notify("[mac-sim] " .. message, vim.log.levels.ERROR)
end

local function server_callbacks()
  return {
    on_status = function(phase)
      vim.schedule(function()
        set_winbar(status_labels[phase] or phase)
      end)
    end,
    on_started = function()
      vim.schedule(function()
        pcall(vim.diagnostic.reset, diag_ns)
        set_winbar("Ready")
        if config.state.preview_pending_force then
          config.state.preview_pending_force = false
          serve.force_rebuild()
        end
      end)
    end,
    on_frame = function(bytes)
      vim.schedule(function()
        local duration = reload_duration()
        if duration ~= "" then
          config.state.preview_last_duration = duration
        end
        show_frame(bytes)
        set_winbar("Ready" .. (config.values.show_timing and duration or ""))
      end)
    end,
    on_diagnostic = function(message)
      vim.schedule(function()
        config.state.preview_reload_start_time = nil
        set_source_diagnostics(message)
        set_winbar("Error", "ErrorMsg")
      end)
    end,
    on_stopped = function(reason, message, diagnostic)
      vim.schedule(function()
        config.state.preview_reload_start_time = nil
        if reason ~= "removed" then
          set_winbar("Stopped", "ErrorMsg")
          if diagnostic and diagnostic ~= "" then
            set_source_diagnostics(diagnostic)
          end
          notify_failure(message ~= "" and message or ("preview stopped: " .. reason))
        end
      end)
    end,
    on_exit = function(code, intentional)
      if code ~= 0 and not intentional then
        notify_failure("preview server exited with code " .. code)
      end
    end,
  }
end

local function start_server(file, force_rebuild)
  config.state.preview_target = file
  config.state.preview_failure_notified = false
  config.state.preview_reload_start_time = nil
  config.state.preview_pending_force = force_rebuild or false
  local buf = vim.fn.bufnr(file)
  if buf > 0 then
    config.state.preview_last_hash = buffer_hash(buf)
  end
  set_winbar("Claiming simulator")

  local root = runner.find_project_root(file)
  runner.ensure_simulator(root, function(ok, udid)
    if not ok then
      config.state.preview_pending_force = false
      set_winbar("No Simulator", "ErrorMsg")
      return
    end

    set_winbar("Starting")
    if not serve.start(file, server_callbacks(), udid) then
      config.state.preview_pending_force = false
      set_winbar("Error", "ErrorMsg")
    end
  end)
end

function M.is_open()
  return config.state.preview_win ~= nil and vim.api.nvim_win_is_valid(config.state.preview_win)
end

local function create_canvas_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "macsim_canvas"
  return buf
end

function M.open_window()
  if M.is_open() then
    return
  end

  local orig_win = vim.api.nvim_get_current_win()
  vim.cmd("silent! vertical botright split")
  local p_win = vim.api.nvim_get_current_win()
  local p_buf = create_canvas_buffer()
  vim.api.nvim_win_set_buf(p_win, p_buf)

  vim.wo[p_win].number = false
  vim.wo[p_win].relativenumber = false
  vim.wo[p_win].signcolumn = "no"
  vim.wo[p_win].foldcolumn = "0"
  vim.wo[p_win].wrap = false
  vim.wo[p_win].cursorline = false
  vim.wo[p_win].cursorcolumn = false
  vim.wo[p_win].winfixwidth = true
  pcall(vim.api.nvim_win_set_width, p_win, 42)
  vim.wo[p_win].winbar = "%#Comment# macsim://canvas [Starting]"

  config.state.preview_win = p_win
  config.state.preview_buf = p_buf
  render.render_starting_screen(p_buf)

  if vim.api.nvim_win_is_valid(orig_win) then
    vim.api.nvim_set_current_win(orig_win)
  end

  local group = vim.api.nvim_create_augroup("MacSimPreviewAuto", { clear = true })
  config.state.preview_autocmd = vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.swift",
    callback = function(args)
      if not M.is_open() then
        return
      end
      if vim.fs.basename(args.file or "") == "Package.swift" then
        M.restart(true)
        return
      end

      local has_preview = false
      for _, line in ipairs(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)) do
        if line:find("#Preview", 1, true) then
          has_preview = true
          break
        end
      end

      local current_hash = buffer_hash(args.buf)
      local changed = current_hash ~= config.state.preview_last_hash
      config.state.preview_last_hash = current_hash
      local same_target = config.state.preview_target == args.file

      if not changed then
        if has_preview and not same_target then
          -- A different target can legitimately have the same content hash;
          -- fall through and switch to it.
        elseif same_target then
          set_winbar("Ready" .. timing_suffix() .. " (unchanged)")
          return
        else
          return
        end
      end

      local stats = uv.fs_stat(args.file)
      config.state.preview_last_file = args.file
      config.state.preview_last_mtime = stats and stats.mtime.sec or 0

      mark_reload_start()
      set_winbar("Compiling")
      serve.sync_file(args.file, function(ok)
        if not ok then
          config.state.preview_reload_start_time = nil
          config.state.preview_last_hash = nil
          notify_failure("could not sync " .. vim.fs.basename(args.file))
          return
        end

        if has_preview then
          config.state.preview_target = args.file
          serve.switch_file(args.file)
        elseif config.state.preview_target then
          -- Reload the active preview so changed dependencies are picked up
          -- even when the edited file has no #Preview block.
          serve.switch_file(config.state.preview_target)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(p_win),
    callback = function()
      M.hide()
    end,
  })
end

-- Hide the canvas but keep the server, simulator, and warm app alive.
function M.hide()
  if config.state.preview_autocmd then
    pcall(vim.api.nvim_del_autocmd, config.state.preview_autocmd)
    config.state.preview_autocmd = nil
  end
  if config.state.preview_placement then
    pcall(function()
      local pl = config.state.preview_placement
      if type(pl) == "table" and type(pl.close) == "function" then
        pl:close()
      end
    end)
    config.state.preview_placement = nil
  end
  local win = config.state.preview_win
  config.state.preview_win = nil
  config.state.preview_buf = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

-- Stop the preview server and close the canvas.
function M.close()
  serve.stop()
  config.state.preview_reload_start_time = nil
  M.hide()
  config.state.preview_target = nil
end

function M.restart(quiet)
  local file = config.state.preview_target
  if not file then
    local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if current:match("%.swift$") then
      file = current
    end
  end
  if not file then
    if not quiet then
      vim.notify("[mac-sim] No SwiftUI canvas to restart", vim.log.levels.WARN)
    end
    return
  end
  if not M.is_open() then
    M.open_window()
  end

  serve.stop()
  start_server(file, true)
end

function M.refresh(quiet, force_rebuild)
  local current_buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(current_buf)
  if not file:match("%.swift$") then
    if not quiet then
      vim.notify("[mac-sim] Current buffer is not a Swift view file", vim.log.levels.WARN)
    end
    return
  end

  if not M.is_open() then
    M.open_window()
  end

  local stats = uv.fs_stat(file)
  config.state.preview_last_file = file
  config.state.preview_last_mtime = stats and stats.mtime.sec or 0

  if not buffer_has_preview(current_buf) then
    if config.state.preview_buf then
      render.render_no_preview_screen(config.state.preview_buf)
    end
    set_winbar("No #Preview")
    return
  end

  if serve.is_alive() and not force_rebuild and serve.remote_file(file) then
    local current_hash = buffer_hash(current_buf)
    local changed = current_hash ~= config.state.preview_last_hash
    local same_target = config.state.preview_target == file

    if not changed and same_target and config.state.current_cache_file
        and vim.fn.filereadable(config.state.current_cache_file) == 1 then
      set_winbar("Ready" .. timing_suffix())
      return
    end

    config.state.preview_last_hash = current_hash
    mark_reload_start()
    set_winbar("Compiling")
    serve.sync_file(file, function(ok)
      if not ok then
        config.state.preview_reload_start_time = nil
        config.state.preview_last_hash = nil
        notify_failure("could not sync " .. vim.fs.basename(file))
        return
      end
      if changed or not same_target then
        config.state.preview_target = file
        serve.switch_file(file)
      end
    end)
    return
  end
  if serve.is_alive() then
    serve.stop()
  end

  start_server(file, force_rebuild)
end

function M.toggle()
  if M.is_open() then
    M.hide()
    return
  end

  local file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if not file:match("%.swift$") then
    vim.notify("[mac-sim] Current buffer is not a Swift view file", vim.log.levels.WARN)
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local unchanged = serve.is_alive()
    and config.state.preview_target == file
    and config.state.preview_last_hash == buffer_hash(current_buf)
    and config.state.current_cache_file
    and vim.fn.filereadable(config.state.current_cache_file) == 1

  M.open_window()
  if unchanged then
    render.render_canvas_image(config.state.preview_buf, config.state.current_cache_file)
    set_winbar("Ready" .. timing_suffix())
    return
  end

  M.refresh(false, false)
end

M.stop_daemon = serve.stop

return M
