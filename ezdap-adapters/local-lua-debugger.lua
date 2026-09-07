-- Lua — https://github.com/tomblind/local-lua-debugger-vscode
-- Fields follow the `lua-local` configurationAttributes in that extension's
-- package.json. `program` is a nested table the js-based adapter consumes, and is
-- a oneOf: a Lua interpreter plus an entry file, or a custom command.

-- Set to the extension directory to skip detection entirely; otherwise the first
-- candidate below that holds a debugAdapter.js wins.
local lua_debugger_dir = nil ---@type string?

-- Where to look for the unpacked extension, in order: the directory holding both
-- `extension/debugAdapter.js` (the adapter) and `debugger/` (the Lua side the
-- debuggee requires). A leading "$" names an environment variable, skipped when
-- unset; "~" expands to the home directory. Mason is only one of the entries and
-- not required — unpack the .vsix anywhere and point $LOCAL_LUA_DEBUGGER_HOME at
-- it. Entries are literal paths, so a VS Code install, which carries a version
-- suffix, needs that directory named here, or `lua_debugger_dir` set to it.
local lua_debugger_dirs = {
    "$LOCAL_LUA_DEBUGGER_HOME",
    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "local-lua-debugger-vscode", "extension"),
}

-- The Node.js that runs the adapter; `node_bin` pins one, `node_bins` is searched.
local node_bin = nil ---@type string?
local node_bins = { "node" }

---The js entry point inside an extension directory.
---@param dir string
---@return string
local function _adapter_js(dir) return vim.fs.joinpath(dir, "extension", "debugAdapter.js") end

---LUA_PATH for the debuggee, so its `require("lldebugger")` finds the Lua side.
---The trailing ";;" keeps the default path in place alongside it.
---@param dir string
---@return string
local function _lua_path(dir) return vim.fs.joinpath(dir, "debugger", "?.lua") .. ";;" end

---Fields both launch shapes accept, alongside their own `program` variant.
---@type table<string, ezdap.Input>
local _common_inputs = {
    cwd                 = { type = "string", completion = "dir", description = "working directory" },
    env                 = { type = "map", description = "environment variables" },
    communication       = { type = "string", completion = { "stdio", "pipe" }, description = "adapter transport" },
    script_roots        = { type = "list", completion = "dir", description = "alternate paths to find Lua scripts in" },
    script_files        = { type = "list", description = "globs of scripts to debug (needed for source-mapped breakpoints)" },
    ignore_patterns     = { type = "list", description = "Lua patterns matching scripts to skip when stepping" },
    step_unmapped_lines = { type = "boolean", description = "step into Lua when a source-mapped line has no mapping" },
    break_in_coroutines = { type = "boolean", description = "break on errors raised inside coroutines" },
    stop_on_entry       = { type = "boolean", description = "break on the first line after the debug hook is set" },
    verbose             = { type = "boolean", description = "enable verbose debugger output" },
}

---@param ... table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_common_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---Assigns everything outside `program`, which each mode fills in itself.
---@param inputs table<string, any>
---@return table params
local function _common_body(inputs)
    local shared = require("ezdap.shared")
    local params = {}
    params.type              = "lua-local"
    params.name              = "Debug"
    params.cwd               = shared.normalize_path(inputs.cwd)
    params.env               = inputs.env
    params.scriptRoots       = shared.normalize_paths(inputs.script_roots)
    params.scriptFiles       = inputs.script_files
    params.ignorePatterns    = inputs.ignore_patterns
    params.stepUnmappedLines = inputs.step_unmapped_lines
    params.breakInCoroutines = inputs.break_in_coroutines
    params.stopOnEntry       = inputs.stop_on_entry
    params.verbose           = inputs.verbose
    return params
end

---@type table<string, ezdap.Mode>
local _modes = {
    -- One `command` input carries the whole command line; `build` splits it into
    -- the script (`program.file`) and `args` (the rest).
    script = {
        description = "debug a Lua script",
        request = "launch",
        inputs = _inputs {
            command = { type = "string", completion = "command", required = true, description = "script to debug, plus its arguments" },
            lua     = { type = "string", description = "Lua interpreter to run the script with (default lua)" },
        },
        build = function(inputs)
            local params = _common_body(inputs)
            -- The script goes inside `program`, not beside it, so the pair is
            -- split off first rather than assigned straight to the body.
            local file, args = require("ezdap.shared").split_command(inputs.command)
            params.program = {
                lua           = inputs.lua or vim.fn.exepath("lua"),
                file          = file,
                communication = inputs.communication or "stdio",
            }
            params.args = args
            return params
        end,
    },
    -- The custom-command shape: an executable that embeds Lua drives the session
    -- itself, so there is no interpreter or entry file to name.
    executable = {
        description = "debug a custom executable that embeds Lua",
        request = "launch",
        inputs = _inputs {
            command = { type = "string", completion = "command", required = true, description = "custom command to run, plus its arguments" },
        },
        build = function(inputs)
            local params = _common_body(inputs)
            local cmd, args = require("ezdap.shared").split_command(inputs.command)
            params.program = {
                command       = cmd,
                communication = inputs.communication or "stdio",
            }
            params.args = args
            return params
        end,
    },
}

---The candidate a pre-`setup` default is built from: the first literal entry, so
---the placeholder never shows an unexpanded "$VAR". `setup` resolves the real one.
---@param candidates string[]
---@return string
local function _first_literal(candidates)
    for _, cand in ipairs(candidates) do
        if not cand:match("^%$") then return cand end
    end
    return candidates[1]
end

local _default_dir = lua_debugger_dir or _first_literal(lua_debugger_dirs)

---@type ezdap.AdapterDef
return {
    command  = { node_bin or node_bins[1], _adapter_js(_default_dir) },
    env      = { LUA_PATH = _lua_path(_default_dir) },
    -- The extension is a directory of js and Lua rather than a binary on $PATH, so
    -- both halves are located here — the adapter this node runs, and the LUA_PATH
    -- the debuggee needs — and a miss is reported as a plain error string.
    setup = function(config, _, callback)
        local shared = require("ezdap.shared")
        local dir, tried = shared.resolve_path(
            lua_debugger_dir and { lua_debugger_dir } or lua_debugger_dirs,
            function(cand) return vim.fn.filereadable(_adapter_js(cand)) == 1 end)
        if not dir then
            return callback("local-lua-debugger-vscode not found (unpack its .vsix, or install it via mason); tried " ..
                table.concat(tried, ", "))
        end
        local node, node_tried = shared.resolve_path(
            node_bin and { node_bin } or node_bins, shared.is_executable)
        if not node then
            return callback("node not found; tried " .. table.concat(node_tried, ", "))
        end
        config.command = { node, _adapter_js(dir) }
        -- A fresh table: `config.env` is the def's own `env` above, shared by every run.
        config.env = vim.tbl_extend("force", config.env or {}, { LUA_PATH = _lua_path(dir) })
        callback()
    end,
    modes = _modes,
}
