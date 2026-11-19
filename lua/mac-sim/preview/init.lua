-- lua/mac-sim/preview/init.lua
-- SwiftUI canvas preview window and orchestration for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local daemon = require("mac-sim.preview.daemon")
local render = require("mac-sim.preview.render")
local uv = vim.uv or vim.loop

local M = {}

local function get_remote_source_path(file)
  local dir = vim.fs.dirname(file)
  local package_file = vim.fs.find("Package.swift", { path = dir, upward = true })[1]
  if package_file then
    local package_dir = vim.fs.dirname(package_file)
    local rel = file:sub(#package_dir + 2)
    local rel_source = rel:match("^Sources/[^/]+/(.+)$")
    if rel_source then
      return "~/Library/Caches/mac-sim.nvim/sources/" .. rel_source
    end
  end
  return "~/Library/Caches/mac-sim.nvim/sources/" .. vim.fs.basename(file)
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
  vim.wo[p_win].winbar = "%#Comment# macsim://canvas [Compiling...]"

  config.state.preview_win = p_win
  config.state.preview_buf = p_buf

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
      local filename = vim.fs.basename(args.file or "")
      if filename == "Package.swift" then
        M.restart(false)
        return
      end
      M.refresh(true, false)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(p_win),
    callback = function()
      M.close()
    end,
  })
end

function M.close()
  daemon.stop()
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
  if M.is_open() then
    pcall(vim.api.nvim_win_close, config.state.preview_win, true)
  end
  config.state.preview_win = nil
  config.state.preview_buf = nil
end

function M.restart(quiet)
  if not quiet then
    vim.notify("[mac-sim] Restarting SwiftUI canvas preview (rebuilding)...", vim.log.levels.INFO)
  end
  daemon.stop()
  if config.state.preview_placement then
    pcall(function()
      local pl = config.state.preview_placement
      if type(pl) == "table" and type(pl.close) == "function" then
        pl:close()
      end
    end)
    config.state.preview_placement = nil
  end
  config.state.preview_last_file = nil
  config.state.preview_last_mtime = nil

  vim.defer_fn(function()
    M.refresh(false, true)
  end, 200)
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
  local mtime = stats and stats.mtime.sec or 0
  config.state.preview_last_file = file
  config.state.preview_last_mtime = mtime

  -- Case 1: Daemon already running (and not forced rebuild)
  if daemon.is_alive() and not force_rebuild then
    if config.state.preview_is_reloading then
      config.state.preview_pending_reload = true
      return
    end

    config.state.preview_is_reloading = true
    config.state.preview_reload_start_time = uv.hrtime()
    if M.is_open() and vim.api.nvim_win_is_valid(config.state.preview_win) then
      vim.wo[config.state.preview_win].winbar = "%#Comment# macsim://canvas [Compiling...]"
    end

    local remote_target = get_remote_source_path(file)

    local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    if #lines > 0 and lines[#lines] ~= "" then
      content = content .. "\n"
    end
    local b64 = vim.base64.encode(content)
    config.state.preview_daemon_file = file
    daemon.push(remote_target, b64)
    return
  end

  -- Case 2: Daemon not running -> start daemon
  if M.is_open() and vim.api.nvim_win_is_valid(config.state.preview_win) then
    vim.wo[config.state.preview_win].winbar = "%#Comment# macsim://canvas [Launching daemon...]"
  end

  daemon.start(
    file,
    force_rebuild,
    quiet,
    function(duration)
      vim.schedule(function()
        if M.is_open() and config.state.preview_buf then
          render.render_canvas_image(config.state.preview_buf)
          if vim.api.nvim_win_is_valid(config.state.preview_win) then
            vim.wo[config.state.preview_win].winbar = "%#Comment# macsim://canvas [Ready" .. duration .. "]"
          end
        end
        if config.state.preview_pending_reload then
          config.state.preview_pending_reload = false
          M.refresh(true, false)
        end
      end)
    end,
    function(errors)
      vim.schedule(function()
        config.state.preview_is_reloading = false
        if M.is_open() and vim.api.nvim_win_is_valid(config.state.preview_win) then
          vim.wo[config.state.preview_win].winbar = "%#ErrorMsg# macsim://canvas [Compile Error]"
          if config.state.preview_buf and vim.api.nvim_buf_is_valid(config.state.preview_buf) then
            render.render_error_buffer(config.state.preview_buf, errors)
          end
        else
          local primary = type(errors) == "table" and errors[1] or tostring(errors)
          local short_msg = primary:match("error: (.+)$") or primary
          vim.notify("[mac-sim] " .. short_msg, vim.log.levels.WARN)
        end
      end)
    end
  )
end

function M.toggle()
  if M.is_open() then
    M.close()
    vim.notify("[mac-sim] Canvas preview closed", vim.log.levels.INFO)
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(current_buf)
  if not file:match("%.swift$") then
    vim.notify("[mac-sim] Current buffer is not a Swift view file", vim.log.levels.WARN)
    return
  end

  local stats = uv.fs_stat(file)
  local mtime = stats and stats.mtime.sec or 0
  local target_cache = config.state.current_cache_file or render.get_preview_cache_png()
  local has_cache = vim.fn.filereadable(target_cache) == 1
  local is_unmodified = (config.state.preview_last_file == file) and (config.state.preview_last_mtime == mtime)

  if has_cache and is_unmodified and daemon.is_alive() then
    M.open_window()
    if config.state.preview_buf then
      render.render_canvas_image(config.state.preview_buf)
      if vim.api.nvim_win_is_valid(config.state.preview_win) then
        vim.wo[config.state.preview_win].winbar = "%#Comment# macsim://canvas [Ready (cached)]"
      end
    end
  else
    M.refresh(false, false)
  end
end

M.stop_daemon = daemon.stop

return M
