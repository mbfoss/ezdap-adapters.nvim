-- netcoredbg has no options document; the authoritative field set is the keys its
-- VS Code protocol handler reads, in Samsung/netcoredbg's
-- src/protocols/vscodeprotocol.cpp ("launch" and "attach" handlers). That set is
-- small and complete as written below - launch takes seven keys, attach only
-- `processId`. netcoredbg spells entry-stop `stopAtEntry`, not the standard
-- `stopOnEntry`, and has no runInTerminal/console argument.

-- Where to look for netcoredbg, in order; the config's netcoredbg is tried
-- first, then these, and the first executable wins. Put your own path first to
-- pin it. A leading "$" names an environment variable, skipped when unset; "~"
-- expands to the home directory. A bare name (no separator) is looked up on
-- $PATH, which is where an unpacked release is picked up from: put its directory
-- on $PATH, or list the binary here first. Mason ships a shim in its `bin`, which
-- is on $PATH only when mason.nvim was set up to put it there, so the binary
-- inside the package is listed too; mason itself is not required.
local netcoredbg_bins = {
    "netcoredbg",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", "netcoredbg"),
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "netcoredbg", "libexec", "netcoredbg", "netcoredbg"),
}

-- Flags netcoredbg is started with, after the binary. `--interpreter=vscode` is
-- what makes it speak DAP at all.
local netcoredbg_args = { "--interpreter=vscode" }

---@type ezdap.AdapterDef
return {
    -- Nothing to spawn - netcoredbg speaks DAP over stdio - but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at whatever
    -- it finds.
    setup = function(config, _, callback)
        local shared = require("ezdap.shared")
        local exe, tried = shared.resolve_path(netcoredbg_bins, shared.is_executable)
        if not exe then
            return callback("netcoredbg not found (unpack its release, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        config.command = vim.list_extend({ exe }, netcoredbg_args)
        callback()
    end,
    modes = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest). A `program` ending in
        -- .dll is run by netcoredbg via `dotnet`; anything else runs as an executable.
        binary = {
            description = "debug a .NET assembly",
            request = "launch",
            inputs = {
                command               = { type = "string", completion = "command", required = true, description = "assembly or executable to debug, plus its arguments" },
                cwd                   = { type = "string", completion = "dir", description = "working directory" },
                env                   = { type = "map", description = "environment variables" },
                stop_at_entry         = { type = "boolean", description = "break at program entry" },
                just_my_code          = { type = "boolean", description = "debug only user code, skipping framework code (default true)" },
                enable_step_filtering = { type = "boolean", description = "step over property accessors and operators (default true)" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                local program, args = shared.split_command(inputs.command)
                return {
                    program             = program,
                    args                = args,
                    cwd                 = shared.normalize_path(inputs.cwd),
                    env                 = inputs.env,
                    stopAtEntry         = inputs.stop_at_entry,
                    justMyCode          = inputs.just_my_code,
                    enableStepFiltering = inputs.enable_step_filtering,
                }
            end,
        },
        -- The attach handler reads `processId` alone - the launch-side options are
        -- not consulted here, so none are offered.
        attach = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(inputs)
                local pid, err = require("ezdap.shared").resolve_pid(inputs.pid)
                if not pid then return nil, err end
                return {
                    processId = pid,
                }
            end,
        },
    },
}
