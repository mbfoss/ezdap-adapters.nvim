-- netcoredbg has no options document; the authoritative field set is the keys its
-- VS Code protocol handler reads, in Samsung/netcoredbg's
-- src/protocols/vscodeprotocol.cpp ("launch" and "attach" handlers). That set is
-- small and complete as written below — launch takes seven keys, attach only
-- `processId`. netcoredbg spells entry-stop `stopAtEntry`, not the standard
-- `stopOnEntry`, and has no runInTerminal/console argument.

-- Set to a netcoredbg path to skip detection entirely; otherwise the config's
-- netcoredbg is tried first, then the candidates below.
local netcoredbg_bin = nil ---@type string?

-- Where to look for netcoredbg, in order. A leading "$" names an environment
-- variable, skipped when unset; "~" expands to the home directory. A bare name
-- (no separator) is looked up on $PATH, which is where an unpacked release is
-- picked up from — put its directory on $PATH, or set `netcoredbg_bin`. Mason
-- ships a shim in its `bin`, which is on $PATH only when mason.nvim was set up to
-- put it there, so the binary inside the package is listed too; mason itself is
-- not required.
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
    command = vim.list_extend({ netcoredbg_bin or netcoredbg_bins[1] }, netcoredbg_args),
    -- Nothing to spawn — netcoredbg speaks DAP over stdio — but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at whatever
    -- it finds.
    setup = function(config, _, callback)
        local shared = require("ezdap.shared")
        local from_config = (type(config.command) == "table" and config.command or { config.command }) --[[@as string[] ]]
        local candidates = netcoredbg_bin and { netcoredbg_bin } or
            vim.list_extend({ from_config[1] }, netcoredbg_bins)
        local exe, tried = shared.resolve_path(candidates, shared.is_executable)
        if not exe then
            return callback("netcoredbg not found (unpack its release, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        -- Keep any flags the config carries past the binary.
        config.command = vim.list_extend({ exe },
            #from_config > 1 and vim.list_slice(from_config, 2) or netcoredbg_args)
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
        -- The attach handler reads `processId` alone — the launch-side options are
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
