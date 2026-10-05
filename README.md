# ndebug-adapters.nvim

> [!NOTE]
> **Work in progress.** Stable and usable as it stands, but still evolving:
> changes, including breaking ones, can land at any time. Pin a commit if you
> need a fixed target.

Ready-made DAP adapter definitions for
[ndebug.nvim](https://github.com/mbfoss/ndebug.nvim). Install it and they are all
available at once.

A definition is one self-contained Lua file describing one debug adapter: how to
find and start it, and the launch and attach modes it supports. It is
configuration only. The adapter itself (`codelldb`, `lldb-dap`, `gdb`, `dlv`, …)
is a separate program you install. Modes describe their own inputs, so
ndebug.nvim can complete, prompt for and validate them.

Because each file stands alone, you can also copy one into your own config and
skip the plugin; see
[A single definition instead](#a-single-definition-instead-).

## Requirements

- Neovim with [ndebug.nvim](https://github.com/mbfoss/ndebug.nvim) installed.
- The debug adapter itself. Every definition searches several locations for it
  (an environment variable you set, `PATH`, the usual system prefixes, and a
  [mason.nvim](https://github.com/mason-org/mason.nvim) package) and the first
  hit wins. mason is never required: any of the other locations works on its
  own, and the search list is a variable at the top of each file. See
  [Available adapters](#available-adapters-) and
  [Locating the adapter](#locating-the-adapter-).

## Quick start

With Neovim 0.12's built-in plugin manager (`:h vim.pack`):

```lua
vim.pack.add({
  "https://github.com/mbfoss/ndebug.nvim",
  "https://github.com/mbfoss/ndebug-adapters.nvim",
})
```

with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mbfoss/ndebug.nvim",
  dependencies = { "mbfoss/ndebug-adapters.nvim" },
}
```

or any other plugin manager. Then:

```vim
" check Neovim version, setup and project state
:checkhealth ndebug

" what an adapter takes: its modes, and each mode's inputs
:Ndebug adapter_info debugpy

" one-off session: adapter, mode, and the mode's inputs as --name value
:Ndebug run debugpy script --command ./main.py

" or create a reusable run file for it
:Ndebug new_run_file debugpy script
```

### A single definition instead <!-- tag: single-definition -->

The whole set is not required. Copy only the file you want:

```sh
mkdir -p ~/.config/nvim/ndebug-adapters
curl -o ~/.config/nvim/ndebug-adapters/debugpy.lua \
  https://raw.githubusercontent.com/mbfoss/ndebug-adapters.nvim/main/ndebug-adapters/debugpy.lua
```

ndebug.nvim globs `ndebug-adapters/*.lua` across the runtimepath and registers
each file under its filename stem, so `debugpy.lua` becomes the `debugpy`
adapter.
The directory sits beside `lsp/` and `plugin/`, not under `lua/`: these are
files read by name, not Lua modules. The plugin works the same way; it puts its
own `ndebug-adapters/` directory on the runtimepath.

Runtimepath order decides ties, so a copy in your own config shadows the
plugin's. You can install the plugin for everything and still keep your own
edited `debugpy.lua`. Hand-copied files are not updated automatically; the
plugin's are.

## Available adapters <!-- tag: adapters -->

ndebug.nvim itself ships only the generic `remote` definition; the
language-specific ones are here. One row per definition, with what it needs
installed.

| Adapter | Debugs | Needs |
| --- | --- | --- |
| [`debugpy`](ndebug-adapters/debugpy.lua) | Python | a Python that can import [debugpy](https://github.com/microsoft/debugpy): `$DEBUGPY_VENV`, `$VIRTUAL_ENV`, a project `.venv`/`venv`/`env`, the mason venv, then `python3` / `python` |
| [`codelldb`](ndebug-adapters/codelldb.lua) | C / C++ / Rust | [`codelldb`](https://github.com/vadimcn/codelldb) on `PATH` |
| [`lldb`](ndebug-adapters/lldb.lua) | C / C++ / Rust | `lldb-dap`, LLVM's own adapter, on `PATH` |
| [`gdb`](ndebug-adapters/gdb.lua) | C / C++ | [GDB](https://sourceware.org/gdb/) 14.1+ on `PATH` |
| [`delve`](ndebug-adapters/delve.lua) | Go | [`dlv`](https://github.com/go-delve/delve) on `PATH`, under `$GOBIN` / `$GOPATH/bin` |
| [`netcoredbg`](ndebug-adapters/netcoredbg.lua) | .NET | [`netcoredbg`](https://github.com/Samsung/netcoredbg) on `PATH` |
| [`jdtls`](ndebug-adapters/jdtls.lua) | Java | a running [jdtls](https://github.com/eclipse-jdtls/eclipse.jdt.ls) with its java-debug server started, e.g. by [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) |
| [`js-debug`](ndebug-adapters/js-debug.lua) | JavaScript / TypeScript | `node`, plus [js-debug](https://github.com/microsoft/vscode-js-debug)'s `dapDebugServer.js` from `$JS_DEBUG_HOME` (an unpacked release or npm install), or the mason `js-debug-adapter` package |
| [`php-debug`](ndebug-adapters/php-debug.lua) | PHP | `node`, plus [vscode-php-debug](https://github.com/xdebug/vscode-php-debug)'s `phpDebug.js` from `$PHP_DEBUG_HOME` (an unpacked .vsix), or the mason `php-debug-adapter` package; it fronts [Xdebug](https://xdebug.org/), loaded into the PHP being debugged |
| [`rdbg`](ndebug-adapters/rdbg.lua) | Ruby | [`rdbg`](https://github.com/ruby/debug), from the `debug` gem, on `PATH`, under `$GEM_HOME/bin` / `$GEM_ROOT/bin` |
| [`dart`](ndebug-adapters/dart.lua) | Dart / Flutter | the [Dart](https://dart.dev) or [Flutter](https://flutter.dev) SDK on `PATH`, or under `$DART_SDK` / `$FLUTTER_ROOT`; the adapters ship inside the SDK |
| [`bash-debug`](ndebug-adapters/bash-debug.lua) | Bash | `bash-debug-adapter` on `PATH` or from mason ([bash-debug](https://github.com/rogalmic/vscode-bash-debug)); it fronts bashdb, taken from `$BASHDB_HOME` (where a system install is named) or the extension's own `bashdb_dir` |

Mode names say what they do: `binary`, `script`, `package` and the other launch
modes start a new process; `attach` / `process_name` / `remote` / `gdb_remote` /
`listen` connect to a running one; `core` / `replay` load a post-mortem
artifact.

What each mode takes is not listed here: the definitions describe their own
inputs, so ask ndebug.nvim instead:

```vim
:Ndebug adapter_info                 " every registered adapter
:Ndebug adapter_info debugpy         " every mode, with its inputs and their types
:Ndebug adapter_info debugpy script  " just that mode
```

See [`:Ndebug
adapter_info`](https://github.com/mbfoss/ndebug.nvim#ndebug-adapter_info-), help
tag |ndebug-:ndebug-adapter_info|. The same descriptions reach you while typing:
completion after `:Ndebug run <adapter> <mode> ` lists the mode's inputs as
`--name`, and `:Ndebug new_run_file <adapter> <mode>` writes them all out,
commented. A definition you copy and edit documents itself the same way.

## Locating the adapter <!-- tag: locating -->

Paths — the adapter executable, and anything shipped beside it — come from a
candidate list at the top of the definition file. Each thing a definition locates
— the executable, a script, a library directory, `node` — has its own list
(`delve_bins`, `php_debug_jss`, `bashdb_lib_dirs`), searched in order; the first
entry that exists wins.

```lua
local delve_bins = {
    "dlv",             -- bare name: looked up on $PATH
    "$GOBIN/dlv",      -- leading $: environment variable, skipped when unset
    "~/go/bin/dlv",    -- ~: home directory
}
```

To override, either:

- set an environment variable an entry already reads (`$GOBIN`,
  `$JS_DEBUG_HOME`, `$DEBUGPY_VENV`, …) — no copy, no edit; or
- copy the file into `~/.config/nvim/ndebug-adapters/` and edit — put your own
  path first in the list to pin it.
- Lists carry what `PATH` cannot reach: SDK prefixes behind a toolchain
  variable, mason's package directory. `PATH` already finds a bare `dlv`, so no
  absolute or home-relative paths, and no package manager prefixes.
- Mason optional: its paths are ordinary entries; nothing checks for it.
- Environment variables only where `PATH` cannot express the path: `$GOBIN`,
  `$GOPATH`, `$GEM_HOME`, `$DART_SDK`, `$FLUTTER_ROOT`; `$DEBUGPY_VENV`,
  `$JS_DEBUG_HOME`, `$PHP_DEBUG_HOME` (venv, `.js` entry point, unpacked
  extension). A plain executable gets none.

## Writing your own <!-- tag: writing -->

An adapter definition is a single Lua file returning one `ndebug.AdapterDef`.
See [Writing an adapter definition][writing].

[writing]: https://github.com/mbfoss/ndebug.nvim/blob/main/WRITING-DEFINITIONS.md

## License <!-- tag: license -->

[MIT](LICENSE).
