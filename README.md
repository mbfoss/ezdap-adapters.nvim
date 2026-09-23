# ezdap-adapters.nvim

Ready-made DAP adapter definitions for
[ezdap.nvim](https://github.com/mbfoss/ezdap.nvim). Install it and they are all
available at once.

A definition is one self-contained Lua file describing one debug adapter: how to
find and start it, and the launch and attach modes it supports. It is
configuration only. The adapter itself (`codelldb`, `lldb-dap`, `gdb`, `dlv`, …)
is a separate program you install. Modes describe their own inputs, so
ezdap.nvim can complete, prompt for and validate them.

Because each file stands alone, you can also copy one into your own config and
skip the plugin; see
[A single definition instead](#a-single-definition-instead-).

## Requirements

- Neovim with [ezdap.nvim](https://github.com/mbfoss/ezdap.nvim) installed.
- The debug adapter itself. Every definition searches several locations for it —
  an environment variable you set, `PATH`, the usual system prefixes, and a
  [mason.nvim](https://github.com/mason-org/mason.nvim) package — and the first
  hit wins. mason is never required: any of the other locations works on its
  own, and the search list is a variable at the top of each file. See
  [Available adapters](#available-adapters-) and
  [Locating the adapter](#locating-the-adapter-).

## Quick start

With Neovim 0.12's built-in plugin manager (`:h vim.pack`):

```lua
vim.pack.add({
  "https://github.com/mbfoss/ezdap.nvim",
  "https://github.com/mbfoss/ezdap-adapters.nvim",
})
```

with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mbfoss/ezdap.nvim",
  dependencies = { "mbfoss/ezdap-adapters.nvim" },
}
```

or any other plugin manager. Then:

```vim
" check Neovim version, setup and project state
:checkhealth ezdap

" what an adapter takes: its modes, and each mode's inputs
:Ezdap adapter_info debugpy

" one-off session: adapter, mode, and the mode's inputs as key=value
:Ezdap run debugpy script command=./main.py

" or create a reusable run file for it
:Ezdap new_run_file debugpy script
```

### A single definition instead <!-- tag: single-definition -->

The whole set is not required. Copy only the file you want:

```sh
mkdir -p ~/.config/nvim/ezdap-adapters
curl -o ~/.config/nvim/ezdap-adapters/debugpy.lua \
  https://raw.githubusercontent.com/mbfoss/ezdap-adapters.nvim/main/ezdap-adapters/debugpy.lua
```

ezdap.nvim globs `ezdap-adapters/*.lua` across the runtimepath and registers
each file under its filename stem — `debugpy.lua` becomes the `debugpy` adapter.
The directory sits beside `lsp/` and `plugin/`, not under `lua/`: these are
files read by name, not Lua modules. The plugin works the same way; it puts its
own `ezdap-adapters/` directory on the runtimepath.

Runtimepath order decides ties, so a copy in your own config shadows the
plugin's. You can install the plugin for everything and still keep your own
edited `debugpy.lua`. Hand-copied files are not updated automatically; the
plugin's are.

## Available adapters <!-- tag: adapters -->

ezdap.nvim itself ships only the generic `remote` definition; the
language-specific ones are here. One row per definition, with what it needs
installed.

| Adapter | Debugs | Needs |
| --- | --- | --- |
| [`debugpy`](ezdap-adapters/debugpy.lua) | Python | a Python that can import [debugpy](https://github.com/microsoft/debugpy): `$DEBUGPY_VENV`, `$VIRTUAL_ENV`, a project `.venv`/`venv`/`env`, the mason venv, then `python3` / `python` |
| [`codelldb`](ezdap-adapters/codelldb.lua) | C / C++ / Rust | [`codelldb`](https://github.com/vadimcn/codelldb) on `PATH` or from mason; it bundles LLDB |
| [`lldb`](ezdap-adapters/lldb.lua) | C / C++ / Rust | `lldb-dap`, LLVM's own adapter, on `PATH` — from an LLVM install (a versioned `lldb-dap-21` works too), or from Xcode's toolchain, whose bin directory `xcode-select -p` names |
| [`gdb`](ezdap-adapters/gdb.lua) | C / C++ | [GDB](https://sourceware.org/gdb/) 14.1+ on `PATH`; its own adapter via `gdb --interpreter=dap`; `core` needs 17.3+ |
| [`delve`](ezdap-adapters/delve.lua) | Go | [`dlv`](https://github.com/go-delve/delve) on `PATH`, under `$GOBIN` / `$GOPATH/bin`, or from mason; its own adapter via `dlv dap` |
| [`netcoredbg`](ezdap-adapters/netcoredbg.lua) | .NET | [`netcoredbg`](https://github.com/Samsung/netcoredbg) on `PATH` or from mason |
| [`jdtls`](ezdap-adapters/jdtls.lua) | Java | a running [jdtls](https://github.com/eclipse-jdtls/eclipse.jdt.ls) with its java-debug server started, e.g. by [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls); this definition only connects to it |
| [`js-debug`](ezdap-adapters/js-debug.lua) | JavaScript / TypeScript | `node`, plus [js-debug](https://github.com/microsoft/vscode-js-debug)'s `dapDebugServer.js` — `$JS_DEBUG_HOME` (an unpacked release or npm install), or the mason `js-debug-adapter` package |
| [`php-debug`](ezdap-adapters/php-debug.lua) | PHP | `node`, plus [vscode-php-debug](https://github.com/xdebug/vscode-php-debug)'s `phpDebug.js` — `$PHP_DEBUG_HOME` (an unpacked .vsix), or the mason `php-debug-adapter` package; it fronts [Xdebug](https://xdebug.org/), loaded into the PHP being debugged |
| [`rdbg`](ezdap-adapters/rdbg.lua) | Ruby | [`rdbg`](https://github.com/ruby/debug), from the `debug` gem, on `PATH`, under `$GEM_HOME/bin` / `$GEM_ROOT/bin`, or from mason |
| [`dart`](ezdap-adapters/dart.lua) | Dart / Flutter | the [Dart](https://dart.dev) or [Flutter](https://flutter.dev) SDK on `PATH`, or under `$DART_SDK` / `$FLUTTER_ROOT`; the adapters ship inside the SDK |
| [`bash-debug`](ezdap-adapters/bash-debug.lua) | Bash | `bash-debug-adapter` on `PATH` or from mason ([bash-debug](https://github.com/rogalmic/vscode-bash-debug)); it fronts bashdb, taken from `$BASHDB_HOME` (where a system install is named) or the extension's own `bashdb_dir` |

Mode names say what they do: `binary`, `script`, `package` and the other launch
modes start a new process; `attach` / `process_name` / `remote` / `gdb_remote` /
`listen` connect to a running one; `core` / `replay` load a post-mortem
artifact.

What each mode takes is not listed here: the definitions describe their own
inputs, so ask ezdap.nvim instead:

```vim
:Ezdap adapter_info                 " every registered adapter
:Ezdap adapter_info debugpy         " every mode, with its inputs and their types
:Ezdap adapter_info debugpy script  " just that mode
```

See [`:Ezdap
adapter_info`](https://github.com/mbfoss/ezdap.nvim#ezdap-adapter_info-), help
tag |ezdap-:ezdap-adapter_info|. The same descriptions reach you while typing:
completion after `:Ezdap run <adapter> <mode> ` lists the mode's inputs, and
`:Ezdap new_run_file <adapter> <mode>` writes them all out, commented. A
definition you copy and edit documents itself the same way.

## Locating the adapter <!-- tag: locating -->

Paths a definition resolves — the adapter executable, and anything shipped
beside it — are variables at the top of its file, ready to be pinned or
extended. With the plugin installed, copy the file into
`~/.config/nvim/ezdap-adapters/` and edit it there.

Each file has the same two variables: a singular one (`delve_bin`,
`php_debug_js`, `bashdb_lib_dir`, …) that pins one path and skips detection
entirely, and the plural list beside it (`delve_bins`, `php_debug_jss`, …) that
is searched in order. In a list entry, a leading `$` names an environment
variable and the entry is skipped when it is unset, `~` is the home directory,
and a bare name with no separator is looked up on `PATH`.

Lists cover only what `PATH` does not. A bare `dlv` finds
`/usr/local/bin/dlv` on its own, so the only things spelled out are what `PATH`
cannot reach: an SDK prefix named by a toolchain variable, and mason's package
directory. No list hardcodes an absolute or home-relative path, which keeps
every definition working the same way on Linux, macOS and Windows. A package
manager's prefix is not there — Homebrew, a distro package and a hand-built
install all put the binary somewhere `PATH` reaches — and neither is any prefix
an unpacked release might sit under: point an environment variable, or the
file's singular variable, at wherever you put it.

For the same reason an adapter that is a plain executable gets no environment
variable of its own. The variables that are there either belong to the
language's own toolchain (`$GOBIN`, `$GOPATH`, `$GEM_HOME`, `$VIRTUAL_ENV`,
`$DART_SDK`, `$FLUTTER_ROOT`) or name something `PATH` cannot express — a venv,
a `.js` entry point, an unpacked extension directory (`$DEBUGPY_VENV`,
`$JS_DEBUG_HOME`, `$PHP_DEBUG_HOME`, `$BASHDB_HOME`, `$BASH_DEBUG_ADAPTER`).

mason paths are entries in these lists like any other, so mason is entirely
optional; a definition never requires it, and never looks at whether it is
installed. Entries are literal paths, with no globbing, so a VS Code extension
directory carrying a version suffix has to be named in full or pinned with the
singular variable.

## Writing your own <!-- tag: writing -->

An adapter definition is a single Lua file returning one `ezdap.AdapterDef`.
See [Writing an adapter definition][writing].

[writing]: https://github.com/mbfoss/ezdap.nvim/blob/main/WRITING-DEFINITIONS.md

Contributions of new definitions are welcome.

## License <!-- tag: license -->

[MIT](LICENSE).
