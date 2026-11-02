---@brief
---
--- https://github.com/viperproject/viperserver
---
--- Language server for [Viper](https://www.pm.inf.ethz.ch/research/viper.html), a
--- verification infrastructure for permission-based reasoning developed at ETH Zurich.
--- Viper files use the `.vpr` (or `.sil`) extension.
---
--- ViperServer is the backend that drives the Viper IDE. It exposes an LSP interface
--- and is the recommended way to integrate Viper into editors other than VS Code.
---
--- ## Installation
---
--- Download the pre-built tools from the
--- [Viper IDE releases page](https://github.com/viperproject/viper-ide/releases).
--- The release archive contains:
---
--- - `backends/viperserver.jar` — the language server (requires Java ≥ 11)
--- - `z3/bin/z3` — the Z3 SMT solver (required by the Silicon backend)
--- - `boogie/` — the Boogie verifier (required by the Carbon backend)
---
--- Point the config at these paths via `viperserver_jar_path` and `z3_path` (and
--- optionally `boogie_path`):
---
--- ```lua
--- vim.lsp.config('viperserver', {
---   viperserver_jar_path = '/path/to/viperserver.jar',
---   z3_path              = '/path/to/z3',
---   boogie_path          = '/path/to/BoogieDriver', -- optional, needed for Carbon backend
--- })
--- ```
---
--- You also need to tell Neovim to recognise `.vpr` files:
---
--- ```lua
--- vim.filetype.add({ extension = { vpr = 'viper', sil = 'viper' } })
--- ```
---
--- ## Transport
---
--- ViperServer in LSP mode listens on a random TCP port and prints it to stdout as
--- `<ViperServerPort:PORT>`. This config spawns the server, parses that line, and
--- connects over TCP — matching the behaviour of the official VS Code extension.

---@type vim.lsp.Config
return {
  ---@param dispatchers vim.lsp.rpc.Dispatchers
  ---@param config vim.lsp.ClientConfig
  cmd = function(dispatchers, config)
    ---@diagnostic disable-next-line: undefined-field
    local jar = config.viperserver_jar_path
    if not jar or jar == '' then
      vim.notify(
        'viperserver: `viperserver_jar_path` is not set.\n'
          .. "Add `vim.lsp.config('viperserver', { viperserver_jar_path = '/path/to/viperserver.jar' })`"
          .. ' to your config.',
        vim.log.levels.ERROR
      )
      return
    end

    local java_bin = (vim.env.JAVA_HOME and (vim.env.JAVA_HOME .. '/bin/java')) or 'java'

    local server_cmd = { java_bin, '-jar', jar, '--serverMode', 'LSP', '--singleClient' }

    ---@diagnostic disable-next-line: undefined-field
    local z3 = config.z3_path
    if z3 and z3 ~= '' then
      vim.list_extend(server_cmd, { '--z3Exe', z3 })
    end

    ---@diagnostic disable-next-line: undefined-field
    local boogie = config.boogie_path
    if boogie and boogie ~= '' then
      vim.list_extend(server_cmd, { '--boogieExe', boogie })
    end

    -- ViperServer prints "<ViperServerPort:PORT>" then listens on that TCP port.
    -- We spawn it, read its stdout until we find the port, then connect via TCP.
    local port_found = false
    local stdout = vim.uv.new_pipe(false)
    local stderr = vim.uv.new_pipe(false)
    local handle

    handle = vim.uv.spawn(server_cmd[1], {
      args = vim.list_slice(server_cmd, 2),
      stdio = { nil, stdout, stderr },
      detached = false,
    }, function(code, _signal)
      if not port_found then
        vim.notify(
          'viperserver: process exited with code ' .. code .. ' before announcing its port.',
          vim.log.levels.ERROR
        )
      end
    end)

    if not handle then
      vim.notify('viperserver: failed to spawn `' .. server_cmd[1] .. '`. Is Java installed?', vim.log.levels.ERROR)
      return
    end

    -- Discard stderr (it only contains Akka/JVM warnings)
    stderr:read_start(function(_err, _data) end)

    -- Buffer stdout lines until we see the port announcement
    local buf = ''
    local conn_client

    stdout:read_start(function(err, data)
      if err or not data then
        return
      end
      buf = buf .. data
      -- ViperServer prints "<ViperServerPort:PORT>" followed by a newline
      local port_str = buf:match '<ViperServerPort:(%d+)>'
      if port_str and not port_found then
        port_found = true
        local port = tonumber(port_str)
        -- Connect via TCP; retry briefly in case the socket isn't bound yet
        vim.schedule(function()
          local attempts = 0
          local function try_connect()
            attempts = attempts + 1
            local ok, result = pcall(vim.lsp.rpc.connect, '127.0.0.1', port)
            if ok and result then
              conn_client = result(dispatchers)
            elseif attempts < 10 then
              vim.defer_fn(try_connect, 200)
            else
              vim.notify('viperserver: could not connect to TCP port ' .. port, vim.log.levels.ERROR)
            end
          end
          try_connect()
        end)
      end
    end)

    -- Return a client wrapper that forwards stop() to the process
    return {
      request = function(method, params, callback, notify_reply_callback)
        if conn_client then
          return conn_client.request(method, params, callback, notify_reply_callback)
        end
      end,
      notify = function(method, params)
        if conn_client then
          conn_client.notify(method, params)
        end
      end,
      is_closing = function()
        return conn_client and conn_client.is_closing() or false
      end,
      terminate = function()
        if conn_client then
          conn_client.terminate()
        end
        if handle and not handle:is_closing() then
          handle:kill('sigterm')
        end
      end,
    }
  end,
  filetypes = { 'viper' },
  root_markers = { '.git', '*.vpr', '*.sil' },
}
