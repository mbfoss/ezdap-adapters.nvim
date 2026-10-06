-- PHP / Xdebug - https://github.com/xdebug/vscode-php-debug
-- Fields follow the `php` configurationAttributes in that extension's
-- package.json. Upstream declares a `launch` request only, and no `attach`: the
-- adapter never dials the debuggee, it *listens* for Xdebug to connect back to
-- it, so the bodiless `listen` mode is a launch request too.

-- Where to look for the adapter's js entry point, in order; the first readable
-- one wins. Put your own file first to pin it. A leading "$" names an
-- environment variable, skipped when unset; "~" expands to the home directory.
-- Mason is only one of the entries and not required - unpack the .vsix anywhere
-- and point $PHP_DEBUG_HOME at it, either at the extension root or at the
-- directory above it. Entries are literal paths, so a VS Code install, which
-- carries a version suffix, needs that directory named here.
local php_debug_jss = {
    "$PHP_DEBUG_HOME/out/phpDebug.js",
    "$PHP_DEBUG_HOME/extension/out/phpDebug.js",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages",
        "php-debug-adapter", "extension", "out", "phpDebug.js"),
}

-- The Node.js that runs the adapter; put your own path first to pin it.
local node_bins = { "node" }

---Attributes both modes accept - everything that configures the DBGP side of
---the session, which is the same whether the debuggee was started here or
---connects on its own. Declared once and merged into every mode, so a field
---is described in one place.
---@type table<string, ndebug.Input>
local _common_inputs = {
    port               = { type = "integer", description = "port to listen for Xdebug on (default 9003)" },
    hostname           = { type = "string", description = "address to bind while listening (default :: - every interface)" },
    path_mappings      = { type = "map", completion = "dir", description = "source path mappings, server=local" },
    stop_on_entry      = { type = "boolean", description = "break at the first line" },
    ignore             = { type = "list", description = "globs whose errors are ignored (default **/vendor/**/*.php)" },
    ignore_exceptions  = { type = "list", description = "exception class names to ignore" },
    skip_files         = { type = "list", description = "globs to skip when stepping (default **/vendor/**)" },
    skip_entry_paths   = { type = "list", description = "globs that abandon the session when the entry file matches" },
    max_connections    = { type = "integer", description = "maximum parallel debug sessions (0 = unlimited)" },
    xdebug_settings    = { type = "map", description = "DBGP feature overrides, e.g. max_depth=3,max_children=100" },
    stream_stdout      = { type = "integer", description = "the debuggee's stdout: 0 off, 1 copy, 2 redirect" },
    proxy_host         = { type = "string", description = "DBGP proxy host (naming any proxy field enables the proxy)" },
    proxy_port         = { type = "integer", description = "DBGP proxy port (default 9001)" },
    proxy_key          = { type = "string", description = "IDE key the proxy matches requests to this editor by" },
    xdebug_cloud_token = { type = "string", description = "Xdebug Cloud token, used instead of a local port" },
    log                = { type = "boolean", description = "log the DAP/DBGP conversation to the debug console" },
}

---A mode's own inputs on top of the common set.
---@param extra table<string, ndebug.Input>
---@return table<string, ndebug.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Both ports are held to their range here, so every mode's `build` reports a bad
---one the same way - the `nil, err` pair an abort returns.
---@param parameters table<string, any>
---@return table? params, string? err
local function _common_body(parameters)
    local shared = require("ndebug.shared")
    local port, err = shared.resolve_port(parameters.port)
    if err then return nil, err end
    local proxy_port, proxy_err = shared.resolve_port(parameters.proxy_port)
    if proxy_err then return nil, proxy_err end
    local params = {}
    params.port             = port
    params.hostname         = parameters.hostname
    params.pathMappings     = parameters.path_mappings and vim.tbl_map(shared.normalize_path, parameters.path_mappings) or nil
    params.stopOnEntry      = parameters.stop_on_entry
    params.ignore           = parameters.ignore
    params.ignoreExceptions = parameters.ignore_exceptions
    params.skipFiles        = parameters.skip_files
    params.skipEntryPaths   = parameters.skip_entry_paths
    params.maxConnections   = parameters.max_connections
    params.xdebugSettings   = parameters.xdebug_settings
    params.xdebugCloudToken = parameters.xdebug_cloud_token
    params.log              = parameters.log
    -- `stream` and `proxy` are nested objects upstream; they are offered as flat
    -- parameters and assembled here. Naming any proxy field is what turns it on -
    -- there is no separate switch to forget.
    if parameters.stream_stdout then
        params.stream = { stdout = parameters.stream_stdout }
    end
    if parameters.proxy_host or parameters.proxy_port or parameters.proxy_key then
        params.proxy = {
            enable = true,
            host   = parameters.proxy_host,
            port   = proxy_port,
            key    = parameters.proxy_key,
        }
    end
    return params
end

---@type table<string, ndebug.Mode>
local _modes = {
    -- The usual PHP session: nothing is started here, the adapter just holds the
    -- port open and the next request Xdebug is enabled for connects back to it.
    -- Nothing beyond the common inputs applies, since there is no process to
    -- configure - `path_mappings` is what makes breakpoints land when the
    -- debuggee runs in a container or on another host.
    listen = {
        description = "wait for Xdebug to connect back on a port",
        request = "launch",
        inputs = _inputs {},
        build = function(parameters)
            local params, err = _common_body(parameters)
            if not params then return nil, err end
            return params
        end,
    },
    -- One `command` input carries the whole command line; `build` splits it into
    -- `program` (the first word) and `args` (the rest). The php binary is not part
    -- of it - `command` starts at the script, and `runtime_executable` names php.
    -- Xdebug still has to be told to start a session for this run, which is what
    -- `runtime_args` is for; without it the script runs to completion undebugged.
    script = {
        description = "run a PHP script under Xdebug",
        request = "launch",
        inputs = _inputs {
            command            = { type = "string", completion = "command", required = true, description = "script to debug, plus its arguments" },
            cwd                = { type = "string", completion = "dir", description = "working directory" },
            env                = { type = "map", description = "environment variables" },
            env_file           = { type = "string", completion = "file", description = "file of environment variable definitions" },
            runtime_executable = { type = "string", description = "php binary to run the script with (default php)" },
            runtime_args       = { type = "list", description = "arguments passed to php, e.g. -dxdebug.mode=debug,-dxdebug.start_with_request=yes" },
            console            = { type = "string", completion = { "internalConsole", "integratedTerminal", "externalTerminal" }, description = "where the debuggee's stdio goes" },
        },
        build = function(parameters)
            local shared = require("ndebug.shared")
            local params, err = _common_body(parameters)
            if not params then return nil, err end
            params.program, params.args = shared.split_command(parameters.command)
            params.cwd               = shared.normalize_path(parameters.cwd)
            params.env               = parameters.env
            params.envFile           = shared.normalize_path(parameters.env_file)
            params.runtimeExecutable = parameters.runtime_executable
            params.runtimeArgs       = parameters.runtime_args
            params.console           = parameters.console
            return params
        end,
    },
}

---@type ndebug.AdapterDef
return {
    -- Nothing to spawn - the adapter speaks DAP over stdio - but it is a js file
    -- rather than a binary on $PATH, so both halves are located here, where a
    -- plain error string reaches the user: the node that runs it, and the file
    -- itself.
    setup = function(config, _, callback)
        local shared = require("ndebug.shared")
        local js, tried = shared.resolve_path(
            php_debug_jss, function(cand) return vim.fn.filereadable(cand) == 1 end)
        if not js then
            return callback("php-debug-adapter not found (unpack its .vsix, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        local node, node_tried = shared.resolve_path(node_bins, shared.is_executable)
        if not node then
            return callback("node not found; tried " .. table.concat(node_tried, ", "))
        end
        config.command = { node, js }
        callback()
    end,
    modes = _modes,
}
