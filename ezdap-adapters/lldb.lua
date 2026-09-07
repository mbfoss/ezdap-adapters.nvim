-- lldb-dap — LLVM's native DAP adapter. The launch/attach parameters mirror the
-- LLDB docs (https://lldb.llvm.org/use/lldbdap.html).

-- Set to an lldb-dap path to skip detection entirely; otherwise the config's
-- lldb-dap is tried first, then the candidates below.
local lldb_dap_bin = nil ---@type string?

-- Where to look for lldb-dap, in order. A leading "$" names an environment
-- variable, skipped when unset; "~" expands to the home directory. A bare name
-- (no separator) is looked up on $PATH, which is where every install is picked up
-- from: a versioned LLVM ("lldb-dap-21", added here or set as `lldb_dap_bin`), a
-- package manager's prefix, or Xcode's toolchain, whose bin directory `xcode-select
-- -p` names and which `xcrun lldb-dap` runs without $PATH at all.
local lldb_dap_bins = { "lldb-dap" }

---@type ezdap.AdapterDef
return {
    command  = lldb_dap_bin or lldb_dap_bins[1],
    -- Nothing to spawn — lldb-dap speaks DAP over stdio — but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at what it
    -- finds.
    setup    = function(config, _, callback)
        local shared = require("ezdap.shared")
        local from_config = (type(config.command) == "table" and config.command or { config.command }) --[[@as string[] ]]
        local candidates = lldb_dap_bin and { lldb_dap_bin } or
            vim.list_extend({ from_config[1] }, lldb_dap_bins)
        local exe, tried = shared.resolve_path(candidates, shared.is_executable)
        if not exe then
            return callback("lldb-dap not found (install LLVM, or Xcode's command line tools); tried " ..
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
            inputs = {
                command         = { type = "string", completion = "command", required = true, description = "command line to debug" },
                cwd             = { type = "string", completion = "dir", description = "working directory" },
                env             = { type = "map", description = "environment variables" },
                stop_on_entry   = { type = "boolean", description = "break at program entry" },
                console         = { type = "string", completion = { "internalConsole", "integratedTerminal", "externalTerminal" }, description = "where to run" },
                run_in_terminal = { type = "boolean", description = "run the debuggee in a terminal (default true)" },
                source_path     = { type = "string", completion = "dir", description = "source root to remap ./ to" },
                source_map      = { type = "map", completion = "dir", description = "source path remappings, from=to" },
                init_commands   = { type = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                local program, args = shared.split_command(inputs.command)
                return {
                    name          = "lldb",
                    type          = "lldb-dap",
                    program       = program,
                    args          = args,
                    cwd           = shared.normalize_path(inputs.cwd),
                    env           = inputs.env,
                    stopOnEntry   = inputs.stop_on_entry,
                    console       = inputs.console,
                    -- Unset means the default, so only an explicit false turns it off.
                    runInTerminal = inputs.run_in_terminal ~= false,
                    sourcePath    = shared.normalize_path(inputs.source_path),
                    sourceMap     = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil,
                    initCommands  = inputs.init_commands,
                }
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid           = { type = "integer", description = "process id to attach to" },
                source_path   = { type = "string", completion = "dir", description = "source root to remap ./ to" },
                source_map    = { type = "map", completion = "dir", description = "source path remappings, from=to" },
                init_commands = { type = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return nil, err end
                return {
                    name         = "lldb",
                    type         = "lldb-dap",
                    pid          = pid,
                    sourcePath   = shared.normalize_path(inputs.source_path),
                    sourceMap    = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil,
                    initCommands = inputs.init_commands,
                }
            end,
        },
        process_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = {
                program       = { type = "string", completion = "file", required = true, description = "executable to attach to" },
                wait_for      = { type = "boolean", description = "wait for the process to launch" },
                source_path   = { type = "string", completion = "dir", description = "source root to remap ./ to" },
                source_map    = { type = "map", completion = "dir", description = "source path remappings, from=to" },
                init_commands = { type = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                return {
                    name         = "lldb",
                    type         = "lldb-dap",
                    program      = shared.normalize_path(inputs.program),
                    waitFor      = inputs.wait_for,
                    sourcePath   = shared.normalize_path(inputs.source_path),
                    sourceMap    = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil,
                    initCommands = inputs.init_commands,
                }
            end,
        },
        core = {
            description = "post-mortem debug from a core file",
            request = "attach",
            inputs = {
                corefile    = { type = "string", completion = "file", required = true, description = "core file to load" },
                program     = { type = "string", completion = "file", description = "executable that produced the core" },
                source_path = { type = "string", completion = "dir", description = "source root to remap ./ to" },
                source_map  = { type = "map", completion = "dir", description = "source path remappings, from=to" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                return {
                    name       = "lldb",
                    type       = "lldb-dap",
                    program    = shared.normalize_path(inputs.program),
                    coreFile   = shared.normalize_path(inputs.corefile),
                    sourcePath = shared.normalize_path(inputs.source_path),
                    sourceMap  = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil,
                }
            end,
        },
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection",
            request = "attach",
            inputs = {
                port        = { type = "integer", required = true, description = "gdbserver port" },
                host        = { type = "string", description = "gdbserver host" },
                source_path = { type = "string", completion = "dir", description = "source root to remap ./ to" },
                source_map  = { type = "map", completion = "dir", description = "source path remappings, from=to" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                local port, err = shared.resolve_port(inputs.port)
                if err then return nil, err end
                return {
                    name                = "lldb",
                    type                = "lldb-dap",
                    ["gdb-remote-host"] = inputs.host,
                    ["gdb-remote-port"] = port,
                    sourcePath          = shared.normalize_path(inputs.source_path),
                    sourceMap           = inputs.source_map and vim.tbl_map(shared.normalize_path, inputs.source_map) or nil,
                }
            end,
        },
    },
}
