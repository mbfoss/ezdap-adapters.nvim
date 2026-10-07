-- Directories that may hold the bashdb library, in order; the first one that
-- holds a `bashdb` script wins. Put your own directory first to pin it. "$VAR"
-- and "~" expand anywhere in an entry, as they do in `vim.fs.normalize`; an
-- entry naming an unset or empty variable is skipped. Mason is only one of the
-- entries and not required: the extension ships the same `bashdb_dir` inside its
-- .vsix, which $BASH_DEBUG_ADAPTER can point at, and a system bashdb install is
-- named through $BASHDB_HOME.
local bashdb_lib_dirs = {
    "$BASHDB_HOME",
    "$BASH_DEBUG_ADAPTER/extension/bashdb_dir",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "extension", "bashdb_dir"),
}

-- Those same directories as the driver script inside each, so `resolve_path` is
-- handed the file it actually tests.
local bashdb_scripts = vim.tbl_map(function(dir) return vim.fs.joinpath(dir, "bashdb") end,
    bashdb_lib_dirs)

-- Where to look for the adapter, in order; the first executable wins. Put your
-- own path first to pin it. A bare name (no separator) is looked up on $PATH,
-- which is where an npm or distro install is picked up from; mason's shim is on
-- $PATH only when mason.nvim was set up to put it there, so the binary inside
-- the package is listed too; mason itself is not required.
local bash_debug_bins = {
    "bash-debug-adapter",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", "bash-debug-adapter"),
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "bash-debug-adapter"),
}

-- External programs the adapter shells out to; each is looked up on $PATH unless
-- given as an absolute path.
local bash_tools = {
    bash   = "bash",
    cat    = "cat",
    mkfifo = "mkfifo",
    pkill  = "pkill",
}

---The driver script for the body's `pathBashdb`/`pathBashdbLib`: the one inside a
---resolved library directory, or a `bashdb` on $PATH when only a system install is
---around, which has no library directory of its own.
---@return string? script, string? lib_dir, string? err
local function _bashdb()
    local shared = require("ndap.shared")
    local script, tried = shared.resolve_path(bashdb_scripts,
        function(path) return vim.fn.filereadable(path) == 1 end)
    if script then return script, vim.fs.dirname(script) end
    if shared.is_executable("bashdb") then return "bashdb" end
    return nil, nil, "bashdb not found (install bashdb, set $BASHDB_HOME, or point " ..
        "$BASH_DEBUG_ADAPTER at the extension's bashdb_dir); tried " ..
        table.concat(tried, ", ") .. ", bashdb"
end

---@type ndap.AdapterDef
return {
    -- Nothing to spawn - the adapter speaks DAP over stdio - but a missing binary
    -- fails the session with no legible reason, so the lookup happens here, where
    -- a plain error string reaches the user, and the config is pointed at what it
    -- finds.
    setup    = function(config, _, callback)
        local shared = require("ndap.shared")
        local exe, tried = shared.resolve_path(bash_debug_bins, shared.is_executable)
        if not exe then
            return callback("bash-debug-adapter not found (install it from npm, a distro package, or mason); tried " ..
                table.concat(tried, ", "))
        end
        config.command = exe
        callback()
    end,
    modes = {
        script = {
            description = "debug a bash script",
            request = "launch",
            inputs = {
                script        = { type = "string", completion = "file", description = "bash script to debug" },
                cwd           = { type = "string", completion = "dir", description = "working directory" },
                env           = { type = "map", description = "environment variables" },
                terminal_kind = { type = "string", completion = { "integrated", "external", "debugConsole" }, description = "where the debuggee's stdio goes (default integrated)" },
            },
            -- The body names the driver script and its library, and `build` runs
            -- before `setup`, so this lookup - unlike every other - cannot wait until
            -- then. A missing bashdb is an abort, not a body naming a script that is
            -- not there.
            build = function(parameters)
                local shared = require("ndap.shared")
                local script, lib_dir, err = _bashdb()
                if not script then return nil, err end
                return {
                    type          = "bashdb",
                    name          = "bash-debug",
                    program       = shared.normalize_path(parameters.script),
                    cwd           = shared.normalize_path(parameters.cwd),
                    env           = parameters.env,
                    pathBash      = bash_tools.bash,
                    pathBashdb    = script,
                    -- Absent for a system install, which has no library directory.
                    pathBashdbLib = lib_dir,
                    pathCat       = bash_tools.cat,
                    pathMkfifo    = bash_tools.mkfifo,
                    pathPkill     = bash_tools.pkill,
                    terminalKind  = parameters.terminal_kind or "integrated",
                }
            end,
        },
    },
}
