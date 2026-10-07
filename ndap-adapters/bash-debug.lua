-- Directories that may hold the bashdb library, in order; the first one that
-- holds a `bashdb` script wins. Put your own directory first to pin it. A
-- leading "$" names an environment variable, skipped when unset; "~" expands to
-- the home directory. Mason is only one of the entries and not required: the
-- extension ships the same `bashdb_dir` inside its .vsix, which
-- $BASH_DEBUG_ADAPTER can point at, and a system bashdb install is named through
-- $BASHDB_HOME.
local bashdb_lib_dirs = {
    "$BASHDB_HOME",
    "$BASH_DEBUG_ADAPTER/extension/bashdb_dir",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "extension", "bashdb_dir"),
}

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

---The first candidate that is a directory.
---@return string?
local function _resolve_lib_dir()
    local shared = require("ndap.shared")
    return (shared.resolve_path(bashdb_lib_dirs, shared.is_directory))
end

---The bashdb driver script: the one inside the resolved library directory, or a
---bashdb on $PATH when only a system install is around.
---@param lib_dir string?
---@return string
local function _bashdb_script(lib_dir)
    return lib_dir and vim.fs.joinpath(lib_dir, "bashdb") or "bashdb"
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
            build = function(parameters)
                local shared = require("ndap.shared")
                local lib_dir = _resolve_lib_dir()
                return {
                    type          = "bashdb",
                    name          = "Launch Bash Script",
                    program       = shared.normalize_path(parameters.script),
                    cwd           = shared.normalize_path(parameters.cwd),
                    env           = parameters.env,
                    pathBash      = bash_tools.bash,
                    pathBashdb    = _bashdb_script(lib_dir),
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
