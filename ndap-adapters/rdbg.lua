-- Ruby - https://github.com/ruby/debug (the `debug` gem, driven by `rdbg`)
--
-- `rdbg --open --port N` is a TCP DAP server, not a stdio adapter, and it starts
-- the debuggee itself: the program is already loaded and stopped by the time a
-- client connects. So the request body names no program - the command line does
-- - and every mode is a DAP `attach`, which is the request the gem reads
-- `nonstop` from (a `launch` forces nonstop, and could never stop at entry). The
-- keys the gem's DAP server actually reads are `localfs`, `localfsMap` and
-- `nonstop`; see `process_request` in lib/debug/server_dap.rb.

-- Where to look for rdbg, in order; the first executable wins. Put your own path
-- first to pin it. "$VAR" and "~" expand anywhere in an entry, as they do in
-- `vim.fs.normalize`; an entry naming an unset or empty variable is skipped. A
-- bare name (no separator) is looked up on $PATH.
local rdbg_bins = {
    "rdbg",
    "$GEM_HOME/bin/rdbg",
    "$GEM_ROOT/bin/rdbg",
}

-- The interface rdbg binds its debug port to, and the host ndap then connects
-- to. rdbg binds every interface when left to itself, which is more than a local
-- debug session needs.
local rdbg_host = "127.0.0.1"

-- Ruby boots the whole application before the port is announced, which under
-- bundler in a large project is not always quick.
local rdbg_start_timeout_ms = 10000

---The first candidate that is executable.
---@return string? rdbg, string[] tried
local function _resolve_rdbg()
    local shared = require("ndap.shared")
    return shared.resolve_path(rdbg_bins, shared.is_executable)
end

---Start `rdbg --open`, wait for its "Debugger can attach via TCP/IP (host:port)"
---line, and point the connection at that endpoint.
---@param parameters   table            the mode's answered inputs
---@param command_mode boolean          rdbg's `--command`, for a program on $PATH
---@param config       ndap.dap.Config
---@param ctx          ndap.AdapterSetupCtx
---@param callback     fun(err?: string, state?: any)
local function _spawn_rdbg(parameters, command_mode, config, ctx, callback)
    local shared = require("ndap.shared")
    local rdbg, tried = _resolve_rdbg()
    if not rdbg then
        return callback("rdbg not found (install the debug gem, e.g. `gem install debug`); tried " ..
            table.concat(tried, ", "))
    end
    -- `bundle exec` so the debuggee runs under the project's own bundle, which is
    -- also the only way the gem is loadable when it is a Gemfile dependency.
    local cmd = parameters.use_bundler and { "bundle", "exec", rdbg } or { rdbg }
    vim.list_extend(cmd, { "--open", "--host", rdbg_host, "--port", tostring(shared.free_port()) })
    -- Command mode: the target is a program on $PATH (rspec, rake, ruby itself)
    -- rather than a Ruby script rdbg loads.
    if command_mode then table.insert(cmd, "--command") end
    vim.list_extend(cmd, parameters.rdbg_args or {})
    -- Everything past `--` is the debuggee, so an argument of its own that starts
    -- with a dash is never read as an rdbg flag.
    table.insert(cmd, "--")
    local program, args = shared.split_command(parameters.command)
    table.insert(cmd, program)
    vim.list_extend(cmd, args)

    local resolved = false
    local called   = false
    local handle
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    handle = shared.spawn(cmd, {
        bufname       = ctx.make_buf_name("server"),
        cwd           = shared.normalize_path(parameters.cwd) or config.cwd or vim.fn.getcwd(),
        env           = parameters.env,
        -- The announcement shares a pty with the debuggee's own output, so only
        -- whole lines are matched against.
        line_buffered = true,
        on_stdout     = function(_, data)
            if resolved then return end
            for _, line in ipairs(data) do
                -- "DEBUGGER: Debugger can attach via TCP/IP (127.0.0.1:12345)"
                -- (.+) is greedy so it captures up to the last colon (IPv6-safe).
                local h, p = line:match("Debugger can attach via TCP/IP %((.+):(%d+)%)")
                if h and p then
                    resolved    = true
                    -- An IPv6 address is announced bracketed, as a socket address.
                    config.host = h:match("^%[(.*)%]$") or h
                    config.port = tonumber(p)
                    done(nil, { handle = handle })
                    return
                end
            end
        end,
        on_exit       = function()
            if not resolved then done("rdbg exited before reporting a debug port") end
        end,
    })
    if not handle then return callback("failed to start rdbg") end
    ctx.add_bufnr(handle.bufnr, { label = "rdbg", priority = -2 })
    ctx.report("rdbg: waiting for the debug port")
    vim.defer_fn(function()
        if resolved then return end
        -- Handed back with the error so `teardown` stops it.
        done(("rdbg did not report a debug port within %d s"):format(rdbg_start_timeout_ms / 1000),
            { handle = handle })
    end, rdbg_start_timeout_ms)
end

---Fields every mode accepts. `stop_on_entry` is the readable half of the
---gem's `nonstop`: rdbg has already stopped the program at load by the time we
---connect, and `nonstop` says whether to let it go once breakpoints are set.
---@type table<string, ndap.Input>
local _common_inputs = {
    stop_on_entry = { type = "boolean", description = "stay stopped where rdbg loaded the program, instead of continuing" },
}

---Fields the two spawning modes share, on top of the common set. `env` reaches the
---debuggee through rdbg, which starts it.
---@type table<string, ndap.Input>
local _spawn_inputs = {
    cwd         = { type = "string", completion = "dir", description = "working directory" },
    env         = { type = "map", description = "environment variables the debuggee is started with" },
    use_bundler = { type = "boolean", description = "run under `bundle exec`" },
    rdbg_args   = { type = "list", description = "extra flags for rdbg itself, e.g. --session-name=api" },
}

---@param parameters table<string, any>
---@return table params
local function _common_body(parameters)
    local params = {}
    params.nonstop = not parameters.stop_on_entry
    return params
end

---The body shared by `script` and `command`: rdbg loads the debuggee itself, so
---the body names no program, and `setup` takes command mode off `ctx.mode`.
---@param parameters table<string, any>
---@return table params
local function _spawn_body(parameters)
    local params = _common_body(parameters)
    -- We started the debuggee ourselves, so its paths are this machine's paths.
    params.localfs = true
    return params
end

---@type table<string, ndap.Mode>
local _modes = {
    -- One `command` input carries the whole command line; `setup` starts it under
    -- rdbg, which loads and stops it before we connect.
    script = {
        description = "debug a Ruby script",
        request = "attach",
        inputs = vim.tbl_extend("error", _common_inputs, _spawn_inputs, {
            command = { type = "string", completion = "command", required = true, description = "Ruby script to debug, plus its arguments" },
        }),
        build = _spawn_body,
    },
    -- The same thing in rdbg's command mode, for the case the script form cannot
    -- express: a program on $PATH rather than a .rb file - `rspec spec/foo_spec.rb`,
    -- `rake test`, `ruby -Itest test/foo_test.rb`.
    command = {
        description = "debug a Ruby command - rspec, rake, ruby itself",
        request = "attach",
        inputs = vim.tbl_extend("error", _common_inputs, _spawn_inputs, {
            command = { type = "string", completion = "command", required = true, description = "command to debug, plus its arguments" },
        }),
        build = _spawn_body,
    },
    -- Nothing is started here: the debuggee was opened elsewhere, with
    -- `rdbg --open --port ...` or `RUBY_DEBUG_OPEN=true`. Its paths are its own,
    -- so unless it shares this filesystem, `path_mappings` is what makes
    -- breakpoints land.
    remote = {
        description = "attach to an rdbg server already listening on host/port",
        request = "attach",
        inputs = vim.tbl_extend("error", _common_inputs, {
            host          = { type = "string", description = "rdbg server host (default 127.0.0.1)" },
            port          = { type = "integer", required = true, description = "rdbg server port" },
            local_fs      = { type = "boolean", description = "the debuggee shares this filesystem (default true)" },
            path_mappings = { type = "map", completion = "dir", description = "source path mappings, remote=local" },
        }),
        build = function(parameters)
            local shared = require("ndap.shared")
            local port, err = shared.resolve_port(parameters.port)
            if err then return nil, err end
            local params = _common_body(parameters)
            local path_mappings = parameters.path_mappings and vim.tbl_map(shared.normalize_path, parameters.path_mappings)
            if path_mappings then
                -- The gem takes one string of "remote:local" pairs and matches by
                -- prefix, first hit winning, so the longest prefix goes first -
                -- otherwise a mapping for a parent directory shadows its children.
                local remotes = vim.tbl_keys(path_mappings)
                table.sort(remotes, function(a, b) return #a > #b end)
                local pairs_ = vim.tbl_map(function(remote)
                    return remote .. ":" .. path_mappings[remote]
                end, remotes)
                params.localfsMap = table.concat(pairs_, ",")
            else
                params.localfs = parameters.local_fs == nil and true or parameters.local_fs
            end
            -- Already listening: the connection is all this mode adds to the body.
            return params, { host = parameters.host or rdbg_host, port = port }
        end,
    },
}

---@type ndap.AdapterDef
return {
    -- `script` and `command` start the debuggee here, from the inputs `build` was
    -- resolved with. `remote` finds a server already running, its connection
    -- arriving on the task.
    setup = function(config, ctx, callback)
        local mode, parameters = ctx.mode, ctx.parameters
        if (mode == "script" or mode == "command") and parameters then
            return _spawn_rdbg(parameters, mode == "command", config, ctx, callback)
        end
        callback()
    end,
    teardown = function(_, state) if state and state.handle then state.handle.stop() end end,
    modes = _modes,
}
