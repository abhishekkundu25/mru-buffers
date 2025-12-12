# mru-buffers

Harpoon-inspired MRU switching for Neovim that keeps a unique ring of recently used buffers and lets you preview entries before committing to them. It ships with a minimal UI, safe defaults, and is easy to wire into any plugin manager such as `lazy.nvim`.

## Features

- Maintains a capped MRU ring that ignores special buffers (Telescope, help, terminals, etc.)
- Preview mode lets you cycle through buffers without reordering the ring until you actually edit or move
- Protects from Telescope cancelling (cancel will not reorder the MRU list)
- Pin up to 9 files; pinned entries stay in the MRU ring even after `:bd`/wipe and can be reopened
- Harpoon-like floating menu for quick jumps plus `:MRURing` for debugging
- Configurable keymaps, ignore rules, and "touch" events that trigger commits

## Requirements

- Neovim 0.9+ (needs `vim.on_key` and modern Lua APIs)

## Installation

### lazy.nvim

```lua
{
  "github-user/mru-buffers", -- replace github-user with your handle once published
  event = "VeryLazy",
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
  "github-user/mru-buffers",
  config = function()
    require("mru-buffers").setup()
  end,
})
```

## Usage

Call `require("mru-buffers").setup()` once (usually from your plugin manager). After that you get:

- Default keymaps:
  - `H`: cycle to previous entry in the MRU ring
  - `L`: cycle to next entry
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

Cycling uses preview semantics by default: buffers that you jump to via `H`/`L` do not get committed to the front of the MRU list until you actually touch them (insert, move, edit). Internal cursor events and repeated cycle presses are ignored so the ring stays stable while you browse around.

### Pins

Pins are stored by file path. If you pin a file and later delete the buffer (`:bd`, wipe, etc.), the entry remains in the MRU ring and shows as `[closed]` in the menu until you reopen it (via a pin jump, cycling, or selecting it in the menu).

In the menu, press `x` to unpin the selected entry.

## Configuration

`setup` accepts these keys (all optional):

| Option | Type | Description |
| --- | --- | --- |
| `max` | integer | Maximum number of entries to keep (default `50`). |
| `commit_on_touch` | boolean | If `false`, buffers are committed immediately instead of waiting for a touch event. |
| `touch_events` | table | Autocommands that count as a "touch" (default `{ "CursorMoved", "InsertEnter", "TextChanged" }`). |
| `ignore` | table | Extend the built-in ignore lists (`buftype`, `filetype`, `name_patterns`). Uses `vim.tbl_deep_extend`. |
| `keymaps` | table/`false`/`true` | Provide your own default maps (`{ menu = "...", prev = "...", next = "..." }`). Set to `false` to skip installing keymaps; set to `true` to reset to defaults. |
| `cycle_keys` | table | Extra keys that should be ignored while in preview mode. By default the plugin infers this from the configured `keymaps`. When `keymaps = false`, you should set this manually to match the mappings you define yourself. |

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
})
```

## Development

- `lua/mru/buffers.lua` contains the logic and UI helpers.
- `lua/mru-buffers/init.lua` exposes the module for `require("mru-buffers")`.

Contributions and bug reports are welcome once the repository is published.

## License

MIT – see [LICENSE](LICENSE).
