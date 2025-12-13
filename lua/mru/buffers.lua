local DEFAULT_KEYMAPS = {
	menu = "<leader>he",
	prev = "H",
	next = "L",
	pins = {
		set_prefix = "<leader>p", -- <leader>p1..9 to pin current buffer
		jump_prefix = "<leader>", -- <leader>1..9 to jump to pinned buffer
	},
}

local M = {}

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
M._pins = {} -- slot -> { path = string, bufnr = number|nil }

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

local function add_cycle_key(key)
	if not key or key == "" then
		return
	end
	local normalized = vim.fn.keytrans(key)
	if normalized and normalized ~= "" then
		M.cycle_keys[normalized] = true
	end
end

local function update_cycle_keys(cycle_opts)
	M.cycle_keys = {}
	if type(cycle_opts) == "table" then
		if cycle_opts.prev or cycle_opts.next then
			add_cycle_key(cycle_opts.prev)
			add_cycle_key(cycle_opts.next)
			return
		end
		for _, key in ipairs(cycle_opts) do
			add_cycle_key(key)
		end
		for key, enabled in pairs(cycle_opts) do
			if type(key) == "string" and enabled == true then
				add_cycle_key(key)
			end
		end
		return
	end

	if type(M.keymaps) == "table" then
		add_cycle_key(M.keymaps.prev)
		add_cycle_key(M.keymaps.next)
	end
end

local function apply_keymaps()
	if M.keymaps == false then
		return
	end

	local maps = M.keymaps or {}
	local function map(lhs, rhs, desc)
		if not lhs or lhs == "" then
			return
		end
		vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
	end

	map(maps.menu, function()
		M.open_menu()
	end, "MRU menu")

	map(maps.prev, function()
		M.prev()
	end, "MRU cycle prev")

	map(maps.next, function()
		M.next()
	end, "MRU cycle next")

	local pins = maps.pins
	if pins ~= false then
		local set_prefix = type(pins) == "table" and pins.set_prefix or DEFAULT_KEYMAPS.pins.set_prefix
		local jump_prefix = type(pins) == "table" and pins.jump_prefix or DEFAULT_KEYMAPS.pins.jump_prefix

		for i = 1, M.pin_slots do
			if set_prefix and set_prefix ~= "" then
				map(set_prefix .. tostring(i), function()
					M.pin(i)
				end, ("MRU pin %d"):format(i))
			end
			if jump_prefix and jump_prefix ~= "" then
				map(jump_prefix .. tostring(i), function()
					M.jump(i)
				end, ("MRU jump pin %d"):format(i))
			end
		end
	end
end

update_cycle_keys()

-- ========= helpers =========
local function buf_valid(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function list_contains(t, v)
	for _, x in ipairs(t) do
		if x == v then
			return true
		end
	end
	return false
end

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function json_encode(v)
	if vim.json and vim.json.encode then
		return vim.json.encode(v)
	end
	return vim.fn.json_encode(v)
end

local function json_decode(s)
	if vim.json and vim.json.decode then
		return vim.json.decode(s)
	end
	return vim.fn.json_decode(s)
end

local function normalize_slot(slot)
	slot = tonumber(slot)
	if not slot then
		return nil
	end
	if slot < 1 or slot > M.pin_slots then
		return nil
	end
	return slot
end

local function pin_slot_for_path(path)
	if not path or path == "" then
		return nil
	end
	for slot, pin in pairs(M._pins) do
		if pin and pin.path == path then
			return slot
		end
	end
	return nil
end

local function name_matches(name)
	if not name or name == "" then
		return true
	end
	for _, pat in ipairs(M.ignore.name_patterns) do
		if name:match(pat) then
			return true
		end
	end
	return false
end

local function should_ignore(buf)
	if not buf_valid(buf) then
		return true
	end
	if vim.bo[buf].buflisted ~= true then
		return true
	end

	local bt = vim.bo[buf].buftype or ""
	if bt ~= "" and list_contains(M.ignore.buftype, bt) then
		return true
	end

	local ft = vim.bo[buf].filetype or ""
	if ft ~= "" and list_contains(M.ignore.filetype, ft) then
		return true
	end

	local name = vim.api.nvim_buf_get_name(buf)
	if name_matches(name) then
		return true
	end

	return false
end

local function buf_real(buf)
	if should_ignore(buf) then
		return false
	end
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= nil and name ~= ""
end

local function is_telescope_ui(buf)
	if not buf_valid(buf) then
		return false
	end
	local ft = vim.bo[buf].filetype or ""
	return ft == "TelescopePrompt" or ft == "TelescopeResults"
end

local function normalize_file_buffer(buf)
	if not (buf and buf_valid(buf)) then
		return
	end
	if vim.bo[buf].buftype ~= "" then
		return
	end
	if vim.bo[buf].bufhidden == "wipe" then
		vim.bo[buf].bufhidden = ""
	end
	if vim.bo[buf].buflisted ~= true then
		vim.bo[buf].buflisted = true
	end
end

local function path_for_buf(buf)
	if not buf_real(buf) then
		return nil
	end
	return normalize_path(vim.api.nvim_buf_get_name(buf))
end

local function is_pinned_path(path)
	return pin_slot_for_path(path) ~= nil
end

local function enforce_max()
	while #M._list > M.max do
		local removed = nil
		for i = #M._list, 1, -1 do
			if not is_pinned_path(M._list[i]) then
				removed = i
				break
			end
		end
		if not removed then
			break
		end
		table.remove(M._list, removed)
		if removed < M._pos then
			M._pos = math.max(1, M._pos - 1)
		elseif removed == M._pos then
			M._pos = math.min(M._pos, #M._list)
		end
	end

	if #M._list == 0 then
		M._pos = 1
	else
		M._pos = math.min(M._pos, #M._list)
	end
end

local function prune()
	local new = {}
	local new_pos = 1
	local seen = {}

	for i, entry in ipairs(M._list) do
		local path = entry
		if type(entry) == "number" then
			path = path_for_buf(entry)
		end
		if type(path) == "string" and path ~= "" and not seen[path] then
			local b = vim.fn.bufnr(path, false)
			local keep = false
			if b and b > 0 and buf_valid(b) and buf_real(b) then
				keep = true
			elseif is_pinned_path(path) then
				keep = true
			end

			if keep then
				seen[path] = true
				table.insert(new, path)
				if i == M._pos then
					new_pos = #new
				end
			end
		end
	end

	M._list = new
	if #M._list == 0 then
		M._pos = 1
	else
		M._pos = math.min(new_pos, #M._list)
	end
	enforce_max()
end

local function find_index(path)
	for i, p in ipairs(M._list) do
		if p == path then
			return i
		end
	end
	return nil
end

local function clear_preview()
	M._preview_active = false
	M._preview_buf = nil
	M._preview_key_counter_at_enter = 0
end

local close_menu

-- ========= public: pins =========
local function first_free_pin_slot()
	for i = 1, M.pin_slots do
		if not M._pins[i] then
			return i
		end
	end
	return nil
end

local function pin_path(path, slot, bufnr)
	path = normalize_path(path)
	slot = normalize_slot(slot)
	if not path or not slot then
		return false
	end

	-- enforce one slot per path (if re-pinning, clear any other slot)
	for s, p in pairs(M._pins) do
		if s ~= slot and p and p.path == path then
			M._pins[s] = nil
		end
	end

	M._pins[slot] = { path = path, bufnr = bufnr }
	if not find_index(path) then
		table.insert(M._list, path)
		enforce_max()
	end
	return true
end

local function persist_path()
	if type(M.persist_file) == "string" and M.persist_file ~= "" then
		return M.persist_file
	end
	return vim.fn.stdpath("data") .. "/mru-buffers-pins.json"
end

local function save_pins()
	if not M.persist_pins then
		return
	end

	local out = { version = 1, pins = {} }
	for slot = 1, M.pin_slots do
		local pin = M._pins[slot]
		if pin and pin.path and pin.path ~= "" then
			out.pins[tostring(slot)] = { path = pin.path }
		end
	end

	local ok, encoded = pcall(json_encode, out)
	if not ok or type(encoded) ~= "string" then
		return
	end

	local file = persist_path()
	pcall(vim.fn.writefile, { encoded }, file)
end

local function load_pins()
	if not M.persist_pins then
		return
	end

	local file = persist_path()
	if vim.fn.filereadable(file) ~= 1 then
		return
	end

	local lines = vim.fn.readfile(file)
	local decoded_ok, decoded = pcall(json_decode, table.concat(lines, "\n"))
	if not decoded_ok or type(decoded) ~= "table" then
		return
	end

	local pins = decoded.pins
	if type(pins) ~= "table" then
		return
	end

	for slot_str, pin in pairs(pins) do
		local slot = normalize_slot(slot_str)
		local path = type(pin) == "table" and pin.path or nil
		path = normalize_path(path)
		if slot and path then
			pin_path(path, slot, nil)
		end
	end
end

function M.pin(slot)
	slot = normalize_slot(slot)
	if not slot then
		vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
		return
	end

	local cur = vim.api.nvim_get_current_buf()
	if not buf_real(cur) then
		vim.notify("MRU: cannot pin this buffer", vim.log.levels.WARN)
		return
	end

	local path = normalize_path(vim.api.nvim_buf_get_name(cur))
	if not path then
		vim.notify("MRU: cannot pin unnamed buffer", vim.log.levels.WARN)
		return
	end

	pin_path(path, slot, cur)
	save_pins()
	vim.notify(("MRU: pinned %s to %d"):format(vim.fn.fnamemodify(path, ":~:."), slot), vim.log.levels.INFO)
end

function M.unpin(slot)
	slot = normalize_slot(slot)
	if not slot then
		vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
		return
	end
	M._pins[slot] = nil
	prune()
	save_pins()
end

function M.jump(slot)
	slot = normalize_slot(slot)
	if not slot then
		vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
		return
	end

	local pin = M._pins[slot]
	if not pin or not pin.path then
		vim.notify(("MRU: no pin in slot %d"):format(slot), vim.log.levels.INFO)
		return
	end

	local path = normalize_path(pin.path)
	if not path then
		vim.notify(("MRU: invalid pin in slot %d"):format(slot), vim.log.levels.WARN)
		return
	end

	local origin_win = nil
	if close_menu and M._menu and M._menu.win and vim.api.nvim_win_is_valid(M._menu.win) then
		origin_win = M._menu.origin_win
		close_menu()
		if origin_win and vim.api.nvim_win_is_valid(origin_win) then
			pcall(vim.api.nvim_set_current_win, origin_win)
		end
	end

	local function go()
		-- If we still have a valid bufnr, use it.
		if pin.bufnr and buf_valid(pin.bufnr) then
			vim.cmd(("buffer %d"):format(pin.bufnr))
			normalize_file_buffer(pin.bufnr)
			return true
		end

		-- Try to find an existing buffer for this path.
		local existing = vim.fn.bufnr(path, false)
		if existing and existing > 0 and buf_valid(existing) then
			pin.bufnr = existing
			vim.cmd(("buffer %d"):format(existing))
			normalize_file_buffer(existing)
			return true
		end

		-- Reopen from disk as a normal listed buffer.
		pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(path)))
		local b = vim.fn.bufnr(path, false)
		if b and b > 0 and buf_valid(b) then
			pin.bufnr = b
			vim.cmd(("buffer %d"):format(b))
			normalize_file_buffer(b)
			return true
		end

		local ok = pcall(vim.cmd, ("edit %s"):format(vim.fn.fnameescape(path)))
		if ok then
			normalize_file_buffer(vim.api.nvim_get_current_buf())
		end
		return ok
	end

	local ok = pcall(go)
	if not ok then
		vim.notify(("MRU: failed to open pin %d"):format(slot), vim.log.levels.WARN)
	end
end

-- Promote buf to front (MRU), unique list, capped
function M._record(buf)
	if M._nav_lock then
		return
	end
	local path = path_for_buf(buf)
	if not path then
		return
	end

	prune()

	local idx = find_index(path)
	if idx then
		table.remove(M._list, idx)
	end
	table.insert(M._list, 1, path)
	M._pos = 1

	enforce_max()
end

local function goto_path(path, target_pos, as_preview)
	if type(path) ~= "string" or path == "" then
		return false
	end

	M._nav_lock = true
	if target_pos then
		M._pos = target_pos
	end
	local ok
	local b = vim.fn.bufnr(path, false)
	if not (b and b > 0 and buf_valid(b)) then
		pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(path)))
		b = vim.fn.bufnr(path, false)
	end
	if b and b > 0 and buf_valid(b) then
		ok = pcall(vim.cmd, ("buffer %d"):format(b))
		normalize_file_buffer(b)
	else
		ok = pcall(vim.cmd, ("edit %s"):format(vim.fn.fnameescape(path)))
		if ok then
			normalize_file_buffer(vim.api.nvim_get_current_buf())
		end
	end
	M._nav_lock = false

	if ok and as_preview then
		-- start preview session; commit only after real user input (movement/edit)
		M._preview_active = true
		M._preview_buf = vim.api.nvim_get_current_buf()
		M._preview_key_counter_at_enter = M._key_counter
	end

	return ok
end

-- ========= public: cycle =========
function M.prev()
	prune()
	if #M._list <= 1 then
		vim.notify("MRU: nothing to cycle", vim.log.levels.INFO)
		return
	end

	local cur = vim.api.nvim_get_current_buf()
	local cur_path = path_for_buf(cur)
	local idx = cur_path and find_index(cur_path) or nil
	if idx and idx ~= M._pos then
		M._pos = idx
	end

	local tries = 0
	repeat
		M._pos = M._pos + 1
		if M._pos > #M._list then
			M._pos = 1
		end
		local path = M._list[M._pos]
		if path and path ~= cur_path then
			if goto_path(path, M._pos, M.commit_on_touch) then
				return
			end
		end
		tries = tries + 1
	until tries >= #M._list

	vim.notify("MRU: no valid target", vim.log.levels.INFO)
end

function M.next()
	prune()
	if #M._list <= 1 then
		vim.notify("MRU: nothing to cycle", vim.log.levels.INFO)
		return
	end

	local cur = vim.api.nvim_get_current_buf()
	local cur_path = path_for_buf(cur)
	local idx = cur_path and find_index(cur_path) or nil
	if idx and idx ~= M._pos then
		M._pos = idx
	end

	local tries = 0
	repeat
		M._pos = M._pos - 1
		if M._pos < 1 then
			M._pos = #M._list
		end
		local path = M._list[M._pos]
		if path and path ~= cur_path then
			if goto_path(path, M._pos, M.commit_on_touch) then
				return
			end
		end
		tries = tries + 1
	until tries >= #M._list

	vim.notify("MRU: no valid target", vim.log.levels.INFO)
end

-- ========= setup =========
function M.setup(opts)
	opts = opts or {}

	if opts.keymaps ~= nil then
		if opts.keymaps == false then
			M.keymaps = false
		elseif opts.keymaps == true then
			M.keymaps = vim.deepcopy(DEFAULT_KEYMAPS)
		elseif type(opts.keymaps) == "table" then
			local base = type(M.keymaps) == "table" and M.keymaps or vim.deepcopy(DEFAULT_KEYMAPS)
			M.keymaps = vim.tbl_deep_extend("force", {}, base, opts.keymaps)
		end
	end

	M.max = opts.max or M.max
	M.commit_on_touch = (opts.commit_on_touch ~= false)
	M.touch_events = opts.touch_events or M.touch_events
	if opts.ignore then
		M.ignore = vim.tbl_deep_extend("force", M.ignore, opts.ignore)
	end
	if opts.ui then
		M.ui = vim.tbl_deep_extend("force", M.ui or {}, opts.ui)
	end
	update_cycle_keys(opts.cycle_keys)

	if opts.persist_pins ~= nil then
		M.persist_pins = opts.persist_pins == true
	end
	if opts.persist_file ~= nil then
		M.persist_file = opts.persist_file
	end

	if not M._augroup then
		M._augroup = vim.api.nvim_create_augroup("MRUBuffers", { clear = true })
	else
		vim.api.nvim_clear_autocmds({ group = M._augroup })
	end

	-- Keypress tracker (only used to gate "touch" commits)
	if not M._key_ns then
		M._key_ns = vim.api.nvim_create_namespace("mru_ring_keytrack")
		vim.on_key(function(ch)
			-- We only care while previewing, and only in the preview buffer
			if not M._preview_active then
				return
			end
			if vim.api.nvim_get_current_buf() ~= M._preview_buf then
				return
			end
			M._key_counter = M._key_counter + 1
			M._last_key = vim.fn.keytrans(ch)
		end, M._key_ns)
	end

	-- Record normal BufEnter, but do not let Telescope cancel reorder MRU
	vim.api.nvim_create_autocmd("BufEnter", {
		group = M._augroup,
		callback = function(args)
			local buf = args.buf

			-- entering telescope UI
			if is_telescope_ui(buf) then
				if not M._ui_active then
					M._ui_active = true
					M._ui_origin_buf = vim.fn.bufnr("#")
					M._ui_origin_pos = M._pos
				end
				return
			end

			-- leaving telescope UI
			if M._ui_active then
				local origin = M._ui_origin_buf
				local origin_pos = M._ui_origin_pos
				M._ui_active, M._ui_origin_buf, M._ui_origin_pos = false, nil, nil

				-- Cancel -> ended up back at origin: do nothing
				if origin and buf == origin then
					if origin_pos then
						M._pos = origin_pos
					end
					return
				end
				-- selection -> record normally below
			end

			-- if we entered due to our MRU cycling, do not record here
			if M._nav_lock then
				return
			end

			-- refresh pinned bufnr when entering a pinned file
			local path = path_for_buf(buf)
			local slot = path and pin_slot_for_path(path) or nil
			if slot and M._pins[slot] then
				M._pins[slot].bufnr = buf
			end

			-- normal navigation: commit immediately
			clear_preview()
			M._record(buf)
		end,
	})

	-- Commit preview only after real user input (not internal CursorMoved)
	vim.api.nvim_create_autocmd(M.touch_events, {
		group = M._augroup,
		callback = function()
			if not M.commit_on_touch then
				return
			end
			if not M._preview_active then
				return
			end

			local cur = vim.api.nvim_get_current_buf()
			if cur ~= M._preview_buf then
				return
			end
			if not buf_real(cur) then
				return
			end

			-- If no keypress happened since we entered preview, ignore (internal events)
			if M._key_counter == M._preview_key_counter_at_enter then
				return
			end

			-- If the last keypress is one of our cycle keys, ignore (just cycling)
			if M.cycle_keys[M._last_key] then
				return
			end

			-- Otherwise, user actually did something => commit
			clear_preview()
			M._record(cur)
		end,
	})

	-- If we leave preview buffer without committing, discard preview state
	vim.api.nvim_create_autocmd("BufLeave", {
		group = M._augroup,
		callback = function(args)
			if not M.commit_on_touch then
				return
			end
			if not M._preview_active then
				return
			end
			if args.buf ~= M._preview_buf then
				return
			end
			clear_preview()
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = M._augroup,
		callback = function(args)
			-- keep pins even if the underlying buffer is wiped
			if args and args.buf then
				for _, pin in pairs(M._pins) do
					if pin and pin.bufnr == args.buf then
						pin.bufnr = nil
					end
				end
			end
			prune()
			if M._preview_active and not buf_valid(M._preview_buf) then
				clear_preview()
			end
		end,
	})

	if M.persist_pins then
		load_pins()
		vim.api.nvim_create_autocmd("VimLeavePre", {
			group = M._augroup,
			callback = function()
				save_pins()
			end,
		})
	end

	vim.api.nvim_create_user_command("MRUMenu", function()
		M.open_menu()
	end, { force = true })

	vim.api.nvim_create_user_command("MRUPin", function(cmd)
		M.pin(cmd.args)
	end, {
		nargs = 1,
		force = true,
		complete = function()
			local out = {}
			for i = 1, M.pin_slots do
				out[#out + 1] = tostring(i)
			end
			return out
		end,
	})

	vim.api.nvim_create_user_command("MRUUnpin", function(cmd)
		M.unpin(cmd.args)
	end, {
		nargs = 1,
		force = true,
		complete = function()
			local out = {}
			for i = 1, M.pin_slots do
				out[#out + 1] = tostring(i)
			end
			return out
		end,
	})

	vim.api.nvim_create_user_command("MRURing", function()
		prune()
		local out = {}
		for i, path in ipairs(M._list) do
			if type(path) == "string" and path ~= "" then
				local b = vim.fn.bufnr(path, false)
				local pin_slot = pin_slot_for_path(path)
				local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
				local here = (i == M._pos) and "  <==" or ""
				if b and b > 0 and buf_valid(b) then
					table.insert(out, string.format("%3d  %s  #%d  %s%s", i, pin_tag, b, path, here))
				else
					table.insert(out, string.format("%3d  %s  (closed)  %s%s", i, pin_tag, path, here))
				end
			end
		end
		vim.notify(#out > 0 and table.concat(out, "\n") or "MRU ring: empty")
	end, { force = true })

	apply_keymaps()
	return M
end

-- =========================
-- MRU Menu (Harpoon-like UI)
-- =========================
M.ui = M.ui
	or {
		width = 140, -- columns (clamped to screen)
		height = 12, -- rows (clamped to screen)
		border = "rounded",
		title = "Recently used Buff",
		-- UI styling (opt-in; classic behavior by default)
		fancy = false,
		show_icons = true, -- requires nvim-web-devicons
		show_count_in_title = true,
		show_footer = true,
		modified_icon = " ●",
	}

M._menu = { buf = nil, win = nil }
M._ui_ns = M._ui_ns or nil
M._ui_hl_ready = M._ui_hl_ready or false

local function setup_ui_highlights()
	if M._ui_hl_ready then
		return
	end

	M._ui_ns = M._ui_ns or vim.api.nvim_create_namespace("MRUBuffersUI")

	local function link(group, target)
		vim.api.nvim_set_hl(0, group, { link = target, default = true })
	end

	link("MRUBuffersNormal", "NormalFloat")
	link("MRUBuffersBorder", "FloatBorder")
	link("MRUBuffersTitle", "FloatTitle")
	link("MRUBuffersCursorLine", "CursorLine")
	link("MRUBuffersIndex", "LineNr")
	link("MRUBuffersPin", "DiagnosticHint")
	link("MRUBuffersPinnedName", "Directory")
	link("MRUBuffersName", "NormalFloat")
	link("MRUBuffersModified", "DiagnosticWarn")
	link("MRUBuffersClosed", "Comment")
	link("MRUBuffersHint", "Comment")

	M._ui_hl_ready = true
end

local function devicon_for(path)
	if not (M.ui and M.ui.show_icons) then
		return nil, nil
	end
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if not ok or not devicons then
		return nil, nil
	end
	local name = vim.fn.fnamemodify(path, ":t")
	local ext = vim.fn.fnamemodify(path, ":e")
	local icon, hl = devicons.get_icon(name, ext, { default = true })
	return icon, hl
end

local function mru_items()
	prune()
	local items = {}
	for _, path in ipairs(M._list) do
		if type(path) == "string" and path ~= "" then
			local b = vim.fn.bufnr(path, false)
			if b and b > 0 and buf_valid(b) and buf_real(b) then
				table.insert(items, { path = path, bufnr = b })
			elseif is_pinned_path(path) then
				table.insert(items, { path = path, bufnr = nil })
			end
		end
	end
	return items
end

local function render_menu(buf, items)
	local fancy = M.ui and M.ui.fancy == true

	if not fancy then
		local lines = {}
		for i, it in ipairs(items) do
			local pin_slot = pin_slot_for_path(it.path)
			local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
			local disp = vim.fn.fnamemodify(it.path, ":~:.")
			if it.bufnr and vim.bo[it.bufnr].modified then
				disp = disp .. "  [+]"
			elseif not it.bufnr then
				disp = disp .. "  [closed]"
			end
			lines[i] = string.format("%2d  %s  %s", i, pin_tag, disp)
		end

		lines[#lines + 1] = ""
		lines[#lines + 1] = "x: pin/unpin   q/<Esc>: close"

		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		return
	end

	setup_ui_highlights()

	local lines = {}
	local meta = {}
	for i, it in ipairs(items) do
		local pin_slot = pin_slot_for_path(it.path)
		local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
		local icon, icon_hl = devicon_for(it.path)
		local icon_part = icon and (icon .. " ") or ""

		local disp = vim.fn.fnamemodify(it.path, ":~:.")
		local suffix = ""
		if it.bufnr and vim.bo[it.bufnr].modified then
			suffix = M.ui.modified_icon or " ●"
		elseif not it.bufnr then
			suffix = "  [closed]"
		end

		local line = string.format("%2d  %s  %s%s%s", i, pin_tag, icon_part, disp, suffix)
		lines[i] = line

		meta[i] = {
			pin_slot = pin_slot,
			icon_hl = icon_hl,
			icon_len = icon and #icon or 0,
			name_col = 9 + #icon_part,
			suffix = suffix,
		}
	end

	if M.ui.show_footer ~= false then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "x: pin/unpin  •  <CR>: open  •  r: refresh  •  H/L: cycle  •  q/<Esc>: close"
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, M._ui_ns, 0, -1)
	for i = 1, #items do
		local m = meta[i]
		local line = lines[i]
		if not (m and line) then
			break
		end

		vim.api.nvim_buf_add_highlight(buf, M._ui_ns, "MRUBuffersIndex", i - 1, 0, 2)

		local pin_hl = m.pin_slot and "MRUBuffersPin" or "MRUBuffersClosed"
		vim.api.nvim_buf_add_highlight(buf, M._ui_ns, pin_hl, i - 1, 4, 7)

		if m.icon_len > 0 and m.icon_hl then
			local icon_col = 9
			vim.api.nvim_buf_add_highlight(buf, M._ui_ns, m.icon_hl, i - 1, icon_col, icon_col + m.icon_len)
		end

		local name_hl = m.pin_slot and "MRUBuffersPinnedName" or "MRUBuffersName"
		if m.suffix == "  [closed]" then
			name_hl = "MRUBuffersClosed"
		end
		vim.api.nvim_buf_add_highlight(buf, M._ui_ns, name_hl, i - 1, m.name_col, -1)

		if m.suffix == (M.ui.modified_icon or " ●") then
			local start = #line - #m.suffix
			vim.api.nvim_buf_add_highlight(buf, M._ui_ns, "MRUBuffersModified", i - 1, start, -1)
		elseif m.suffix == "  [closed]" then
			local start = #line - #m.suffix
			vim.api.nvim_buf_add_highlight(buf, M._ui_ns, "MRUBuffersClosed", i - 1, start, -1)
		end
	end

	if M.ui.show_footer ~= false then
		local hint_row = #items + 2
		if lines[hint_row] then
			vim.api.nvim_buf_add_highlight(buf, M._ui_ns, "MRUBuffersHint", hint_row - 1, 0, -1)
		end
	end
end

close_menu = function()
	if M._menu.win and vim.api.nvim_win_is_valid(M._menu.win) then
		vim.api.nvim_win_close(M._menu.win, true)
	end
	if M._menu.buf and vim.api.nvim_buf_is_valid(M._menu.buf) then
		vim.api.nvim_buf_delete(M._menu.buf, { force = true })
	end
	M._menu.win, M._menu.buf, M._menu.origin_win = nil, nil, nil
end

function M.open_menu()
	-- toggle behavior
	if M._menu.win and vim.api.nvim_win_is_valid(M._menu.win) then
		close_menu()
		return
	end

	local origin_buf = vim.api.nvim_get_current_buf()
	local origin_path = path_for_buf(origin_buf)
	local origin_win = vim.api.nvim_get_current_win()

	local items = mru_items()
	if #items == 0 then
		vim.notify("MRU ring: empty")
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "mru-ring"
	vim.bo[buf].modifiable = false

	render_menu(buf, items)

	local cols = vim.o.columns
	local lines = vim.o.lines

	local w = math.min(M.ui.width, math.max(30, cols - 4))
	local h = math.min(M.ui.height, math.max(6, lines - 6))

	local title = M.ui.title
	if M.ui.fancy == true and M.ui.show_count_in_title ~= false then
		title = string.format(" %s (%d) ", title or "MRU Buffers", #items)
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = w,
		height = h,
		col = math.floor((cols - w) / 2),
		row = math.floor((lines - h) / 2),
		style = "minimal",
		border = M.ui.border,
		title = title,
		title_pos = "center",
	})

	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	if M.ui.fancy == true then
		setup_ui_highlights()
		vim.wo[win].winhighlight =
			"Normal:MRUBuffersNormal,FloatBorder:MRUBuffersBorder,FloatTitle:MRUBuffersTitle,CursorLine:MRUBuffersCursorLine"
	end

	M._menu.buf, M._menu.win = buf, win
	M._menu.origin_win = origin_win

	-- place cursor on current buffer if present, else first line
	local target_line = 1
	if origin_path then
		for i, it in ipairs(items) do
			if it.path == origin_path then
				target_line = i
				break
			end
		end
	end
	vim.api.nvim_win_set_cursor(win, { target_line, 0 })

	local function with_items(fn)
		return function()
			if not (M._menu.win and vim.api.nvim_win_is_valid(M._menu.win)) then
				return
			end
			local fresh = mru_items()
			fn(fresh)
		end
	end

	-- Jump to selection
	vim.keymap.set(
		"n",
		"<CR>",
		with_items(function(fresh)
			local row = vim.api.nvim_win_get_cursor(0)[1]
			local it = fresh[row]
			if not it then
				return
			end
			close_menu()
			if M._menu.origin_win and vim.api.nvim_win_is_valid(M._menu.origin_win) then
				pcall(vim.api.nvim_set_current_win, M._menu.origin_win)
			end
			if it.bufnr and buf_valid(it.bufnr) then
				vim.cmd(("buffer %d"):format(it.bufnr))
				normalize_file_buffer(it.bufnr)
			else
				pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(it.path)))
				local b = vim.fn.bufnr(it.path, false)
				if b and b > 0 and buf_valid(b) then
					vim.cmd(("buffer %d"):format(b))
					normalize_file_buffer(b)
				else
					vim.cmd(("edit %s"):format(vim.fn.fnameescape(it.path)))
					normalize_file_buffer(vim.api.nvim_get_current_buf())
				end
			end
		end),
		{ buffer = buf, silent = true }
	)

	-- Close
	vim.keymap.set("n", "q", close_menu, { buffer = buf, silent = true })
	vim.keymap.set("n", "<Esc>", close_menu, { buffer = buf, silent = true })

	-- Unpin (removes the pin, does not force-close buffer)
	vim.keymap.set(
		"n",
		"x",
		with_items(function(fresh)
			local row = vim.api.nvim_win_get_cursor(0)[1]
			local it = fresh[row]
			if not it then
				return
			end
			local slot = pin_slot_for_path(it.path)
			if slot then
				M.unpin(slot)
			else
				local free = first_free_pin_slot()
				if not free then
					vim.notify(("MRU: no free pin slots (1-%d)"):format(M.pin_slots), vim.log.levels.WARN)
					return
				end
				pin_path(it.path, free, it.bufnr)
				vim.notify(("MRU: pinned to %d"):format(free), vim.log.levels.INFO)
			end
			local refreshed = mru_items()
			render_menu(buf, refreshed)
			local new_row = math.min(row, #refreshed)
			vim.api.nvim_win_set_cursor(0, { math.max(1, new_row), 0 })
		end),
		{ buffer = buf, silent = true, desc = "Unpin selected" }
	)

	-- Refresh (if MRU changed)
	vim.keymap.set("n", "r", function()
		local fresh = mru_items()
		render_menu(buf, fresh)
	end, { buffer = buf, silent = true, desc = "Refresh MRU menu" })

	-- Optional: cycle MRU while menu is open (keeps your cycle behavior)
	vim.keymap.set("n", "H", function()
		close_menu()
		M.prev()
	end, { buffer = buf, silent = true })

	vim.keymap.set("n", "L", function()
		close_menu()
		M.next()
	end, { buffer = buf, silent = true })
end

return M
