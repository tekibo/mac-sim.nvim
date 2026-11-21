-- lua/mac-sim/preview/render.lua
-- Canvas fit calculation and image placement for tekibo/mac-sim.nvim

local config = require("mac-sim.config")

local M = {}
local preview_cache_seq = 0

function M.get_preview_cache_png()
  return vim.fs.joinpath(config.get_runtime_dir(), "preview.png")
end

function M.get_next_preview_cache_file(ext)
  preview_cache_seq = (preview_cache_seq % 2) + 1
  return vim.fs.joinpath(config.get_runtime_dir(),
    string.format("preview_%d.%s", preview_cache_seq, ext or "png"))
end

local function be32(data, pos)
  return data:byte(pos) * 16777216 + data:byte(pos + 1) * 65536 +
    data:byte(pos + 2) * 256 + data:byte(pos + 3)
end

local function png_size(data)
  if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  return be32(data, 17), be32(data, 21)
end

local function jpeg_size(data)
  local i = 3
  while i + 8 <= #data do
    if data:byte(i) ~= 0xFF then
      i = i + 1
    else
      local marker = data:byte(i + 1)
      if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) then
        i = i + 2
      elseif marker == 0xDA then
        return nil
      else
        local length = data:byte(i + 2) * 256 + data:byte(i + 3)
        local is_sof = (marker >= 0xC0 and marker <= 0xC3) or
          (marker >= 0xC5 and marker <= 0xC7) or
          (marker >= 0xC9 and marker <= 0xCB) or
          (marker >= 0xCD and marker <= 0xCF)
        if is_sof then
          local h = data:byte(i + 5) * 256 + data:byte(i + 6)
          local w = data:byte(i + 7) * 256 + data:byte(i + 8)
          return w, h
        end
        i = i + 2 + length
      end
    end
  end
  return nil
end

function M.image_size(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read(65536) or ""
  file:close()

  local ok, w, h = pcall(png_size, data)
  if ok and w and h then
    return w, h
  end
  ok, w, h = pcall(jpeg_size, data)
  if ok and w and h then
    return w, h
  end
  return nil
end

function M.calculate_canvas_fit(win, img_w, img_h)
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

  if not img_w or not img_h or img_w <= 0 or img_h <= 0 then
    img_w, img_h = win_w * cell_w, win_h * cell_h
  end

  local max_cols = math.max(4, win_w - 2)
  local max_rows = math.max(4, win_h - 2)
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

function M.get_starting_png()
  return vim.fs.joinpath(config.get_plugin_root(), "assets", "canvas-starting.png")
end

function M.get_no_preview_png()
  return vim.fs.joinpath(config.get_plugin_root(), "assets", "canvas-no-preview.png")
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

-- Compiler errors are published to source buffers via vim.diagnostic.set.
-- The canvas window retains the last known good frame in place without wiping.
function M.render_error_buffer(buf, errors)
  -- Retain the existing image in place; winbar shows the error status
end

function M.render_canvas_image(buf, custom_image)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local target_file = custom_image or config.state.current_cache_file or M.get_preview_cache_png()
  if vim.fn.filereadable(target_file) ~= 1 then
    return
  end

  -- Clear any previous text lines in canvas buffer
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false

  local win = config.state.preview_win
  local img_w, img_h = M.image_size(target_file)
  local target_cols, target_rows, col_offset = M.calculate_canvas_fit(win, img_w, img_h)

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
        images[M.get_starting_png()] = nil
        images[M.get_no_preview_png()] = nil
      end
      if type(img_mod.clear) == "function" then
        img_mod.clear()
      end
    end)

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

function M.render_starting_screen(buf)
  M.render_canvas_image(buf, M.get_starting_png())
end

function M.render_no_preview_screen(buf)
  M.render_canvas_image(buf, M.get_no_preview_png())
end

return M
