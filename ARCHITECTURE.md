# df-nvim Architecture

df-nvim is a Neovim take on VS Code's Data Wrangler. It shows tabular data in
[VisiData](https://www.visidata.org/) running inside a Neovim terminal buffer.
You can also inspect live pandas/polars dataframes from a paused Python debug
session (nvim-dap + debugpy).

Status legend: ✅ implemented · 🗓️ planned

## Overview

```mermaid
flowchart LR
    subgraph Neovim
        CMD[":OpenViewer / :OpenDFLens / :CloseViewer"]
        INS[":DfInspect expr / gd in dap-ui"]
        CORE["df-nvim.lua<br/>viewer + commands"]
        DAPM["df-nvim/dap.lua<br/>evaluate + serialize"]
        TERM["terminal buffer<br/>(tab / float / vsplit)"]
    end

    subgraph Debuggee["Python process (debugpy)"]
        DF["pandas / polars DataFrame"]
    end

    FILE[("~/.cache/nvim/df-nvim/<br/>&lt;hrtime&gt;.parquet | .csv")]
    VD["visidata"]

    CMD --> CORE
    INS --> CORE --> DAPM
    DAPM -- "DAP evaluate requests<br/>via nvim-dap" --> DF
    DF -- "to_parquet / to_csv" --> FILE
    DAPM -- "path" --> CORE
    CORE -- "jobstart(term=true)" --> TERM --> VD
    VD -- reads --> FILE
```

## Modules

| File | Responsibility |
|---|---|
| `lua/df-nvim.lua` | Viewer lifecycle (open/focus/close/toggle), layout handling, argument parsing, user commands, keymaps, `setup()` |
| `lua/df-nvim/dap.lua` | Talks to the active nvim-dap session: detects the dataframe library, writes the frame to a temp file (format fallback), then hands the path back to the viewer |
| `lua/df-nvim/install.lua` 🗓️ | `:DfInstall`: creates a managed venv with VisiData + pyarrow |
| `lua/df-nvim/health.lua` 🗓️ | `:checkhealth df-nvim` |

## 1. Viewer core ✅

`df-nvim.lua` keeps a single viewer instance in `M.state`
(`buf`, `win`, `tab`, `layout`, `job`).

```mermaid
stateDiagram-v2
    [*] --> Closed
    Closed --> Open: open_if_closed(path, layout)<br/>create scratch buf, open layout,<br/>jobstart visidata path
    Open --> Open: open_if_closed(...)<br/>focus() only (no reload)
    Open --> Closed: close_if_open()<br/>close wins/tab, delete buf, reset_state()
    Closed --> Open: toggle()
    Open --> Closed: toggle()
```

- **Layouts:** `tab` (default) uses `nvim_open_tabpage`. `float` is a centered
  window at 80% of the editor size with a rounded border. `vsplit` uses
  `:vsplit`.
- **"Is open" check:** the buffer must be valid, plus the tab (for the `tab`
  layout) or the window (for the others).
- **Launching VisiData:** `vim.fn.jobstart({ "visidata", filepath }, { term = true })`.
  VisiData chooses its loader from the file extension.

### Commands and argument parsing

| Command | Behavior |
|---|---|
| `:OpenViewer <path> [layout]` | Opens the file in VisiData |
| `:OpenDFLens` / `<leader>hw` | Toggles a fixed test file (`/tmp/dflens_test.csv`) |
| `:CloseViewer` | Closes the viewer |

`parse_arg_and_layout(raw)` takes the raw, unsplit argument string, so paths
containing spaces still work:

1. If the argument starts with a quote (`"…"` or `'…'`), the quoted part is the
   value and any trailing word is checked against `tab | float | vsplit`.
2. Otherwise, if the last whitespace-separated word is a layout keyword, it is
   split off. Everything before it is the value.
3. If no layout is given, it defaults to `tab`.

## 2. Debug session inspection ✅

Registered only when `opts.dap ~= false` and `require("dap")` succeeds at
`setup()` time.

- `:DfInspect <python expr> [layout]`: evaluates any Python expression in the
  paused frame.
- `gd` (configurable with `dap_inspect_keymap`) in the `dapui_scopes` and
  `dapui_watches` buffers: reads the variable name from the current line and
  inspects it. Only registered when nvim-dap-ui is installed.

```mermaid
sequenceDiagram
    participant U as User
    participant C as df-nvim.lua
    participant D as dap.lua
    participant S as nvim-dap session
    participant P as debugpy / Python

    U->>C: :DfInspect df vsplit
    C->>C: parse_arg_and_layout()
    C->>D: inspect("df", "vsplit")
    D->>S: dap.session(), session.current_frame
    alt no session / not paused
        D-->>U: notify ERROR
    end
    D->>S: evaluate `type(df).__module__.split(".")[0]`
    S->>P: DAP "evaluate" (context=repl, frameId)
    P-->>D: "'pandas'" | "'polars'" | other
    alt unsupported
        D-->>U: notify ERROR "not a supported dataframe"
    end
    D->>D: write_frame() (see section 3)
    D->>C: open_if_closed(path, layout)
    C->>U: VisiData in terminal buffer
```

## 3. Serialization format and fallback ✅

The `format` option is set in `setup()` and stored in
`require("df-nvim.dap").config.format`. An invalid value shows a warning and
resets to `auto`.

| `format` | Tries, in order |
|---|---|
| `auto` (default) | parquet, then csv |
| `parquet` | parquet only |
| `csv` | csv only |

Writers for each library:

| | pandas | polars |
|---|---|---|
| parquet | `to_parquet` | `write_parquet` |
| csv | `to_csv` | `write_csv` |

```mermaid
flowchart TD
    A["write_frame(kind, expr)"] --> B["next format in FORMAT_ORDER[format]"]
    B --> C["path = stdpath('cache')/df-nvim/&lt;hrtime&gt;.&lt;ext&gt;"]
    C --> E["DAP evaluate: expr.&lt;writer&gt;(r'path')"]
    E -->|ok| F["callback(path) → open viewer"]
    E -->|error, formats left| G["notify INFO: '&lt;ext&gt; write failed, falling back'"] --> B
    E -->|error, none left| H["notify ERROR: failed to serialize"]
```

Why use parquet: it keeps dtypes (datetimes, categoricals, nullable ints) and
is faster and smaller than CSV.

Why keep the CSV fallback: in the debuggee, parquet writes fail when:

- `pyarrow` is missing in the debuggee's environment (pandas only; polars
  writes parquet natively)
- columns have non-string names (e.g. after a `pivot` or `DataFrame(ndarray)`)
- `object` columns hold mixed types, or the frame has MultiIndex columns

### debugpy setup (user side)

nvim-dap needs a debugpy adapter, most easily through nvim-dap-python:

```lua
require("dap-python").setup(vim.fn.expand("~/.virtualenvs/debugpy/bin/python"))
require("df-nvim").setup({ format = "auto", dap_inspect_keymap = "gd" })
```

Attach mode: `python -m debugpy --listen 5678 --wait-for-client script.py`.

## 4. VisiData environment 🗓️

Goal: VisiData (with `pyarrow`, so it can read parquet) should work without
manual setup.

```mermaid
flowchart TD
    subgraph install[":DfInstall (build = ':DfInstall' in lazy.nvim)"]
        I1{"uv on PATH?"} -->|yes| I2["uv venv + uv pip install visidata pyarrow"]
        I1 -->|no| I3["python3 -m venv + pip install visidata pyarrow"]
        I2 & I3 --> V[("stdpath('data')/df-nvim/venv")]
    end

    subgraph resolve["Resolving the VisiData binary at open()"]
        R1{"opts.visidata_cmd set?"} -->|yes| R4["use it"]
        R1 -->|no| R2{"managed venv bin/vd exists?"}
        R2 -->|yes| R5["use venv vd"]
        R2 -->|no| R3["'visidata' on PATH"]
    end

    V -.-> R2
```

- The install runs asynchronously with `vim.system`, so Neovim stays usable.
- The venv lives in `stdpath("data")`, not in the plugin directory, because
  plugin managers own that directory and may wipe it on update.
- `:checkhealth df-nvim` reports which binary will be used, whether it can
  `import pyarrow`, and whether nvim-dap and nvim-dap-ui are available.
- **Out of scope:** the debuggee's `pyarrow`. That is the user's project
  environment, so the plugin doesn't install into it. The `auto` fallback
  covers this case.

## Known limitations

- **Stale viewer:** `open_if_closed` only focuses an existing viewer. A second
  `:DfInspect` doesn't show the new file until `:CloseViewer` is run.
- **Remote/container debugging:** the debuggee writes the temp file on its own
  machine. Neovim's cache path must be reachable there, otherwise it needs a
  shared path or path mapping.
- **Large frames:** debugpy warns when an evaluate call takes over about 3
  seconds (`PYDEVD_WARN_EVALUATION_TIMEOUT`), and the debugger blocks during
  the write.
- **Temp files:** files in `stdpath('cache')/df-nvim/` are never cleaned up.
- **No exit handling:** the VisiData job has no `on_exit` handler yet (TODO in
  `open()`).
