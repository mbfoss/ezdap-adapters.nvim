-- Ruby — https://github.com/ruby/debug (the `debug` gem, driven by `rdbg`)
--
-- `rdbg --open --port N` is a TCP DAP server, not a stdio adapter, and it starts
-- the debuggee itself: the program is already loaded and stopped by the time a
-- client connects. So the request body names no program — the command line does
-- — and every mode is a DAP `attach`, which is the request the gem reads
-- `nonstop` from (a `launch` forces nonstop, and could never stop at entry). The
-- keys the gem's DAP server actually reads are `localfs`, `localfsMap` and
-- `nonstop`; see `process_request` in lib/debug/server_dap.rb.

-- Set to an rdbg path to skip detection entirely; otherwise the first candidate
-- below that is executable wins.
local rdbg_bin = nil ---@type string?

-- Where to look for rdbg, in order. A leading "$" names an environment variable,
-- skipped when unset; "~" expands to the home directory. A bare name (no
-- separator) is looked up on $PATH.
local rdbg_bins = {
    "rdbg",
    "$GEM_HOME/bin/rdbg",
    "$GEM_ROOT/bin/rdbg",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", "rdbg"),
}

-- The interface rdbg binds its debug port to, and the host ezdap then connects
-- to. rdbg binds every interface when left to itself, which is more than a local
-- debug session needs.
local rdbg_host = "127.0.0.1"

-- Ruby boots the whole application before the port is announced, which under
-- bundler in a large project is not always quick.
local rdbg_start_timeout_ms = 10000

---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end

---Where a mode's `build` leaves what `setup` needs — the command line to
---start, or the endpoint to dial. Nothing here belongs in the request body: it
---describes how the session is *reached*, which is settled before the body is
---sent, so `setup` consumes the key and drops it.
local RDBG_KEY = "__rdbg"

---The configured rdbg, or the first candidate that is executable.
---@return string? rdbg, string[] tried
local function _resolve_rdbg()
    local shared = require("ezdap.shared")
    if rdbg_bin then return rdbg_bin, { rdbg_bin } end
    return shared.resolve_path(rdbg_bins, shared.is_executable)
end

---Start `rdbg --open`, wait for its "Debugger can attach via TCP/IP (host:port)"
---line, and point the connection at that endpoint.
---@param spec    table            the `build`-supplied spawn description
---@param config  ezdap.dap.Config
---@param ctx     ezdap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _spawn_rdbg(spec, config, ctx, callback)
    local shared = require("ezdap.shared")
    local rdbg, tried = _resolve_rdbg()
    if not rdbg then
        return callback("rdbg not found (install the debug gem, e.g. `gem install debug`); tried " ..
            table.concat(tried, ", "))
    end
    -- `bundle exec` so the debuggee runs under the project's own bundle, which is
    -- also the only way the gem is loadable when it is a Gemfile dependency.
    local cmd = spec.use_bundler and { "bundle", "exec", rdbg } or { rdbg }
    vim.list_extend(cmd, { "--open", "--host", rdbg_host, "--port", tostring(_free_port()) })
    -- Command mode: the target is a program on $PATH (rspec, rake, ruby itself)
    -- rather than a Ruby script rdbg loads.
    if spec.command_mode then table.insert(cmd, "--command") end
    vim.list_extend(cmd, spec.rdbg_args or {})
    -- Everything past `--` is the debuggee, so an argument of its own that starts
    -- with a dash is never read as an rdbg flag.
    table.insert(cmd, "--")
    table.insert(cmd, spec.program)
    vim.list_extend(cmd, spec.args or {})

    local resolved = false
    local called   = false
    local handle
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    handle = shared.spawn(cmd, {
        bufname       = shared.unique_buf_name("ezdap://" ..
            (config.name or config.adapter or "debug") .. "_rdbg"),
        cwd           = spec.cwd or config.cwd or vim.fn.getcwd(),
        env           = spec.env,
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
        if not resolved then
            done(("rdbg did not report a debug port within %d s"):format(rdbg_start_timeout_ms / 1000))
        end
    end, rdbg_start_timeout_ms)
end

---Fields every mode accepts. `stop_on_entry` is the readable half of the
---gem's `nonstop`: rdbg has already stopped the program at load by the time we
---connect, and `nonstop` says whether to let it go once breakpoints are set.
---@type table<string, ezdap.Input>
local _common_inputs = {
    stop_on_entry = { type = "boolean", description = "stay stopped where rdbg loaded the program, instead of continuing" },
}

---Fields the two spawning modes share, on top of the common set.
---@type table<string, ezdap.Input>
local _spawn_inputs = {
    cwd         = { type = "string", completion = "dir", description = "working directory" },
    env         = { type = "map", description = "environment variables" },
    use_bundler = { type = "boolean", description = "run under `bundle exec`" },
    rdbg_args   = { type = "list", description = "extra flags for rdbg itself, e.g. --session-name=api" },
}

---A mode's inputs: the always-accepted set plus whichever groups apply.
---@param ... table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_common_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---@param inputs table<string, any>
---@return table params
local function _common_body(inputs)
    local params = {}
    params.nonstop = not inputs.stop_on_entry
    return params
end

---The body and spawn description shared by `script`/`command`,
---which differ only in whether rdbg is put in command mode.
---@param inputs  table<string, any>
---@param command_mode boolean
local function _spawn_body(inputs, command_mode)
    local params = _common_body(inputs)
    -- We started the debuggee ourselves, so its paths are this machine's paths.
    params.localfs = true
    local shared = require("ezdap.shared")
    local program, args = shared.split_command(inputs.command)
    params[RDBG_KEY] = {
        program      = program,
        args         = args,
        cwd          = shared.normalize_path(inputs.cwd),
        env          = inputs.env,
        use_bundler  = inputs.use_bundler,
        rdbg_args    = inputs.rdbg_args,
        command_mode = command_mode,
    }
    return params
end

---@type table<string, ezdap.Mode>
local _modes = {
    -- One `command` input carries the whole command line; `build` splits it into
    -- the script rdbg loads and the arguments handed to it.
    script = {
        description = "debug a Ruby script",
        request = "attach",
        inputs = _inputs(_spawn_inputs, {
            command = { type = "string", completion = "command", required = true, description = "Ruby script to debug, plus its arguments" },
        }),
        build = function(inputs)
            local params = _spawn_body(inputs, false)
            return params
        end,
    },
    -- The same thing in rdbg's command mode, for the case the script form cannot
    -- express: a program on $PATH rather than a .rb file — `rspec spec/foo_spec.rb`,
    -- `rake test`, `ruby -Itest test/foo_test.rb`.
    command = {
        description = "debug a Ruby command — rspec, rake, ruby itself",
        request = "attach",
        inputs = _inputs(_spawn_inputs, {
            command = { type = "string", completion = "command", required = true, description = "command to debug, plus its arguments" },
        }),
        build = function(inputs)
            local params = _spawn_body(inputs, true)
            return params
        end,
    },
    -- Nothing is started here: the debuggee was opened elsewhere, with
    -- `rdbg --open --port ...` or `RUBY_DEBUG_OPEN=true`. Its paths are its own,
    -- so unless it shares this filesystem, `path_mappings` is what makes
    -- breakpoints land.
    remote = {
        description = "attach to an rdbg server already listening on host/port",
        request = "attach",
        inputs = _inputs {
            host          = { type = "string", description = "rdbg server host (default 127.0.0.1)" },
            port          = { type = "integer", required = true, description = "rdbg server port" },
            local_fs      = { type = "boolean", description = "the debuggee shares this filesystem (default true)" },
            path_mappings = { type = "map", completion = "dir", description = "source path mappings, remote=local" },
        },
        build = function(inputs)
            local shared = require("ezdap.shared")
            local port, err = shared.resolve_port(inputs.port)
            if err then return nil, err end
            local params = _common_body(inputs)
            local path_mappings = inputs.path_mappings and vim.tbl_map(shared.normalize_path, inputs.path_mappings)
            if path_mappings then
                -- The gem takes one string of "remote:local" pairs and matches by
                -- prefix, first hit winning, so the longest prefix goes first —
                -- otherwise a mapping for a parent directory shadows its children.
                local remotes = vim.tbl_keys(path_mappings)
                table.sort(remotes, function(a, b) return #a > #b end)
                local pairs_ = vim.tbl_map(function(remote)
                    return remote .. ":" .. path_mappings[remote]
                end, remotes)
                params.localfsMap = table.concat(pairs_, ",")
            else
                params.localfs = inputs.local_fs == nil and true or inputs.local_fs
            end
            params[RDBG_KEY] = { host = inputs.host, port = port }
            return params
        end,
    },
}

---@type ezdap.AdapterDef
return {
    -- The literal default, never run as a stdio adapter: a config with a port
    -- connects instead, and `setup` always sets one. It is here so `:checkhealth
    -- ezdap` has an executable to look for, and `setup` re-resolves it in case it
    -- is not on $PATH.
    command = rdbg_bin or rdbg_bins[1],
    -- The endpoint is not known until `setup` has either started a server or been
    -- told where an existing one is. Because this adapter has a `setup`, a task's
    -- own host/port are left to it rather than applied by the runner, so `remote`
    -- routes them through here too.
    setup = function(config, ctx, callback)
        local args = config.request_args
        if not args or not args[RDBG_KEY] then
            return callback(
                "rdbg: nothing to connect to — run one of its modes " ..
                "(script, command, remote), which say how to reach the debuggee")
        end
        local spec = args[RDBG_KEY]
        args[RDBG_KEY] = nil
        if spec.host or spec.port then
            config.host = spec.host or rdbg_host
            config.port = spec.port
            return callback()
        end
        _spawn_rdbg(spec, config, ctx, callback)
    end,
    teardown = function(_, ctx) if ctx and ctx.handle then ctx.handle.stop() end end,
    modes = _modes,
}
