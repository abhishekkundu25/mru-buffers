# mru-buffers

Harpoon-inspired MRU switching for Neovim that keeps a unique ring of recently used buffers and lets you preview entries before committing to them. It ships with a minimal UI, safe defaults, and is easy to wire into any plugin manager such as `lazy.nvim`.

## Features

- Maintains a capped MRU ring that ignores special buffers (Telescope, help, terminals, etc.)
- Preview mode lets you cycle through buffers without reordering the ring until you actually edit or move
- Pin up to 9 files; pinned entries stay in the MRU ring even after `:bd`/wipe and can be reopened
- Configurable keymaps, ignore rules, and "touch" events that trigger commits

## Requirements

- Neovim 0.9+ (needs `vim.on_key` and modern Lua APIs)

## Installation

### lazy.nvim

```lua
{
  "abhishekkundu25/mru-buffers",
  event = "VeryLazy",
  version = "0.8",
  config = function()
    require("mru-buffers").setup({
      -- optional configuration
    })
  end,
}
```

### Packer (example)

```lua
use({
  "abhishekkundu25/mru-buffers",
  config = function()
    require("mru-buffers").setup()
  end,
})
```

## Usage

Call `require("mru-buffers").setup()` once (usually from your plugin manager). After that you get:

- Default keymaps:
  - `[b`: cycle to previous entry in the MRU ring
  - `]b`: cycle to next entry
  - `<leader>he`: open the floating MRU menu
  - `<leader>p1`..`<leader>p9`: pin current buffer to slot 1..9
  - `<leader>1`..`<leader>9`: jump to pinned slot 1..9
- Commands:
  - `:MRUMenu`: toggle the menu
  - `:MRUPin {1..9}`: pin current buffer to a slot
  - `:MRUUnpin {1..9}`: clear a pin slot
  - `:MRURing`: print the ring in `vim.notify`
- Lua helpers: `require("mru-buffers").prev()`, `.next()`, `.open_menu()`, etc. if you want to create custom maps or integrate elsewhere.

### Preview mode

Cycling uses preview semantics by default: buffers that you jump to via your cycle keys (defaults: `[b` / `]b`) do not get committed to the front of the MRU list until you actually touch them (insert, move, edit). Internal cursor events and repeated cycle presses are ignored so the ring stays stable while you browse around.

### Pins

Pins are stored by file path. If you pin a file and later delete the buffer (`:bd`, wipe, etc.), the entry remains in the MRU ring and shows as `[closed]` in the menu until you reopen it (via a pin jump, cycling, or selecting it in the menu).

In the menu:
- `x`: pin/unpin selected entry
- `X`: pin from the top of the MRU list into free slots (1..9)
- `c`: close selected buffer (only if saved)

## Configuration

`setup` accepts these keys (all optional):

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `max` | integer | `50` | Maximum number of entries to keep. |
| `commit_on_touch` | boolean | `true` | If `false`, buffers are committed immediately instead of waiting for a touch event. |
| `touch_events` | table | `{ "CursorMoved", "InsertEnter", "TextChanged" }` | Autocommands that count as a "touch". |
| `ignore` | table | (built-in) | Extend the built-in ignore lists (`buftype`, `filetype`, `name_patterns`). Uses `vim.tbl_deep_extend`. |
| `keymaps` | table/`false`/`true` | (built-in) | Provide your own default maps (`{ menu, prev, next, pins = { set_prefix, jump_prefix } }`). Set to `false` to skip installing keymaps; set to `true` to reset to defaults. |
| `cycle_keys` | table | (derived) | Extra keys that should be ignored while in preview mode. By default the plugin infers this from the configured `keymaps`. When `keymaps = false`, set this manually. |
| `ui` | table | (built-in) | MRU menu UI options (see below). |
| `persist_pins` | boolean | `false` | Persist pinned slots to disk and reload on startup. |
| `persist_file` | string | `stdpath("data") .. "/mru-buffers-pins.json"` | Override the persistence file path. |

### UI options (`ui`)

Classic UI is the default. Enable the newer styling via `ui.fancy = true`.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `ui.width` | integer | `140` | Menu width (columns, clamped to screen). |
| `ui.height` | integer | `12` | Menu height (rows, clamped to screen). |
| `ui.border` | string | `"rounded"` | Floating window border style. |
| `ui.title` | string | `"Recently used Buff"` | Window title. |
| `ui.fancy` | boolean | `false` | Enable enhanced styling (highlights, icons, richer footer). |
| `ui.show_icons` | boolean | `true` | Show devicons when `ui.fancy = true` (requires `nvim-web-devicons`). |
| `ui.show_count_in_title` | boolean | `true` | Append item count to title when `ui.fancy = true`. |
| `ui.show_footer` | boolean | `true` | Show the help footer when `ui.fancy = true`. |
| `ui.modified_icon` | string | `" ●"` | Suffix for modified buffers when `ui.fancy = true`. |

Example:

```lua
require("mru-buffers").setup({
  max = 75,
  keymaps = {
    menu = "<leader>bm",
    prev = "[b",
    next = "]b",
    pins = {
      set_prefix = "<leader>bp", -- <leader>bp1..9 to pin
      jump_prefix = "<leader>b", -- <leader>b1..9 to jump
    },
  },
  cycle_keys = { prev = "[b", next = "]b" },
  ignore = {
    filetype = { "startify" },
  },
  ui = {
    fancy = true,
    border = "rounded",
    title = "MRU",
    show_icons = true, -- requires nvim-web-devicons
    show_count_in_title = true,
    show_footer = true,
  },
  persist_pins = true,
})
```

## Example (Fancy)

```lua
{
  "abhishekkundu25/mru-buffers",
  event = "VeryLazy",
  dependencies = { "nvim-tree/nvim-web-devicons" }, -- optional (icons)
  config = function()
    require("mru-buffers").setup({
      max = 80,
      persist_pins = true,
      keymaps = {
        menu = "<leader>m",
        prev = "[b",
        next = "]b",
        pins = {
          set_prefix = "<leader>p", -- <leader>p1..9
          jump_prefix = "<leader>", -- <leader>1..9
        },
      },
      ui = {
        fancy = true,
        width = 120,
        height = 14,
        border = "rounded",
        title = "MRU Buffers",
        show_icons = true,
        show_count_in_title = true,
        show_footer = true,
        modified_icon = " ●",
      },
      ignore = {
        filetype = { "TelescopePrompt", "TelescopeResults", "lazy", "mason" },
      },
    })
  end,
}
```

## Development

- `lua/mru-buffers/init.lua` exposes `require("mru-buffers")` and assembles modules.
- `lua/mru-buffers/core.lua` MRU ring + cycling logic.
- `lua/mru-buffers/pins.lua` pins + persistence.
- `lua/mru-buffers/ui.lua` floating menu UI.
- `lua/mru-buffers/setup.lua` `setup()`, autocmds, user commands, keymaps.
- `lua/mru/buffers.lua` is a compatibility wrapper for `require("mru.buffers")`.

Contributions and bug reports are welcome once the repository is published.

## License

MIT – see [LICENSE](LICENSE).
