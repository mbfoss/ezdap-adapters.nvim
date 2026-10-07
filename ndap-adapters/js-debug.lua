-- JavaScript / TypeScript - starts js-debug's TCP server, then connects to it.
-- Fields follow vscode-js-debug's options documentation
-- (https://github.com/microsoft/vscode-js-debug/blob/main/OPTIONS.md). js-debug
-- picks the debuggee's console via `console`, not runInTerminal.

-- Where to look for the server's js entry point, in order; the first readable
-- one wins. Put your own file first to pin it. "$VAR" and "~" expand anywhere in
-- an entry, as they do in `vim.fs.normalize`; an entry naming an unset or empty
-- variable is skipped.
-- Mason is only one of the entries, and not required: the same `js-debug` tree
-- comes out of the upstream release tarball or an npm install, and
-- $JS_DEBUG_HOME points at wherever you unpacked it. Entries are literal paths,
-- so an install in a version-suffixed directory needs that version named here.
local js_debug_server_jss = {
    "$JS_DEBUG_HOME/src/dapDebugServer.js",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages",
        "js-debug-adapter", "js-debug", "src", "dapDebugServer.js"),
}

-- The Node.js that runs the server, in order; put your own path first to pin it.
local node_bins = { "node" }

---Source-resolution fields every mode accepts, node and browser alike.
---@type table<string, ndap.Input>
local _source_inputs = {
    source_maps                  = { type = "boolean", description = "use source maps when they exist" },
    source_map_path_overrides    = { type = "map", description = "rewrite sourcemap file locations, from=to" },
    resolve_source_map_locations = { type = "list", description = "globs where sourcemaps may be resolved" },
    out_files                    = { type = "list", description = "globs matching generated JavaScript" },
    skip_files                   = { type = "list", description = "globs to skip when stepping" },
    smart_step                   = { type = "boolean", description = "step over generated code with no original source" },
}

---Fields both Node modes accept on top of the source ones.
---@type table<string, ndap.Input>
local _node_inputs = {
    cwd                         = { type = "string", completion = "dir", description = "working directory" },
    env                         = { type = "map", description = "environment variables" },
    env_file                    = { type = "string", completion = "file", description = "file of environment variable definitions" },
    restart                     = { type = "boolean", description = "try to reconnect when the connection is lost" },
    auto_attach_child_processes = { type = "boolean", description = "attach to child processes automatically" },
}

---@param parameters table<string, any>
---@return table params
local function _source_body(parameters)
    local params = {}
    params.sourceMaps                = parameters.source_maps
    params.sourceMapPathOverrides    = parameters.source_map_path_overrides
    params.resolveSourceMapLocations = parameters.resolve_source_map_locations
    params.outFiles                  = parameters.out_files
    params.skipFiles                 = parameters.skip_files
    params.smartStep                 = parameters.smart_step
    return params
end

---@param parameters table<string, any>
---@return table params
local function _node_body(parameters)
    local shared = require("ndap.shared")
    local params = _source_body(parameters)
    params.type                     = "pwa-node"
    params.cwd                      = shared.normalize_path(parameters.cwd)
    params.env                      = parameters.env
    params.envFile                  = shared.normalize_path(parameters.env_file)
    params.restart                  = parameters.restart
    params.autoAttachChildProcesses = parameters.auto_attach_child_processes
    return params
end

---@type table<string, ndap.Mode>
local _modes = {
    -- One `command` input carries the whole command line; `build` splits it into
    -- `program` (the first word) and `args` (the rest). The runtime is not part of
    -- it - `command` starts at the script, and `runtime_executable` names the runtime.
    script = {
        description = "debug a Node.js/JS/TS file",
        request = "launch",
        inputs = vim.tbl_extend("error", _source_inputs, _node_inputs, {
            command            = { type = "string", completion = "command", required = true, description = "script to debug, plus its arguments" },
            runtime_executable = { type = "string", description = "runtime to run the script with (default node)" },
            runtime_args       = { type = "list", description = "arguments passed to the runtime, before the program" },
            stop_on_entry      = { type = "boolean", description = "break at program entry" },
            console            = { type = "string", completion = { "internalConsole", "integratedTerminal", "externalTerminal" }, description = "where to run the debuggee" },
        }),
        build = function(parameters)
            local shared = require("ndap.shared")
            local params = _node_body(parameters)
            params.program, params.args = shared.split_command(parameters.command)
            params.runtimeExecutable = parameters.runtime_executable
            params.runtimeArgs       = parameters.runtime_args
            params.stopOnEntry       = parameters.stop_on_entry
            params.console           = parameters.console
            return params
        end,
    },
    -- Both attach modes are the same DAP request; they differ only in whether
    -- the debuggee is named by pid or by address/port.
    attach = {
        description = "attach to a running process by pid",
        request = "attach",
        inputs = vim.tbl_extend("error", _source_inputs, _node_inputs, {
            pid                      = { type = "integer", description = "process id to attach to" },
            attach_existing_children = { type = "boolean", description = "also attach to already-spawned child processes" },
            continue_on_attach       = { type = "boolean", description = "resume a program waiting on --inspect-brk" },
        }),
        build = function(parameters)
            local shared = require("ndap.shared")
            local pid, err = shared.resolve_pid(parameters.pid)
            if not pid then return nil, err end
            local params = _node_body(parameters)
            params.processId              = pid
            params.attachExistingChildren = parameters.attach_existing_children
            params.continueOnAttach       = parameters.continue_on_attach
            return params
        end,
    },
    -- `local_root`/`remote_root` map the remote machine's paths onto this one.
    remote = {
        description = "attach to a remote Node.js process over host/port",
        request = "attach",
        inputs = vim.tbl_extend("error", _source_inputs, _node_inputs, {
            host                     = { type = "string", description = "remote Node.js host" },
            port                     = { type = "integer", description = "remote Node.js debug port (default 9229)" },
            local_root               = { type = "string", completion = "dir", description = "local directory containing the program" },
            remote_root              = { type = "string", description = "remote directory containing the program" },
            attach_existing_children = { type = "boolean", description = "also attach to already-spawned child processes" },
            continue_on_attach       = { type = "boolean", description = "resume a program waiting on --inspect-brk" },
        }),
        build = function(parameters)
            local shared = require("ndap.shared")
            local port, err = shared.resolve_port(parameters.port)
            if err then return nil, err end
            local params = _node_body(parameters)
            params.address                = parameters.host
            params.port                   = port
            params.localRoot              = shared.normalize_path(parameters.local_root)
            params.remoteRoot             = parameters.remote_root
            params.attachExistingChildren = parameters.attach_existing_children
            params.continueOnAttach       = parameters.continue_on_attach
            return params
        end,
    },
    -- The browser target: js-debug serves pwa-chrome from the same server, and
    -- resolves sources through `web_root`/`path_mapping` rather than a cwd.
    browser = {
        description = "launch a Chromium browser and debug a page",
        request = "launch",
        inputs = vim.tbl_extend("error", _source_inputs, {
            url                = { type = "string", required = true, description = "url to open and attach to" },
            web_root           = { type = "string", completion = "dir", description = "absolute path to the webserver root" },
            path_mapping       = { type = "map", completion = "dir", description = "url-to-local-folder mappings, from=to" },
            user_data_dir      = { type = "string", completion = "dir", description = "browser user-data directory (default: a throwaway one)" },
            runtime_executable = { type = "string", description = "'stable', 'canary', or a path to the browser executable" },
            runtime_args       = { type = "list", description = "arguments passed to the browser" },
        }),
        build = function(parameters)
            local shared = require("ndap.shared")
            local params = _source_body(parameters)
            params.type              = "pwa-chrome"
            params.url               = parameters.url
            params.webRoot           = shared.normalize_path(parameters.web_root)
            params.pathMapping       = parameters.path_mapping and vim.tbl_map(shared.normalize_path, parameters.path_mapping) or nil
            params.userDataDir       = shared.normalize_path(parameters.user_data_dir)
            params.runtimeExecutable = parameters.runtime_executable
            params.runtimeArgs       = parameters.runtime_args
            return params
        end,
    },
}

---@type ndap.AdapterDef
return {
    setup = function(config, ctx, callback)
        local shared = require("ndap.shared")
        local server_js, tried = shared.resolve_path(
            js_debug_server_jss, function(cand) return vim.fn.filereadable(cand) == 1 end)
        if not server_js then
            return callback("js-debug-adapter not found (install js-debug from its release, npm, or mason); tried " ..
                table.concat(tried, ", "))
        end
        local node, node_tried = shared.resolve_path(node_bins, shared.is_executable)
        if not node then
            return callback("node not found (needed to run js-debug); tried " .. table.concat(node_tried, ", "))
        end
        local resolved_host = nil
        local resolved_port = nil
        local called        = false
        local function done(err, state)
            if called then return end
            called = true
            callback(err, state)
        end
        local handle
        handle = shared.spawn({ node, server_js }, {
            bufname = ctx.make_buf_name("server"),
            on_stdout = function(_, data)
                if resolved_port then return end
                for _, line in ipairs(data) do
                    -- format: "Debug server listening at <host>:<port>"
                    -- (.+) is greedy so it captures up to the last colon,
                    -- correctly handling IPv6 addresses like ::1
                    local h, p = line:match("Debug server listening at (.+):(%d+)")
                    if h and p then
                        resolved_host = h
                        resolved_port = tonumber(p)
                        config.host   = resolved_host
                        config.port   = resolved_port
                        done(nil, { handle = handle })
                        return
                    end
                end
            end,
            on_exit = function()
                if not resolved_port then
                    done("js-debug server exited before reporting a port")
                end
            end,
        })
        if not handle then return callback("failed to start js-debug server") end
        ctx.add_bufnr(handle.bufnr, { label = "js-debug server", priority = -2 })
        ctx.report("js-debug: waiting for server port")
        vim.defer_fn(function()
            if not resolved_port then
                -- Handed back with the error so `teardown` stops it.
                done("js-debug server did not start within 5 s", { handle = handle })
            end
        end, 5000)
    end,

    teardown = function(_, state) if state and state.handle then state.handle.stop() end end,

    modes = _modes,
}
