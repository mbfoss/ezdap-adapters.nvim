-- codelldb - the CodeLLDB VS Code extension's adapter binary. Field set follows
-- vadimcn/codelldb's launch.json attributes
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). `type` is always
-- "lldb"; `name` is a display label.

-- Where to look for the adapter binary, in order; the config's codelldb is tried
-- first, then these, and the first executable wins. Put your own path first to
-- pin it. A leading "$" names an environment variable, skipped when unset; "~"
-- expands to the home directory. A bare name (no separator) is looked up on
-- $PATH, which is where an unpacked release or a distro package is picked up
-- from: put its adapter directory on $PATH, or list the binary here first. Mason
-- ships a shim in its `bin`,
-- which is on $PATH only when mason.nvim was set up to put it there, so the
-- binary inside the package is listed too; mason itself is not required.
local codelldb_bins = {
    "codelldb",
}

---Attributes codelldb accepts on both a launch and an attach. Declared once and
---merged into every mode, so a field is described in one place.
---@type table<string, ndap.Input>
local _common_inputs = {
    source_map             = { type = "map", completion = "dir", description = "source path remappings, from=to" },
    relative_path_base     = { type = "string", completion = "dir", description = "base directory for relative source paths" },
    source_languages       = { type = "list", description = "source languages in the program, for language-specific features" },
    expressions            = { type = "string", completion = { "simple", "python", "native" }, description = "default expression evaluator" },
    breakpoint_mode        = { type = "string", completion = { "path", "file" }, description = "how source breakpoints resolve" },
    reverse_debugging      = { type = "boolean", description = "enable reverse debugging" },
    init_commands          = { type = "list", description = "LLDB commands run at debugger startup, before the target exists" },
    pre_run_commands       = { type = "list", description = "LLDB commands run just before launching/attaching" },
    post_run_commands      = { type = "list", description = "LLDB commands run just after launching/attaching" },
    pre_terminate_commands = { type = "list", description = "LLDB commands run just before the debuggee is terminated" },
    exit_commands          = { type = "list", description = "LLDB commands run at the end of the session" },
}

---A path as an LLDB command argument: `~`/`$VAR` expanded, then quoted so a path
---with spaces survives LLDB's own word splitting.
---@param path string
---@return string
local function _quoted(path)
    return '"' .. require("ndap.shared").normalize_path(path) .. '"'
end

---A mode's own inputs on top of the common set.
---@param extra table<string, ndap.Input>
---@return table<string, ndap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `name`/`type` every codelldb body carries.
---@param parameters table<string, any>
---@return table params
local function _common_body(parameters)
    local shared = require("ndap.shared")
    local params = {}
    params.name                 = "codelldb"
    params.type                 = "lldb"
    params.sourceMap            = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil
    params.relativePathBase     = shared.normalize_path(parameters.relative_path_base)
    params.sourceLanguages      = parameters.source_languages
    params.expressions          = parameters.expressions
    params.breakpointMode       = parameters.breakpoint_mode
    params.reverseDebugging     = parameters.reverse_debugging
    params.initCommands         = parameters.init_commands
    params.preRunCommands       = parameters.pre_run_commands
    params.postRunCommands      = parameters.post_run_commands
    params.preTerminateCommands = parameters.pre_terminate_commands
    params.exitCommands         = parameters.exit_commands
    return params
end

---@type ndap.AdapterDef
return {
    setup = function(config, _, callback)
        local shared = require("ndap.shared")
        local exe, tried = shared.resolve_path(codelldb_bins, shared.is_executable)
        if not exe then
            return callback("codelldb not found (unpack its .vsix or release, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        config.command = exe
        callback()
    end,
    modes = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        binary = {
            description = "debug an executable",
            request = "launch",
            inputs = _inputs {
                command       = { type = "string", completion = "command", required = true, description = "command line to debug" },
                cwd           = { type = "string", completion = "dir", description = "working directory" },
                env           = { type = "map", description = "environment variables, added to the inherited ones" },
                env_file      = { type = "string", completion = "file", description = "file of additional environment variables" },
                stdio         = { type = "list", description = "redirections for stdin, stdout, stderr, in that order" },
                terminal      = { type = "string", completion = { "console", "integrated", "external" }, description = "where the debuggee's stdio goes" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local params = _common_body(parameters)
                params.program, params.args = shared.split_command(parameters.command)
                params.cwd         = shared.normalize_path(parameters.cwd)
                params.env         = parameters.env
                params.envFile     = shared.normalize_path(parameters.env_file)
                params.stdio       = parameters.stdio
                params.terminal    = parameters.terminal
                params.stopOnEntry = parameters.stop_on_entry
                return params
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = _inputs {
                pid           = { type = "integer", description = "process id to attach to" },
                program       = { type = "string", completion = "file", description = "executable to read symbols from" },
                stop_on_entry = { type = "boolean", description = "break immediately after attaching" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local pid, err = shared.resolve_pid(parameters.pid)
                if not pid then return nil, err end
                local params = _common_body(parameters)
                params.pid         = pid
                params.program     = shared.normalize_path(parameters.program)
                params.stopOnEntry = parameters.stop_on_entry
                return params
            end,
        },
        process_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = _inputs {
                program       = { type = "string", completion = "file", required = true, description = "executable to attach to" },
                wait_for      = { type = "boolean", description = "wait for the process to launch" },
                stop_on_entry = { type = "boolean", description = "break immediately after attaching" },
            },
            build = function(parameters)
                local params = _common_body(parameters)
                params.program     = require("ndap.shared").normalize_path(parameters.program)
                params.waitFor     = parameters.wait_for
                params.stopOnEntry = parameters.stop_on_entry
                return params
            end,
        },
        -- A custom launch drives LLDB by command rather than by `program`, so both
        -- parameters land inside a command string instead of a field of their own. One
        -- `target create` opens the core: it *is* the target, so there is no process
        -- to create afterwards - an empty `processCreateCommands` keeps codelldb from
        -- falling back to `process launch` and running the program for real.
        core = {
            description = "post-mortem debug from a core file (custom launch)",
            request = "launch",
            inputs = _inputs {
                program  = { type = "string", completion = "file", description = "executable that produced the core (read from the core when unset)" },
                corefile = { type = "string", completion = "file", required = true, description = "core file to load" },
            },
            build = function(parameters)
                local params = _common_body(parameters)
                local target = parameters.program and ("target create %s --core %s")
                    :format(_quoted(parameters.program), _quoted(parameters.corefile))
                    or ("target create --core %s"):format(_quoted(parameters.corefile))
                params.targetCreateCommands  = { target }
                params.processCreateCommands = {}
                return params
            end,
        },
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection (custom launch)",
            request = "launch",
            inputs = _inputs {
                program = { type = "string", completion = "file", description = "executable for symbols" },
                host    = { type = "string", required = true, description = "gdbserver host" },
                port    = { type = "integer", required = true, description = "gdbserver port" },
            },
            -- `host`/`port` are required for the same reason `core` always writes a
            -- `processCreateCommands`: without one codelldb runs `process launch` and
            -- debugs the program locally instead of the remote.
            build = function(parameters)
                local port, err = require("ndap.shared").resolve_port(parameters.port)
                if err then return nil, err end
                local params = _common_body(parameters)
                if parameters.program then
                    params.targetCreateCommands = { "target create " .. _quoted(parameters.program) }
                end
                params.processCreateCommands = { ("gdb-remote %s:%d"):format(parameters.host, port) }
                return params
            end,
        },
    },
}
