-- https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings

-- Directories searched for a venv-style interpreter (bin/python, or
-- Scripts/python.exe on Windows), in order; the first one with debugpy
-- importable wins, so put your own interpreter's directory first to pin it.
-- "$VAR" and "~" expand anywhere in an entry, as they do in `vim.fs.normalize`;
-- an entry naming an unset or empty variable is skipped; a relative entry
-- resolves against the cwd. Mason is only
-- one of the entries, and the last of them: `pip install debugpy` into the
-- project's venv, or into the interpreter tried below, is enough on its own.
local debugpy_venv_dirs = {
    "$DEBUGPY_VENV",
    "$VIRTUAL_ENV",
    ".venv",
    "venv",
    "env",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "debugpy", "venv"),
}

-- Plain interpreters tried once no venv above pans out. A bare name (no
-- separator) is looked up on $PATH.
local debugpy_pythons = { "python3", "python" }

---The interpreter inside a venv-style directory, absolute or cwd-relative.
---@param dir string
---@return string
local function _venv_python(dir)
    return vim.fn.has("win32") == 1
        and vim.fs.joinpath(dir, "Scripts", "python.exe")
        or vim.fs.joinpath(dir, "bin", "python")
end

-- Those same directories as interpreters, so `resolve_path` is handed the file
-- it actually tests. `vim.fs.normalize` expands `$VAR` and `~` wherever they
-- appear, so appending `bin/python` to an entry needs no special arrangement.
local debugpy_venv_pythons = vim.tbl_map(_venv_python, debugpy_venv_dirs)

---Whether `python` runs and can import the adapter module.
---@param python string
---@return boolean
local function _has_debugpy(python)
    if python == "" or vim.fn.executable(python) == 0 then return false end
    vim.fn.system({ python, "-c", "import debugpy.adapter" })
    return vim.v.shell_error == 0
end

---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end

---Spawn the local debugpy adapter on a free port and point the connection at it.
---@param config   ndap.dap.Config
---@param ctx      ndap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _debugpy_setup(config, ctx, callback)
    local shared = require("ndap.shared")
    -- Venvs first, then bare interpreters: the first one debugpy actually imports
    -- under wins, so no venv is required.
    local cwd = config.cwd or vim.fn.getcwd()
    local python, venv_tried = shared.resolve_path(debugpy_venv_pythons, _has_debugpy,
        { cwd = cwd })
    if not python then
        local bare = vim.deepcopy(debugpy_pythons)
        local bare_tried
        python, bare_tried = shared.resolve_path(bare, _has_debugpy)
        if not python then
            local tried = vim.list_extend(venv_tried, bare_tried)
            return callback("no python with debugpy installed found (tried " ..
                table.concat(tried, ", ") .. ")")
        end
    end
    local port   = _free_port()
    local called = false
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    local handle = shared.spawn(
        { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
        {
            bufname = ctx.make_buf_name("server"),
            cwd     = config.cwd or vim.fn.getcwd(),
            on_exit = function() done("debugpy adapter exited unexpectedly") end,
        }
    )
    if not handle then return callback("failed to start debugpy adapter") end
    ctx.add_bufnr(handle.bufnr, { label = "debugpy", priority = -2 })
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

---Attributes debugpy accepts on both a launch and an attach. Declared once and
---merged into every mode, so a field is described in one place.
---@type table<string, ndap.Input>
local _common_inputs = {
    just_my_code      = { type = "boolean", description = "debug only user-written code (default false)" },
    show_return_value = { type = "boolean", description = "show function return values while stepping (default true)" },
    redirect_output   = { type = "boolean", description = "route the debuggee's output to the debug console" },
    sub_process       = { type = "boolean", description = "debug child processes too" },
    path_mappings     = { type = "map", description = "local=remote source path mappings" },
    django            = { type = "boolean", description = "enable Django template debugging" },
    jinja             = { type = "boolean", description = "enable Jinja2 template debugging" },
    pyramid           = { type = "boolean", description = "enable Pyramid application debugging" },
    gevent            = { type = "boolean", description = "support gevent monkey-patched code" },
    sudo              = { type = "boolean", description = "run the debuggee with elevated permissions" },
    log_to_file       = { type = "boolean", description = "log debugger events to a file" },
}

---A mode's own inputs on top of the common set.
---@param extra table<string, ndap.Input>
---@return table<string, ndap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `type` every debugpy body carries.
---`justMyCode`/`showReturnValue` keep ndap's defaults when left unset.
---@param parameters table<string, any>
---@return table params
local function _common_body(parameters)
    local params = {}
    params.type            = "python"
    params.justMyCode      = parameters.just_my_code == nil and false or parameters.just_my_code
    params.showReturnValue = parameters.show_return_value == nil and true or parameters.show_return_value
    params.redirectOutput  = parameters.redirect_output
    params.subProcess      = parameters.sub_process
    params.django          = parameters.django
    params.jinja           = parameters.jinja
    params.pyramid         = parameters.pyramid
    params.gevent          = parameters.gevent
    params.sudo            = parameters.sudo
    params.logToFile       = parameters.log_to_file
    if parameters.path_mappings then
        local mappings = {}
        for local_root, remote_root in pairs(parameters.path_mappings) do
            mappings[#mappings + 1] = { localRoot = local_root, remoteRoot = remote_root }
        end
        params.pathMappings = mappings
    end
    return params
end

---Launch-only attributes shared by the `script`, `module` and `code` modes.
---@type table<string, ndap.Input>
local _launch_inputs = {
    cwd           = { type = "string", completion = "dir", description = "working directory" },
    env           = { type = "map", description = "environment variables" },
    python        = { type = "list", description = "python executable and interpreter arguments" },
    console       = { type = "string", completion = { "internalConsole", "integratedTerminal", "externalTerminal" }, description = "where the debuggee's stdio goes" },
    stop_on_entry = { type = "boolean", description = "break at the first line of user code" },
}

---@param parameters table<string, any>
---@return table params
local function _launch_body(parameters)
    local params = _common_body(parameters)
    params.cwd         = require("ndap.shared").normalize_path(parameters.cwd)
    params.env         = parameters.env
    params.python      = parameters.python
    params.console     = parameters.console
    params.stopOnEntry = parameters.stop_on_entry
    return params
end

-- Attach to a remote Python process: the `connect`/`listen` groups target the
-- REMOTE process and go in the body, not the task-level connection (the local
-- adapter's port is chosen by `_debugpy_setup`, which also spawns it).
---@type ndap.AdapterDef
return {
    setup    = _debugpy_setup,
    teardown = function(_, ctx) if ctx then ctx.handle.stop() end end,
    modes = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        script = {
            description = "debug a Python file",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                command = { type = "string", completion = "command", required = true, description = "command line to debug" },
            })),
            build = function(parameters)
                local params = _launch_body(parameters)
                params.program, params.args = require("ndap.shared").split_command(parameters.command)
                return params
            end,
        },
        module = {
            description = "debug a module, as `python -m`",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                module = { type = "string", required = true, description = "module name to debug" },
                args   = { type = "list", description = "command line arguments passed to the module" },
            })),
            build = function(parameters)
                local params = _launch_body(parameters)
                params.module = parameters.module
                params.args   = parameters.args
                return params
            end,
        },
        code = {
            description = "debug a snippet of Python source, as `python -c`",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                code = { type = "string", required = true, description = "Python code to debug" },
                args = { type = "list", description = "command line arguments passed to the code" },
            })),
            build = function(parameters)
                local params = _launch_body(parameters)
                params.code = parameters.code
                params.args = parameters.args
                return params
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = _inputs {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(parameters)
                local pid, err = require("ndap.shared").resolve_pid(parameters.pid)
                if not pid then return nil, err end
                local params = _common_body(parameters)
                params.processId = pid
                return params
            end,
        },
        remote = {
            description = "attach to a remote debugpy process over host/port",
            request = "attach",
            inputs = _inputs {
                host = { type = "string", required = true, description = "remote debugpy host" },
                port = { type = "integer", required = true, description = "remote debugpy port" },
            },
            build = function(parameters)
                local port, err = require("ndap.shared").resolve_port(parameters.port)
                if err then return nil, err end
                local params = _common_body(parameters)
                params.connect = { host = parameters.host, port = port }
                return params
            end,
        },
        -- The inverse of `remote`: the adapter listens and the debuggee, started
        -- with `debugpy --connect`, dials in.
        listen = {
            description = "wait for a debugpy process to connect back on host/port",
            request = "attach",
            inputs = _inputs {
                host = { type = "string", description = "host to listen on" },
                port = { type = "integer", required = true, description = "port to listen on" },
            },
            build = function(parameters)
                local port, err = require("ndap.shared").resolve_port(parameters.port)
                if err then return nil, err end
                local params = _common_body(parameters)
                params.listen = { host = parameters.host or "127.0.0.1", port = port }
                return params
            end,
        },
    },
}
