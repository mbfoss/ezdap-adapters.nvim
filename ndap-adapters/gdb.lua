-- https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html

-- Where to look for gdb, in order; the first one new enough for DAP wins. Put
-- your own path first to pin it. "$VAR" and "~" expand anywhere in an entry, as
-- they do in `vim.fs.normalize`; an entry naming an unset or empty variable is
-- skipped. A bare name (no separator) is looked up on $PATH - a good place to
-- add a cross-toolchain gdb such as "arm-none-eabi-gdb".
local gdb_bins = {
    "gdb",
    "gdb-multiarch",
}

-- Flags gdb is started with, after the binary. `--interpreter=dap` is what makes
-- it speak DAP at all.
local gdb_args = { "--interpreter=dap" }

-- `coreFile` is a post-17.2 addition to gdb's DAP attach: an older gdb drops it
-- and fails the attach with the unhelpful "attach requires either 'pid' or
-- 'target'", so the `core` mode checks the version up front instead.
local CORE_MIN = { 17, 3 }

-- `--interpreter=dap` is gdb 14.1 and newer; an older gdb exits with
-- "Interpreter `dap' unrecognized" the moment the session starts.
local DAP_MIN = { 14, 1 }

---gdb's version as `{major, minor}`, parsed from the tail of `gdb --version`'s
---first line ("GNU gdb (GDB) 17.2", "GNU gdb (Ubuntu 12.1-0ubuntu1~22.04) 12.1").
---Cached per binary: a gdb does not change version mid-session.
---@type table<string, integer[]>
local _versions = {}
---@param exe string  the gdb binary to ask
---@return integer[]? version, string? err
local function _gdb_version(exe)
    if _versions[exe] then return _versions[exe] end
    if vim.fn.executable(exe) == 0 then return nil, exe .. " not found" end
    local out = vim.fn.system({ exe, "--version" })
    if vim.v.shell_error ~= 0 then return nil, ("`%s --version` failed: %s"):format(exe, vim.trim(out)) end
    -- The trailing "\n" anchors the match to the *end* of the first line, past any
    -- version-shaped noise in a distro's parenthesised build string; it is appended
    -- in case the output has none of its own.
    local major, minor = (out .. "\n"):match("^[^\n]-(%d+)%.(%d+)[^%s]*%s*\n")
    if not major then return nil, "could not parse gdb version from: " .. vim.trim(vim.split(out, "\n")[1] or "") end
    _versions[exe] = { tonumber(major), tonumber(minor) }
    return _versions[exe]
end

---How `a` orders against `b`: negative, zero or positive.
---@param a integer[]
---@param b integer[]
---@return integer
local function _cmp(a, b)
    for i = 1, 2 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return 0
end

---@param v integer[]
---@return string
local function _fmt(v) return ("%d.%d"):format(v[1], v[2]) end

---The first gdb that exists and is new enough to speak DAP.
---Versions are cached, so the accepted one is re-read for free by the caller.
---@return string? exe, string? err
local function _resolve_gdb()
    local shared = require("ndap.shared")
    -- The reason the *first* candidate was turned down, which is the one worth
    -- reporting: it is the gdb the run asked for.
    local first_err = nil
    local exe, tried = shared.resolve_path(gdb_bins, function(cand)
        local version, err = _gdb_version(cand)
        if version and _cmp(version, DAP_MIN) >= 0 then return true end
        first_err = first_err or err or
            ("%s is gdb %s; DAP support needs gdb %s or newer")
            :format(cand, _fmt(version --[[@as integer[] ]]), _fmt(DAP_MIN))
        return false
    end)
    if exe then return exe end
    return nil, ("%s (tried %s)"):format(first_err or "no gdb found", table.concat(tried, ", "))
end

---@type ndap.AdapterDef
return {
    -- Nothing to spawn - gdb speaks DAP over stdio - but a gdb that cannot do what
    -- the run asks of it fails in ways the session never surfaces legibly, so both
    -- version gates live here, where a plain error string reaches the user.
    setup = function(config, ctx, callback)
        local exe, err = _resolve_gdb()
        if not exe then return callback(err) end
        local version = _gdb_version(exe) --[[@as integer[] ]]
        config.command = vim.list_extend({ exe }, gdb_args)
        -- A raw task names no mode, so it is on its own here: nothing to gate on.
        if ctx.mode == "core" and _cmp(version, CORE_MIN) < 0 then
            return callback(("%s is gdb %s; core files need %s or newer")
                :format(exe, _fmt(version), _fmt(CORE_MIN)))
        end
        callback()
    end,
    modes = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- GDB's `program` (the first word) and `args` (the rest).
        binary = {
            description = "debug a native executable",
            request = "launch",
            inputs = {
                command       = { type = "string", completion = "command", required = true, description = "command line to debug" },
                cwd           = { type = "string", completion = "dir", description = "working directory" },
                env           = { type = "map", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                stop_at_main  = { type = "boolean", description = "break at the start of main" },
                ada_charset   = { type = "string", description = "Ada source character set" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local program, args = shared.split_command(parameters.command)
                return {
                    program                         = program,
                    args                            = args,
                    cwd                             = shared.normalize_path(parameters.cwd),
                    env                             = vim.tbl_extend("force", vim.fn.environ(), parameters.env or {}), -- gdb does not merge env variables on it's own (unlike lldb)
                    stopOnEntry                     = parameters.stop_on_entry,
                    stopAtBeginningOfMainSubprogram = parameters.stop_at_main,
                    adaSourceCharset                = parameters.ada_charset,
                }
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid         = { type = "integer", description = "process id to attach to" },
                program     = { type = "string", completion = "file", description = "local binary for symbols" },
                ada_charset = { type = "string", description = "Ada source character set" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local pid, err = shared.resolve_pid(parameters.pid)
                if not pid then return nil, err end
                return {
                    pid              = pid,
                    program          = shared.normalize_path(parameters.program),
                    adaSourceCharset = parameters.ada_charset,
                }
            end,
        },
        -- GDB's body `target` key is the remote connection string, not a binary.
        remote = {
            description = "connect to a gdbserver / remote target",
            request    = "attach",
            inputs = {
                connection  = { type = "string", required = true, description = "remote target, e.g. host:port" },
                program     = { type = "string", completion = "file", description = "local binary for symbols" },
                ada_charset = { type = "string", description = "Ada source character set" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                return {
                    target           = parameters.connection,
                    program          = shared.normalize_path(parameters.program),
                    adaSourceCharset = parameters.ada_charset,
                }
            end,
        },
        core = {
            description = "post-mortem debug from a core file",
            request    = "attach",
            inputs = {
                corefile    = { type = "string", completion = "file", required = true, description = "core file to load" },
                program     = { type = "string", completion = "file", description = "executable that produced the core" },
                ada_charset = { type = "string", description = "Ada source character set" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                return {
                    coreFile         = shared.normalize_path(parameters.corefile),
                    program          = shared.normalize_path(parameters.program),
                    adaSourceCharset = parameters.ada_charset,
                }
            end,
        },
    },
}
