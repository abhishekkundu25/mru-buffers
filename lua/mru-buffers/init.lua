local DEFAULT_KEYMAPS = {
	menu = "<leader>he",
	prev = "[b",
	next = "]b",
	pins = {
		set_prefix = "<leader>p", -- <leader>p1..9 to pin current buffer
		jump_prefix = "<leader>", -- <leader>1..9 to jump to pinned buffer
	},
}

local M = {}

M._default_keymaps = DEFAULT_KEYMAPS

-- ========= config/state =========
M.max = 50

-- Preview mode: buffers entered via cycle keys are NOT committed until user "uses" them.
M.commit_on_touch = true

-- Touch events (CursorMoved is fine once we gate it by real keypress)
M.touch_events = { "CursorMoved", "InsertEnter", "TextChanged" }

M._list = {} -- MRU unique ring of file paths, most-recent first
M._pos = 1 -- current position in ring (1 = most recent)
M._nav_lock = false

M.keymaps = vim.deepcopy(DEFAULT_KEYMAPS)

-- Preview/commit state
M._preview_active = false
M._preview_buf = nil
M._preview_key_counter_at_enter = 0

-- Key tracking (to distinguish real movement vs internal cursor events)
M._key_counter = 0
M._last_key = ""
M._key_ns = nil

-- Telescope suppression (cancel should not reorder MRU)
M._ui_active = false
M._ui_origin_buf = nil
M._ui_origin_pos = nil

-- Pin slots (1..pin_slots)
M.pin_slots = 9

-- Pin scope:
-- - "global": one set of pins shared everywhere (default)
-- - "project": separate pin sets per detected project root
M.pins_scope = "global"
M.project_markers = { ".git" }
M.project_root = nil -- optional function(bufnr) -> string

M._pins_global = {} -- slot -> { path = string, bufnr = number|nil }
M._pins_projects = {} -- root -> (slot -> { path = string, bufnr = number|nil })

-- Pin persistence (opt-in)
M.persist_pins = false
M.persist_file = nil

-- Keys used for cycling (so we can ignore them in "touch" logic)
M.cycle_keys = {}

M.ignore = {
	buftype = { "nofile", "prompt", "quickfix", "help", "terminal" },
	filetype = {
		"TelescopePrompt",
		"TelescopeResults",
		"lazy",
		"mason",
		"NvimTree",
		"neo-tree",
		"Oil",
		"Trouble",
		"qf",
		"help",
		"dashboard",
		"alpha",
		"notify",
		"noice",
		"toggleterm",
	},
	name_patterns = {
		"^term://",
		"^fugitive://",
		"^git://",
		"/%.git/",
		"COMMIT_EDITMSG$",
		"TelescopePrompt$",
	},
}

M._augroup = nil

local U = require("mru-buffers.util")
require("mru-buffers.core")(M, U)
require("mru-buffers.pins")(M, U)
require("mru-buffers.ui")(M, U)
require("mru-buffers.setup")(M, U)

return M
