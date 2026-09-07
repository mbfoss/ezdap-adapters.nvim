-- https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings

-- Set to an interpreter path to skip detection entirely; otherwise the first
-- candidate below that has debugpy importable wins.
local debugpy_python = nil ---@type string?

-- Directories searched for a venv-style interpreter (bin/python, or
-- Scripts/python.exe on Windows), in order. A leading "$" names an environment
-- variable, skipped when unset; "~" expands to the home directory; a relative
-- entry resolves against the cwd. Mason is only one of the entries, and the last
-- of them: `pip install debugpy` into the project's venv, or into the
-- interpreter tried below, is enough on its own.
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
---@param config   ezdap.dap.Config
---@param ctx      ezdap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _debugpy_setup(config, ctx, callback)
    local shared = require("ezdap.shared")
    local python = debugpy_python
    if python then
        if not _has_debugpy(python) then return callback("debugpy is not installed for " .. python) end
    else
        -- Venvs first, then bare interpreters, then whatever the config named: the
        -- first one debugpy actually imports under wins, so no venv is required.
        local cwd = config.cwd or vim.fn.getcwd()
        local venv_tried, bare_tried
        python, venv_tried = shared.resolve_path(debugpy_venv_dirs, _has_debugpy,
            { cwd = cwd, transform = _venv_python })
        if not python then
            local bare = vim.deepcopy(debugpy_pythons)
            local from_config = type(config.command) == "table" and config.command[1] or config.command
            if type(from_config) == "string" then table.insert(bare, from_config) end
            python, bare_tried = shared.resolve_path(bare, _has_debugpy)
            if not python then
                local tried = vim.list_extend(venv_tried, bare_tried)
                return callback("no python with debugpy installed found (tried " ..
                    table.concat(tried, ", ") .. ")")
            end
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
            bufname = shared.unique_buf_name("ezdap://" ..
            (config.name or config.adapter or "debug") .. "_debugpy-adapter"),
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
---@type table<string, ezdap.Input>
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
---@param extra table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `type` every debugpy body carries.
---`justMyCode`/`showReturnValue` keep ezdap's defaults when left unset.
---@param inputs table<string, any>
---@return table params
local function _common_body(inputs)
    local params = {}
    params.type            = "python"
    params.justMyCode      = inputs.just_my_code == nil and false or inputs.just_my_code
    params.showReturnValue = inputs.show_return_value == nil and true or inputs.show_return_value
    params.redirectOutput  = inputs.redirect_output
    params.subProcess      = inputs.sub_process
    params.django          = inputs.django
    params.jinja           = inputs.jinja
    params.pyramid         = inputs.pyramid
    params.gevent          = inputs.gevent
    params.sudo            = inputs.sudo
    params.logToFile       = inputs.log_to_file
    if inputs.path_mappings then
        local mappings = {}
        for local_root, remote_root in pairs(inputs.path_mappings) do
            mappings[#mappings + 1] = { localRoot = local_root, remoteRoot = remote_root }
        end
        params.pathMappings = mappings
    end
    return params
end

---Launch-only attributes shared by the `script`, `module` and `code` modes.
---@type table<string, ezdap.Input>
local _launch_inputs = {
    cwd           = { type = "string", completion = "dir", description = "working directory" },
    env           = { type = "map", description = "environment variables" },
    python        = { type = "list", description = "python executable and interpreter arguments" },
    console       = { type = "string", completion = { "internalConsole", "integratedTerminal", "externalTerminal" }, description = "where the debuggee's stdio goes" },
    stop_on_entry = { type = "boolean", description = "break at the first line of user code" },
}

---@param inputs table<string, any>
---@return table params
local function _launch_body(inputs)
    local params = _common_body(inputs)
    params.cwd         = require("ezdap.shared").normalize_path(inputs.cwd)
    params.env         = inputs.env
    params.python      = inputs.python
    params.console     = inputs.console
    params.stopOnEntry = inputs.stop_on_entry
    return params
end

-- Attach to a remote Python process: the `connect`/`listen` groups target the
-- REMOTE process and go in the body, not the task-level connection (the local
-- adapter's port is chosen by `_debugpy_setup`, which also spawns it).
---@type ezdap.AdapterDef
return {
    command  = "python3",
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
            build = function(inputs)
                local params = _launch_body(inputs)
                params.program, params.args = require("ezdap.shared").split_command(inputs.command)
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
            build = function(inputs)
                local params = _launch_body(inputs)
                params.module = inputs.module
                params.args   = inputs.args
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
            build = function(inputs)
                local params = _launch_body(inputs)
                params.code = inputs.code
                params.args = inputs.args
                return params
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = _inputs {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(inputs)
                local pid, err = require("ezdap.shared").resolve_pid(inputs.pid)
                if not pid then return nil, err end
                local params = _common_body(inputs)
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
            build = function(inputs)
                local port, err = require("ezdap.shared").resolve_port(inputs.port)
                if err then return nil, err end
                local params = _common_body(inputs)
                params.connect = { host = inputs.host, port = port }
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
            build = function(inputs)
                local port, err = require("ezdap.shared").resolve_port(inputs.port)
                if err then return nil, err end
                local params = _common_body(inputs)
                params.listen = { host = inputs.host or "127.0.0.1", port = port }
                return params
            end,
        },
    },
}
