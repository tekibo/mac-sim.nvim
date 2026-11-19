-- lua/mac-sim/runner.lua
-- Swift/SwiftUI build execution and remote tool management for tekibo/mac-sim.nvim

local config = require("mac-sim.config")
local simulator = require("mac-sim.simulator")
local viewer = require("mac-sim.viewer")

local M = {}

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
  if config.values.xtool_cmd then
    return type(config.values.xtool_cmd) == "table" and config.values.xtool_cmd or vim.split(config.values.xtool_cmd, "%s+")
  end
  if vim.fn.executable("idev") == 1 then
    return { "idev", "xtool", "dev", "build", "--triple", config.values.build_triple }
  end
  return { "xtool", "dev", "build", "--triple", config.values.build_triple }
end

function M.swift_run()
  local root = find_project_root()
  local p_type = detect_project_type(root)
  local name, bundle_id = get_project_meta(root)
  config.state.active_project = { root = root, name = name, bundle_id = bundle_id, p_type = p_type }

  vim.notify(string.format("[mac-sim] Building and launching %s...", name), vim.log.levels.INFO)

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
          config.mac_sim_job({ "mac-sim", "install", app_path }, {
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
                viewer.open(true)
              else
                local msg = #inst_errs > 0 and table.concat(inst_errs, "\n") or "mac-sim install failed"
                vim.notify("[mac-sim] " .. msg, vim.log.levels.ERROR)
              end
            end,
          })
        end,
      })
    else
      local xcmd = config.values.xcode_cmd or string.format("mac-sim mac 'xcodebuild -scheme %s build'", name)
      local cmd = type(xcmd) == "table" and xcmd or vim.split(xcmd, "%s+")
      vim.fn.jobstart(cmd, {
        cwd = root,
        on_exit = function(_, build_code)
          if build_code == 0 then
            vim.notify(string.format("[mac-sim] %s running on simulator", name), vim.log.levels.INFO)
            viewer.open(true)
          else
            vim.notify("[mac-sim] xcode build failed", vim.log.levels.ERROR)
          end
        end,
      })
    end
  end

  config.mac_sim_job({ "mac-sim", "status" }, {
    cwd = root,
    stdout_buffered = true,
    on_stdout = function(_, data)
      local text = table.concat(data or {}, "\n")
      local target = config.values.device or "slim-1"
      local is_up = text:find(target .. "%s*%(.-%)%s*:%s*up") ~= nil
      if is_up then
        do_build_and_launch()
      else
        simulator.up(nil, root, function(up_ok)
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
        simulator.up(nil, root, function(up_ok)
          if up_ok then do_build_and_launch() end
        end, true)
      end
    end,
  })
end

function M.swift_stop()
  local preview = require("mac-sim.preview")
  preview.stop_daemon()
  if config.state.active_project then
    local p = config.state.active_project
    if p and p.bundle_id and p.root then
      config.mac_sim_job({ "mac-sim", "mac", string.format("xcrun simctl terminate booted %s 2>/dev/null", p.bundle_id) }, {
        cwd = p.root,
      })
    end
    config.state.active_project = nil
    vim.notify("[mac-sim] App stopped", vim.log.levels.INFO)
  end
end

-- Deploy vendored axe and idb_companion to remote host
function M.setup_remote(cb)
  local root = config.get_plugin_root()
  local axe_bin = vim.fs.joinpath(root, "bin", "axe")
  local idb_bundle = vim.fs.joinpath(root, "bundles", "idb-companion.tar.gz")

  if vim.fn.filereadable(axe_bin) ~= 1 or vim.fn.filereadable(idb_bundle) ~= 1 then
    vim.notify("[mac-sim] Vendored binaries missing in plugin repository", vim.log.levels.ERROR)
    if cb then cb(false) end
    return
  end

  vim.notify("[mac-sim] Deploying axe & idb-companion to " .. config.values.ssh_host .. "...", vim.log.levels.INFO)

  local cmd = string.format(
    "ssh %s 'mkdir -p ~/.local/lib/mac-sim.nvim/bin ~/.local/lib/mac-sim.nvim/idb-companion ~/.local/bin' && " ..
    "scp %s %s:~/.local/lib/mac-sim.nvim/bin/axe && " ..
    "scp %s %s:~/.local/lib/mac-sim.nvim/ && " ..
    "ssh %s 'tar -xzf ~/.local/lib/mac-sim.nvim/idb-companion.tar.gz -C ~/.local/lib/mac-sim.nvim/idb-companion --strip-components=2 2>/dev/null || tar -xzf ~/.local/lib/mac-sim.nvim/idb-companion.tar.gz -C ~/.local/lib/mac-sim.nvim/idb-companion; " ..
    "rm -f ~/.local/lib/mac-sim.nvim/idb-companion.tar.gz; " ..
    "chmod +x ~/.local/lib/mac-sim.nvim/bin/axe ~/.local/lib/mac-sim.nvim/idb-companion/bin/idb_companion 2>/dev/null; " ..
    "ln -sf ~/.local/lib/mac-sim.nvim/bin/axe ~/.local/bin/axe; " ..
    "ln -sf ~/.local/lib/mac-sim.nvim/idb-companion/bin/idb_companion ~/.local/bin/idb_companion'",
    config.values.ssh_host,
    vim.fn.shellescape(axe_bin), config.values.ssh_host,
    vim.fn.shellescape(idb_bundle), config.values.ssh_host,
    config.values.ssh_host
  )

  vim.fn.jobstart({ "bash", "-c", cmd }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Remote tools deployed successfully to ~/.local/lib/mac-sim.nvim/", vim.log.levels.INFO)
        if cb then cb(true) end
      else
        vim.notify("[mac-sim] Remote tool deployment failed", vim.log.levels.ERROR)
        if cb then cb(false) end
      end
    end,
  })
end

-- Clean remote binaries and preview cache
function M.clean_remote(cb)
  vim.notify("[mac-sim] Cleaning remote tools and cache on " .. config.values.ssh_host .. "...", vim.log.levels.INFO)
  local cmd = string.format(
    "ssh %s 'rm -f ~/.local/bin/axe ~/.local/bin/idb_companion; " ..
    "rm -rf ~/.local/lib/mac-sim.nvim ~/Library/Caches/mac-sim.nvim ~/Library/Caches/axe ~/.cache/axe; " ..
    "xcrun simctl terminate booted all 2>/dev/null || true'",
    config.values.ssh_host
  )
  vim.fn.jobstart({ "bash", "-c", cmd }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("[mac-sim] Remote tools cleaned successfully", vim.log.levels.INFO)
        if cb then cb(true) end
      else
        vim.notify("[mac-sim] Failed to clean remote tools", vim.log.levels.ERROR)
        if cb then cb(false) end
      end
    end,
  })
end

return M
