-- lldb-dap - LLVM's native DAP adapter. The launch/attach parameters mirror the
-- LLDB docs (https://lldb.llvm.org/use/lldbdap.html).

-- Where to look for lldb-dap, in order; the first executable wins. Put your own
-- path first to pin it. "$VAR" and "~" expand anywhere in an entry, as they do in
-- `vim.fs.normalize`; an entry naming an unset or empty variable is skipped. A
-- bare name (no separator) is looked up on $PATH, which is where a package
-- manager's install or Xcode's toolchain is picked up from - Xcode's bin
-- directory, the one `xcode-select -p` names, is on $PATH only in a developer
-- shell, so `xcrun lldb-dap` may be the only way to reach it. An LLVM that
-- suffixes the binary ("lldb-dap-21") is not named that on $PATH: name it here.
local lldb_dap_bins = { "lldb-dap" }

---@type ndap.AdapterDef
return {
    -- Nothing to spawn - lldb-dap speaks DAP over stdio - but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at what it
    -- finds.
    setup    = function(config, _, callback)
        local shared = require("ndap.shared")
        local exe, tried = shared.resolve_path(lldb_dap_bins, shared.is_executable)
        if not exe then
            return callback("lldb-dap not found (install LLVM, or Xcode's command line tools); tried " ..
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
            build = function(parameters)
                local shared = require("ndap.shared")
                local program, args = shared.split_command(parameters.command)
                return {
                    name          = "lldb",
                    type          = "lldb-dap",
                    program       = program,
                    args          = args,
                    cwd           = shared.normalize_path(parameters.cwd),
                    env           = parameters.env,
                    stopOnEntry   = parameters.stop_on_entry,
                    console       = parameters.console,
                    -- Unset means the default, so only an explicit false turns it off.
                    runInTerminal = parameters.run_in_terminal ~= false,
                    sourcePath    = shared.normalize_path(parameters.source_path),
                    sourceMap     = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil,
                    initCommands  = parameters.init_commands,
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
            build = function(parameters)
                local shared = require("ndap.shared")
                local pid, err = shared.resolve_pid(parameters.pid)
                if not pid then return nil, err end
                return {
                    name         = "lldb",
                    type         = "lldb-dap",
                    pid          = pid,
                    sourcePath   = shared.normalize_path(parameters.source_path),
                    sourceMap    = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil,
                    initCommands = parameters.init_commands,
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
            build = function(parameters)
                local shared = require("ndap.shared")
                return {
                    name         = "lldb",
                    type         = "lldb-dap",
                    program      = shared.normalize_path(parameters.program),
                    waitFor      = parameters.wait_for,
                    sourcePath   = shared.normalize_path(parameters.source_path),
                    sourceMap    = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil,
                    initCommands = parameters.init_commands,
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
            build = function(parameters)
                local shared = require("ndap.shared")
                return {
                    name       = "lldb",
                    type       = "lldb-dap",
                    program    = shared.normalize_path(parameters.program),
                    coreFile   = shared.normalize_path(parameters.corefile),
                    sourcePath = shared.normalize_path(parameters.source_path),
                    sourceMap  = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil,
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
            build = function(parameters)
                local shared = require("ndap.shared")
                local port, err = shared.resolve_port(parameters.port)
                if err then return nil, err end
                return {
                    name                = "lldb",
                    type                = "lldb-dap",
                    ["gdb-remote-host"] = parameters.host,
                    ["gdb-remote-port"] = port,
                    sourcePath          = shared.normalize_path(parameters.source_path),
                    sourceMap           = parameters.source_map and vim.tbl_map(shared.normalize_path, parameters.source_map) or nil,
                }
            end,
        },
    },
}
