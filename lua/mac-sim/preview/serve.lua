-- lua/mac-sim/preview/serve.lua
-- JSON Lines client for `axe preview serve`.

local config = require("mac-sim.config")

local M = {}

M.state = {
  job = nil,
  project = nil,
  stream_id = "mac-sim",
  stdout_buf = "",
  stderr = {},
  stopping = false,
  started_at = nil,
  generation = 0,
  sync_job = nil,
  sync_pending = nil,
}

local function shell_quote(value)
  return vim.fn.shellescape(value)
end

local function relpath(path, root)
  local rel = vim.fs.relpath(root, path)
  if not rel or rel:sub(1, 3) == "../" or rel == ".." then
    return nil
  end
  return rel
end

local function notify(message, level)
  vim.schedule(function()
    vim.notify("[mac-sim] " .. message, level or vim.log.levels.INFO)
  end)
end

local function log_stderr(lines)
  for _, line in ipairs(lines or {}) do
    if line:match("%S") then
      table.insert(M.state.stderr, line)
      if #M.state.stderr > 200 then
        table.remove(M.state.stderr, 1)
      end
    end
  end
end

function M.is_alive()
  if not M.state.job then
    return false
  end
  return vim.fn.jobwait({ M.state.job }, 0)[1] == -1
end

function M.project()
  return M.state.project
end

function M.remote_file(file)
  local project = M.state.project
  if not project then
    return nil
  end
  local rel = relpath(file, project.root)
  if not rel then
    return nil
  end
  return project.remote_root .. "/" .. rel
end

function M.send(command)
  if M.state.stopping or not M.is_alive() then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, command)
  if not ok then
    return false
  end
  local sent, wrote = pcall(vim.fn.chansend, M.state.job, encoded .. "\n")
  return sent and wrote > 0
end

local function handle_event(event, callbacks)
  if event.hello then
    local version = event.hello.protocolVersion or event.hello.protocol_version
    if version and version ~= 1 then
      notify("axe protocol version " .. tostring(version) .. " is not supported", vim.log.levels.ERROR)
    end
    return
  end

  if event.streamStatus then
    local phase = event.streamStatus.phase or ""
    if callbacks.on_status then
      callbacks.on_status(phase)
    end
    return
  end

  if event.streamStarted then
    if callbacks.on_started then
      callbacks.on_started(event.streamStarted.previewCount or 0)
    end
    return
  end

  if event.frame then
    local encoded = event.frame.data
    if not encoded or encoded == "" then
      return
    end
    local ok, bytes = pcall(vim.base64.decode, encoded)
    if ok and bytes and #bytes > 0 and callbacks.on_frame then
      callbacks.on_frame(bytes)
    end
    return
  end

  if event.diagnostic then
    if callbacks.on_diagnostic then
      callbacks.on_diagnostic(event.diagnostic.message or "")
    end
    return
  end

  if event.streamStopped then
    if callbacks.on_stopped then
      callbacks.on_stopped(
        event.streamStopped.reason or "stopped",
        event.streamStopped.message or "",
        event.streamStopped.diagnostic or "")
    end
    return
  end

  if event.protocolError then
    if callbacks.on_diagnostic then
      callbacks.on_diagnostic(event.protocolError.message or "")
    end
  end
end

local function handle_stdout(data, callbacks)
  if not data or #data == 0 then
    return
  end

  data[1] = M.state.stdout_buf .. data[1]
  M.state.stdout_buf = data[#data]

  for i = 1, #data - 1 do
    local line = data[i]
    if line:match("%S") then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then
        handle_event(event, callbacks)
      elseif callbacks.on_log then
        callbacks.on_log(line)
      end
    end
  end
end

local function prepare(file, device)
  local preview_bin = config.get_preview_bin_path()
  if vim.fn.filereadable(preview_bin) ~= 1 then
    return nil, "preview helper not found: " .. preview_bin
  end

  local previous_device = vim.env.MAC_SIM_DEVICE
  local selected = device
  if not selected or selected == "" then
    selected = config.values.device
  end
  if selected and selected ~= "" then
    vim.env.MAC_SIM_DEVICE = selected
  end

  local output = vim.fn.systemlist({ preview_bin, "--prepare", "--file", file })
  local code = vim.v.shell_error

  if previous_device == nil then
    vim.env.MAC_SIM_DEVICE = nil
  else
    vim.env.MAC_SIM_DEVICE = previous_device
  end

  if code ~= 0 or #output == 0 then
    local detail = table.concat(output, "\n")
    return nil, detail ~= "" and detail or "preview preparation failed"
  end

  local ok, project = pcall(vim.json.decode, output[#output])
  if not ok or type(project) ~= "table" then
    return nil, "preview preparation returned invalid JSON"
  end
  return project
end

local function ssh_command(project)
  local args = {
    "cd", shell_quote(project.remote_root),
    "&&", "export PATH=" .. shell_quote(project.remote_bin) .. ":$PATH",
    "&&", "exec", shell_quote(project.remote_axe),
    "preview", "serve",
    "--" .. project.container_kind, shell_quote(project.remote_container),
    "--scheme", shell_quote(project.scheme),
    "--root", shell_quote(project.remote_root),
    "--device", shell_quote(project.udid),
    "--snapshots",
    "--max-thunk-files", tostring(config.values.max_thunk_files or 1),
  }
  return table.concat(args, " ")
end

function M.start(file, callbacks, device)
  callbacks = callbacks or {}
  M.stop()

  local generation = M.state.generation + 1
  M.state.generation = generation

  local project, err = prepare(file, device)
  if not project then
    notify(err, vim.log.levels.ERROR)
    if callbacks.on_error then
      callbacks.on_error(err)
    end
    return false
  end

  M.state.project = project
  M.state.stream_id = "mac-sim"
  M.state.stdout_buf = ""
  M.state.stderr = {}
  M.state.stopping = false
  M.state.started_at = vim.uv.hrtime()

  local cmd = {
    "ssh",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" .. config.get_ssh_mux_path(),
    "-o", "ControlPersist=10m",
    "-o", "ConnectTimeout=5",
    project.host,
    ssh_command(project),
  }

  M.state.job = vim.fn.jobstart(cmd, {
    cwd = project.root,
    on_stdout = function(_, data)
      handle_stdout(data, callbacks)
    end,
    on_stderr = function(_, data)
      log_stderr(data)
      if callbacks.on_log then
        callbacks.on_log(data)
      end
    end,
    on_exit = function(_, code)
      if M.state.generation ~= generation then
        return
      end
      local intentional = M.state.stopping
      M.state.job = nil
      M.state.project = nil
      M.state.stdout_buf = ""
      if callbacks.on_exit then
        callbacks.on_exit(code, intentional)
      elseif code ~= 0 and not intentional then
        notify("preview server exited with code " .. code, vim.log.levels.ERROR)
      end
    end,
  })

  if M.state.job <= 0 then
    M.state.job = nil
    M.state.project = nil
    notify("could not start the preview server", vim.log.levels.ERROR)
    return false
  end

  local command = {
    streamId = M.state.stream_id,
    addStream = {
      file = project.remote_file,
      deviceType = "",
      runtime = "",
    },
  }
  M.send(command)
  return true
end

function M.switch_file(file)
  local remote = M.remote_file(file)
  if not remote then
    return false
  end
  return M.send({ streamId = M.state.stream_id, switchFile = { file = remote } })
end

function M.force_rebuild()
  return M.send({ streamId = M.state.stream_id, forceRebuild = vim.empty_dict() })
end

function M.sync_file(file, on_done)
  local project = M.state.project
  if not project then
    if on_done then on_done(false) end
    return false
  end

  -- Serialize syncs. A fast run of saves must not let an older copy
  -- overwrite the newest file on the Mac.
  if M.state.sync_job then
    M.state.sync_pending = { file = file, on_done = on_done }
    return true
  end

  local remote = M.remote_file(file)
  if not remote then
    if on_done then on_done(false) end
    return false
  end
  local remote_dir = vim.fs.dirname(remote)
  local ssh_opts = {
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=" .. config.get_ssh_mux_path(),
    "-o", "ControlPersist=10m",
  }

  local function finish(code)
    M.state.sync_job = nil
    local pending = M.state.sync_pending
    M.state.sync_pending = nil
    -- A superseded sync must not drive a file switch; the newer sync owns
    -- the current editor state.
    if on_done then
      on_done(code == 0 and pending == nil)
    end
    if pending then
      M.sync_file(pending.file, pending.on_done)
    end
  end

  local mkdir_cmd = { "ssh" }
  vim.list_extend(mkdir_cmd, ssh_opts)
  vim.list_extend(mkdir_cmd, {
    project.host,
    "mkdir -p " .. vim.fn.shellescape(remote_dir),
  })

  local mkdir_job = vim.fn.jobstart(mkdir_cmd, {
    on_exit = function(_, code)
      if code ~= 0 then
        finish(code)
        return
      end

      local scp_cmd = { "scp", "-q" }
      vim.list_extend(scp_cmd, ssh_opts)
      vim.list_extend(scp_cmd, { file, project.host .. ":" .. remote })

      local scp_job = vim.fn.jobstart(scp_cmd, {
        on_exit = function(_, copy_code)
          finish(copy_code)
        end,
      })
      if scp_job <= 0 then
        finish(1)
      else
        M.state.sync_job = scp_job
      end
    end,
  })
  if mkdir_job > 0 then
    M.state.sync_job = mkdir_job
  end
  return mkdir_job > 0
end

function M.stop()
  M.state.generation = M.state.generation + 1
  M.state.sync_pending = nil
  local job = M.state.job
  if not job then
    return
  end

  M.state.stopping = true
  pcall(vim.fn.chansend, job, vim.json.encode({
    streamId = M.state.stream_id,
    removeStream = vim.empty_dict(),
  }) .. "\n")
  -- Closing stdin is the protocol's shutdown signal. Give axe time to stop
  -- its idb companion before falling back to killing the SSH job; otherwise
  -- idb processes survive a preview close.
  pcall(vim.fn.chanclose, job, "stdin")
  local exited = vim.wait(1500, function()
    return vim.fn.jobwait({ job }, 0)[1] ~= -1
  end, 50)
  if not exited then
    vim.fn.jobstop(job)
  end
  M.state.job = nil
  M.state.project = nil
  M.state.stdout_buf = ""
end

function M.stderr_tail(limit)
  local count = math.min(limit or 20, #M.state.stderr)
  local start = #M.state.stderr - count + 1
  return table.concat(M.state.stderr, "\n", math.max(1, start))
end

return M
