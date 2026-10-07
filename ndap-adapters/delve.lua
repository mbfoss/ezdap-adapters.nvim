-- https://github.com/go-delve/delve/blob/master/Documentation/api/dap/README.md

-- Go - `dlv dap` is a TCP DAP server, not a stdio adapter: it prints
-- "DAP server listening at: <host>:<port>" and expects a TCP connection, so
-- `_setup` spawns it, parses that line and points the connection there.

-- Where to look for dlv, in order; the first executable wins. Put your own path
-- first to pin it. A leading "$" names an environment variable, skipped when
-- unset; "~" expands to the home directory. A bare name (no separator) is
-- looked up on $PATH.
local delve_bins = {
    "dlv",
    "$GOBIN/dlv",
    "$GOPATH/bin/dlv",
}

-- Subcommand and flags dlv is started with, after the binary.
local delve_args = { "dap" }

---The first candidate that is executable.
---@return string? dlv, string[] tried
local function _resolve_dlv()
    local shared = require("ndap.shared")
    return shared.resolve_path(delve_bins, shared.is_executable)
end

---Start `dlv dap`, wait for its "DAP server listening at: host:port" line, and
---point the connection at that endpoint (delve speaks DAP over TCP, not stdio).
---@param config   ndap.dap.Config
---@param ctx      ndap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _setup(config, ctx, callback)
    local shared = require("ndap.shared")
    local dlv, tried = _resolve_dlv()
    if not dlv then
        return callback("dlv not found (install delve, e.g. via mason); tried " .. table.concat(tried, ", "))
    end
    local cmd = { dlv }
    vim.list_extend(cmd, delve_args)
    local resolved = false
    local called   = false
    local handle
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    handle = shared.spawn(cmd, {
        bufname   = ctx.make_buf_name("server"),
        cwd       = config.cwd or vim.fn.getcwd(),
        env       = config.env,
        on_stdout = function(_, data)
            if resolved then return end
            for _, line in ipairs(data) do
                -- "DAP server listening at: 127.0.0.1:53742"
                -- (.+) is greedy so it captures up to the last colon (IPv6-safe).
                local h, p = line:match("DAP server listening at:%s*(.+):(%d+)")
                if h and p then
                    resolved    = true
                    config.host = h
                    config.port = tonumber(p)
                    done(nil, { handle = handle })
                    return
                end
            end
        end,
        on_exit   = function()
            if not resolved then done("dlv dap exited before reporting a listening port") end
        end,
    })
    if not handle then return callback("failed to start dlv dap") end
    ctx.add_bufnr(handle.bufnr, { label = "dlv dap", priority = -2 })
    ctx.report("delve: waiting for DAP server port")
    vim.defer_fn(function()
        if not resolved then done("dlv dap did not report a listening port within 5 s") end
    end, 5000)
end

-- Launch modes and their fields follow delve's DAP documentation. Every launch
-- mode accepts `dlvCwd`/`env`; `exec` adds the process fields, and `debug`/`test`
-- add the build and display fields on top of those.

---@type table<string, ndap.Input>
local _any_mode_inputs = {
    dlv_cwd         = { type = "string", completion = "dir", description = "working directory for the delve server itself" },
    env             = { type = "map", description = "environment variables for the debuggee" },
    substitute_path = { type = "map", description = "source path remappings, from=to" },
}

---Fields every mode that runs a process accepts (`exec`, and so `debug`/`test`).
---@type table<string, ndap.Input>
local _process_inputs = {
    command  = { type = "string", completion = "command", required = true, description = "command line to debug (package or binary, plus args)" },
    cwd      = { type = "string", completion = "dir", description = "working directory for the debuggee" },
    backend  = { type = "string", completion = { "default", "native", "lldb", "rr" }, description = "debugger backend" },
    no_debug = { type = "boolean", description = "run the program without debugging it" },
}

---Build and display fields only the compiling modes (`debug`, `test`) accept.
---@type table<string, ndap.Input>
local _build_inputs = {
    build_flags            = { type = "string", description = "flags passed to the Go compiler" },
    output                 = { type = "string", completion = "file", description = "path for the compiled binary" },
    stop_on_entry          = { type = "boolean", description = "break at program entry" },
    stack_trace_depth      = { type = "integer", description = "maximum stack trace depth" },
    show_global_variables  = { type = "boolean", description = "show package-level variables among the scopes" },
    show_registers         = { type = "boolean", description = "show CPU registers among the scopes" },
    show_pprof_labels      = { type = "list", description = "pprof labels to show in goroutine names" },
    show_raw_strings       = { type = "boolean", description = "show strings without quoting or escaping" },
    hide_system_goroutines = { type = "boolean", description = "hide runtime goroutines from the thread list" },
    goroutine_filters      = { type = "string", description = "filter expression limiting the goroutines listed" },
}

---A mode's inputs: the always-accepted set plus whichever groups apply.
---@param ... table<string, ndap.Input>
---@return table<string, ndap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_any_mode_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---@param parameters table<string, any>
---@return table params
local function _any_mode_body(parameters)
    local params = {}
    params.dlvCwd = require("ndap.shared").normalize_path(parameters.dlv_cwd)
    params.env    = parameters.env
    -- delve wants a list of {from, to} pairs, not a flat mapping.
    if parameters.substitute_path then
        local rules = {}
        for from, to in pairs(parameters.substitute_path) do
            rules[#rules + 1] = { from = from, to = to }
        end
        params.substitutePath = rules
    end
    return params
end

---@param parameters table<string, any>
---@return table params
local function _process_body(parameters)
    local shared = require("ndap.shared")
    local params = _any_mode_body(parameters)
    params.program, params.args = shared.split_command(parameters.command)
    params.cwd                  = shared.normalize_path(parameters.cwd)
    params.backend              = parameters.backend
    params.noDebug              = parameters.no_debug
    return params
end

---@param parameters table<string, any>
---@return table params
local function _build_body(parameters)
    local params = _process_body(parameters)
    params.buildFlags           = parameters.build_flags
    params.output               = require("ndap.shared").normalize_path(parameters.output)
    params.stopOnEntry          = parameters.stop_on_entry
    params.stackTraceDepth      = parameters.stack_trace_depth
    params.showGlobalVariables  = parameters.show_global_variables
    params.showRegisters        = parameters.show_registers
    params.showPprofLabels      = parameters.show_pprof_labels
    params.showRawStrings       = parameters.show_raw_strings
    params.hideSystemGoroutines = parameters.hide_system_goroutines
    params.goroutineFilters     = parameters.goroutine_filters
    return params
end

---@type ndap.AdapterDef
return {
    setup    = _setup,
    teardown = function(_, ctx) if ctx and ctx.handle then ctx.handle.stop() end end,
    modes = {
        -- `build` splits the one `command` input into `program` and `args`.
        package = {
            description = "build and debug a Go package/binary",
            request = "launch",
            inputs = _inputs(_process_inputs, _build_inputs),
            build = function(parameters)
                local params = _build_body(parameters)
                params.mode = "debug"
                return params
            end,
        },
        test = {
            description = "build and debug a Go test package",
            request = "launch",
            inputs = _inputs(_process_inputs, _build_inputs),
            build = function(parameters)
                local params = _build_body(parameters)
                params.mode = "test"
                return params
            end,
        },
        binary = {
            description = "debug a pre-built Go binary",
            request = "launch",
            inputs = _inputs(_process_inputs),
            build = function(parameters)
                local params = _process_body(parameters)
                params.mode = "exec"
                return params
            end,
        },
        -- Replay and core are post-mortem: they read a recording rather than run a
        -- process, so they take neither args nor the process fields.
        replay = {
            description = "replay an rr trace recording",
            request = "launch",
            inputs = _inputs {
                program        = { type = "string", completion = "file", required = true, description = "binary the trace was recorded from" },
                trace_dir_path = { type = "string", completion = "dir", required = true, description = "rr trace directory to replay" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local params = _any_mode_body(parameters)
                params.mode = "replay"
                params.program      = shared.normalize_path(parameters.program)
                params.traceDirPath = shared.normalize_path(parameters.trace_dir_path)
                return params
            end,
        },
        core = {
            description = "post-mortem debug from a core dump",
            request = "launch",
            inputs = _inputs {
                program       = { type = "string", completion = "file", required = true, description = "binary that produced the core" },
                corefile_path = { type = "string", completion = "file", required = true, description = "core dump to load" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local params = _any_mode_body(parameters)
                params.mode = "core"
                params.program      = shared.normalize_path(parameters.program)
                params.corefilePath = shared.normalize_path(parameters.corefile_path)
                return params
            end,
        },
        -- Only `dlv dap`-served attach mode is "local" (attach to a process the
        -- server can see); "remote" attach is served by `dlv --headless` and
        -- configured at the connection level, not through this launched-server body.
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid     = { type = "integer", description = "process id to attach to" },
                backend = { type = "string", completion = { "default", "native", "lldb", "rr" }, description = "debugger backend" },
            },
            build = function(parameters)
                local pid, err = require("ndap.shared").resolve_pid(parameters.pid)
                if not pid then return nil, err end
                return {
                    mode      = "local",
                    processId = pid,
                    backend   = parameters.backend,
                }
            end,
        },
    },
}
