-- lua/mac-sim/preview/render.lua
-- Canvas fit calculation and image placement for tekibo/mac-sim.nvim

local config = require("mac-sim.config")

local M = {}
local preview_cache_seq = 0

function M.get_preview_cache_png()
  return vim.fs.joinpath(config.get_runtime_dir(), "preview.png")
end

function M.get_next_preview_cache_file()
  preview_cache_seq = (preview_cache_seq % 2) + 1
  return vim.fs.joinpath(config.get_runtime_dir(), string.format("preview_%d.png", preview_cache_seq))
end

function M.preseed_snacks_info(file_path)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.image then return end
  local cache_dir = snacks.image.config and snacks.image.config.cache or (vim.fn.stdpath("cache") .. "/snacks/image")
  if vim.fn.isdirectory(cache_dir) ~= 1 then
    pcall(vim.fn.mkdir, cache_dir, "p")
  end
  local base = vim.fn.fnamemodify(file_path, ":t:r")
  local prefix = vim.fn.sha256(file_path .. "0"):sub(1, 8) .. "-" .. base:gsub("[^%w%.]+", "-")
  local info_file = vim.fs.joinpath(cache_dir, prefix .. ".png.info")
  if vim.fn.filereadable(info_file) ~= 1 then
    local f = io.open(info_file, "w")
    if f then
      f:write("PNG 402x874 72x72\n")
      f:close()
    end
  end
end

function M.calculate_canvas_fit(win, img_w, img_h)
  img_w = img_w or 402
  img_h = img_h or 874
  local win_w = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_width(win) or 42
  local win_h = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_height(win) or 40

  local cell_w, cell_h = 11, 24
  local ok, term_mod = pcall(require, "snacks.image.terminal")
  if ok and term_mod and term_mod.size then
    local tsize = term_mod.size()
    if tsize.cell_width and tsize.cell_width > 0 then
      cell_w = tsize.cell_width
      cell_h = tsize.cell_height
    end
  end

  -- Native iPhone resolution is 402 x 874.
  -- In 11x24px cells, native 1x size is 402/11 = 36.5 cols by 874/24 = 36.4 rows.
  -- Cap maximum dimensions at native size (36x36) so the frame never blows up or enlarges.
  local max_cols = math.min(36, math.max(10, win_w - 2))
  local max_rows = math.min(36, math.max(10, win_h - 2))
  local cell_aspect = (img_w / img_h) * (cell_h / cell_w)

  local target_rows = max_rows
  local target_cols = math.floor(target_rows * cell_aspect)
  if target_cols > max_cols then
    target_cols = max_cols
    target_rows = math.floor(target_cols / cell_aspect)
  end

  target_cols = math.max(4, target_cols)
  target_rows = math.max(4, target_rows)
  local col_offset = math.max(0, math.floor((win_w - target_cols) / 2))

  return target_cols, target_rows, col_offset
end

function M.clear_canvas_image(buf)
  local ok, placement_mod = pcall(require, "snacks.image.placement")
  if ok and placement_mod and placement_mod.clean then
    pcall(placement_mod.clean, buf)
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
end

function M.render_error_buffer(buf, errors)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M.clear_canvas_image(buf)
  local canvas_ns = vim.api.nvim_create_namespace("mac_sim_canvas")
  vim.api.nvim_buf_clear_namespace(buf, canvas_ns, 0, -1)

  local err_lines = {}
  if type(errors) == "table" then
    err_lines = errors
  elseif type(errors) == "string" then
    for line in errors:gmatch("[^\r\n]+") do
      table.insert(err_lines, line)
    end
  end

  local lines = {
    "",
    "  SwiftUI Build Issue",
    "  " .. string.rep("-", 36),
    "",
  }
  local header_count = #lines
  for _, line in ipairs(err_lines) do
    table.insert(lines, "  " .. line)
  end
  table.insert(lines, "")
  table.insert(lines, "  " .. string.rep("-", 36))

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  pcall(function()
    vim.api.nvim_buf_add_highlight(buf, canvas_ns, "DiagnosticWarn", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, canvas_ns, "Comment", 2, 0, -1)
    for idx = header_count, #lines - 2 do
      local text = lines[idx + 1] or ""
      if text:match("error:") or text:match("Error:") then
        vim.api.nvim_buf_add_highlight(buf, canvas_ns, "DiagnosticError", idx, 0, -1)
      else
        vim.api.nvim_buf_add_highlight(buf, canvas_ns, "Comment", idx, 0, -1)
      end
    end
    vim.api.nvim_buf_add_highlight(buf, canvas_ns, "Comment", #lines - 1, 0, -1)
  end)
end

function M.render_canvas_image(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local target_file = config.state.current_cache_file or M.get_preview_cache_png()
  if vim.fn.filereadable(target_file) ~= 1 then
    return
  end

  -- Clear any previous text lines in canvas buffer
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false

  local win = config.state.preview_win
  local target_cols, target_rows, col_offset = M.calculate_canvas_fit(win, 402, 874)

  local ok, placement_mod = pcall(require, "snacks.image.placement")
  if ok and placement_mod then
    if placement_mod.clean then
      pcall(placement_mod.clean, buf)
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

    pcall(function()
      local img_mod = require("snacks.image.image")
      local images = rawget(img_mod, "images")
      if type(images) == "table" then
        images[target_file] = nil
        images[M.get_preview_cache_png()] = nil
      end
      if type(img_mod.clear) == "function" then
        img_mod.clear()
      end
    end)

    M.preseed_snacks_info(target_file)

    config.state.preview_placement = placement_mod.new(buf, target_file, {
      width = target_cols,
      height = target_rows,
      pos = { 1, col_offset },
      auto_resize = true,
      on_update = function(p)
        if not p or not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
        local valid_ids = {}
        for _, id in ipairs(p.eids or {}) do
          valid_ids[id] = true
        end
        local all_exts = vim.api.nvim_buf_get_extmarks(p.buf, placement_mod.ns, 0, -1, {})
        for _, ext in ipairs(all_exts) do
          if not valid_ids[ext[1]] then
            pcall(vim.api.nvim_buf_del_extmark, p.buf, placement_mod.ns, ext[1])
          end
        end
      end,
    })
  end
end

return M
