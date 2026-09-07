-- codelldb — the CodeLLDB VS Code extension's adapter binary. Field set follows
-- vadimcn/codelldb's launch.json attributes
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). `type` is always
-- "lldb"; `name` is a display label.

-- Set to a codelldb path to skip detection entirely; otherwise the config's
-- codelldb is tried first, then the candidates below.
local codelldb_bin = nil ---@type string?

-- Where to look for the adapter binary, in order. A leading "$" names an
-- environment variable, skipped when unset; "~" expands to the home directory. A
-- bare name (no separator) is looked up on $PATH, which is where an unpacked
-- release or a distro package is picked up from — put its adapter directory on
-- $PATH, or set `codelldb_bin` to the binary. Mason ships a shim in its `bin`,
-- which is on $PATH only when mason.nvim was set up to put it there, so the
-- binary inside the package is listed too; mason itself is not required.
local codelldb_bins = {
    "codelldb",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", "codelldb"),
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "codelldb", "extension", "adapter", "codelldb"),
}

---Attributes codelldb accepts on both a launch and an attach. Declared once and
---merged into every mode, so a field is described in one place.
---@type table<string, ezdap.Input>
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
    return '"' .. require("ezdap.shared").normalize_path(path) .. '"'
end

---A mode's own inputs on top of the common set.
---@param extra table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `name`/`type` every codelldb body carries.
---@param inputs table<string, any>
---@return table params
local function _common_body(inputs)
    local shared = require("ezdap.shared")
    local params = {}
    params.name                 = "codelldb"
    params.type                 = "lldb"
    params.sourceMap            = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil
    params.relativePathBase     = shared.normalize_path(inputs.relative_path_base)
    params.sourceLanguages      = inputs.source_languages
    params.expressions          = inputs.expressions
    params.breakpointMode       = inputs.breakpoint_mode
    params.reverseDebugging     = inputs.reverse_debugging
    params.initCommands         = inputs.init_commands
    params.preRunCommands       = inputs.pre_run_commands
    params.postRunCommands      = inputs.post_run_commands
    params.preTerminateCommands = inputs.pre_terminate_commands
    params.exitCommands         = inputs.exit_commands
    return params
end

---@type ezdap.AdapterDef
return {
    command = codelldb_bin or codelldb_bins[1],
    -- Nothing to spawn — codelldb speaks DAP over stdio — but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at what it
    -- finds.
    setup = function(config, _, callback)
        local shared = require("ezdap.shared")
        local from_config = (type(config.command) == "table" and config.command or { config.command }) --[[@as string[] ]]
        local candidates = codelldb_bin and { codelldb_bin } or
            vim.list_extend({ from_config[1] }, codelldb_bins)
        local exe, tried = shared.resolve_path(candidates, shared.is_executable)
        if not exe then
            return callback("codelldb not found (unpack its .vsix or release, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        -- Keep any flags the config carries past the binary.
        config.command = #from_config > 1 and vim.list_extend({ exe }, vim.list_slice(from_config, 2)) or exe
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
            build = function(inputs)
                local shared = require("ezdap.shared")
                local params = _common_body(inputs)
                params.program, params.args = shared.split_command(inputs.command)
                params.cwd         = shared.normalize_path(inputs.cwd)
                params.env         = inputs.env
                params.envFile     = shared.normalize_path(inputs.env_file)
                params.stdio       = inputs.stdio
                params.terminal    = inputs.terminal
                params.stopOnEntry = inputs.stop_on_entry
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
            build = function(inputs)
                local shared = require("ezdap.shared")
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return nil, err end
                local params = _common_body(inputs)
                params.pid         = pid
                params.program     = shared.normalize_path(inputs.program)
                params.stopOnEntry = inputs.stop_on_entry
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
            build = function(inputs)
                local params = _common_body(inputs)
                params.program     = require("ezdap.shared").normalize_path(inputs.program)
                params.waitFor     = inputs.wait_for
                params.stopOnEntry = inputs.stop_on_entry
                return params
            end,
        },
        -- A custom launch drives LLDB by command rather than by `program`, so both
        -- inputs land inside a command string instead of a field of their own. One
        -- `target create` opens the core: it *is* the target, so there is no process
        -- to create afterwards — an empty `processCreateCommands` keeps codelldb from
        -- falling back to `process launch` and running the program for real.
        core = {
            description = "post-mortem debug from a core file (custom launch)",
            request = "launch",
            inputs = _inputs {
                program  = { type = "string", completion = "file", description = "executable that produced the core (read from the core when unset)" },
                corefile = { type = "string", completion = "file", required = true, description = "core file to load" },
            },
            build = function(inputs)
                local params = _common_body(inputs)
                local target = inputs.program and ("target create %s --core %s")
                    :format(_quoted(inputs.program), _quoted(inputs.corefile))
                    or ("target create --core %s"):format(_quoted(inputs.corefile))
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
            build = function(inputs)
                local port, err = require("ezdap.shared").resolve_port(inputs.port)
                if err then return nil, err end
                local params = _common_body(inputs)
                if inputs.program then
                    params.targetCreateCommands = { "target create " .. _quoted(inputs.program) }
                end
                params.processCreateCommands = { ("gdb-remote %s:%d"):format(inputs.host, port) }
                return params
            end,
        },
    },
}
