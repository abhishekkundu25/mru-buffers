return function(M, U)
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

	M._menu = M._menu
		or {
			frame_buf = nil,
			frame_win = nil,
			list_buf = nil,
			list_win = nil,
			footer_buf = nil,
			footer_win = nil,
			origin_win = nil,
			items = nil,
		}

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

		link("MRUBuffersNormal", "Normal")
		link("MRUBuffersBorder", "FloatBorder")
		link("MRUBuffersTitle", "FloatTitle")
		link("MRUBuffersCursorLine", "CursorLine")
		link("MRUBuffersIndex", "LineNr")
		link("MRUBuffersPin", "DiagnosticHint")
		link("MRUBuffersPinnedName", "Directory")
		link("MRUBuffersName", "Normal")
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

	local function set_menu_wrapping(win, enable)
		if not (win and vim.api.nvim_win_is_valid(win)) then
			return
		end
		if enable then
			vim.wo[win].wrap = true
			vim.wo[win].linebreak = true
			vim.wo[win].breakindent = true
			vim.wo[win].breakindentopt = "shift:2,min:10"
			vim.wo[win].showbreak = string.rep(" ", 10)
		else
			vim.wo[win].wrap = false
			vim.wo[win].linebreak = false
			vim.wo[win].breakindent = false
			vim.wo[win].breakindentopt = ""
			vim.wo[win].showbreak = ""
		end
	end

	local function should_wrap_lines(win, lines)
		if not (win and vim.api.nvim_win_is_valid(win)) then
			return false
		end
		local width = vim.api.nvim_win_get_width(win)
		if not width or width <= 0 then
			return false
		end
		for _, line in ipairs(lines) do
			if vim.fn.strdisplaywidth(line) > width then
				return true
			end
		end
		return false
	end

	local function footer_action_for_row(items, row)
		if type(items) ~= "table" or #items == 0 then
			return "x: pin/unpin"
		end
		if type(row) ~= "number" or row < 1 or row > #items then
			return "x: pin/unpin"
		end

		local it = items[row]
		if not it or not it.path then
			return "x: pin/unpin"
		end

		local slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(it.path) or nil
		if slot then
			return ("x: unpin [%d]"):format(slot)
		end

		local free = type(M._first_free_pin_slot) == "function" and M._first_free_pin_slot() or nil
		if free then
			return ("x: pin -> [%d]"):format(free)
		end
		return ("x: pin (no slots %d-%d)"):format(1, M.pin_slots)
	end

	local function footer_bulk_pin_hint()
		local free = type(M._first_free_pin_slot) == "function" and M._first_free_pin_slot() or nil
		if free then
			return "X: pin top"
		end
		return "X: no slots"
	end

	local function footer_close_hint(items, row)
		if type(items) ~= "table" or #items == 0 then
			return "c: close"
		end
		if type(row) ~= "number" or row < 1 or row > #items then
			return "c: close"
		end

		local it = items[row]
		if not it or not it.path then
			return "c: close"
		end

		local bufnr = it.bufnr
		if not (bufnr and U.buf_valid(bufnr)) then
			local b = vim.fn.bufnr(it.path, false)
			bufnr = (b and b > 0 and U.buf_valid(b)) and b or nil
		end

		if not bufnr then
			return "c: closed"
		end
		if vim.bo[bufnr].modified then
			return "c: modified"
		end
		return "c: close"
	end

	local function update_menu_footer(footer_buf, footer_win, list_win, items)
		if not (footer_buf and vim.api.nvim_buf_is_valid(footer_buf)) then
			return
		end
		if not (footer_win and vim.api.nvim_win_is_valid(footer_win)) then
			return
		end
		if not (list_win and vim.api.nvim_win_is_valid(list_win)) then
			return
		end

		local row = vim.api.nvim_win_get_cursor(list_win)[1]
		local x_action = footer_action_for_row(items, row)
		local c_action = footer_close_hint(items, row)

		local fancy = M.ui and M.ui.fancy == true
		local sep = fancy and "  •  " or "   "

		local function cycle_hint()
			if type(M.keymaps) ~= "table" then
				return "cycle: prev/next"
			end
			local prev = U.keytrans(M.keymaps.prev)
			local next = U.keytrans(M.keymaps.next)
			if prev and prev ~= "" and next and next ~= "" then
				return string.format("%s/%s: cycle", prev, next)
			end
			if prev and prev ~= "" then
				return string.format("%s: prev", prev)
			end
			if next and next ~= "" then
				return string.format("%s: next", next)
			end
			return "cycle: prev/next"
		end

		local parts = {
			x_action,
			footer_bulk_pin_hint(),
			c_action,
			"<CR>: open",
			"r: refresh",
			cycle_hint(),
			"q/<Esc>: close",
		}
		if not fancy then
			parts = { x_action, footer_bulk_pin_hint(), c_action, "q/<Esc>: close" }
		end

		local footer = table.concat(parts, sep)

		vim.bo[footer_buf].modifiable = true
		vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer })
		vim.bo[footer_buf].modifiable = false

		if fancy then
			setup_ui_highlights()
			vim.api.nvim_buf_clear_namespace(footer_buf, M._ui_ns, 0, -1)
			vim.api.nvim_buf_add_highlight(footer_buf, M._ui_ns, "MRUBuffersHint", 0, 0, -1)
		end

		local footer_lines = { footer }
		set_menu_wrapping(footer_win, should_wrap_lines(footer_win, footer_lines))
	end

	local function mru_items()
		if type(M._prune) == "function" then
			M._prune()
		end

		local items = {}
		for _, path in ipairs(M._list) do
			if type(path) == "string" and path ~= "" then
				local b = vim.fn.bufnr(path, false)
				local is_real = b and b > 0 and U.buf_valid(b) and type(M._buf_real) == "function" and M._buf_real(b)
				local pinned = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) ~= nil
				if is_real then
					table.insert(items, { path = path, bufnr = b })
				elseif pinned then
					table.insert(items, { path = path, bufnr = nil })
				end
			end
		end
		return items
	end

	local function render_menu(list_buf, list_win, items)
		local fancy = M.ui and M.ui.fancy == true

		if not fancy then
			local lines = {}
			for i, it in ipairs(items) do
				local pin_slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(it.path) or nil
				local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
				local disp = vim.fn.fnamemodify(it.path, ":~:.")
				if it.bufnr and vim.bo[it.bufnr].modified then
					disp = disp .. "  [unsaved]"
				elseif not it.bufnr then
					disp = disp .. "  [closed]"
				end
				lines[i] = string.format("%2d  %s  %s", i, pin_tag, disp)
			end

			vim.bo[list_buf].modifiable = true
			vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
			vim.bo[list_buf].modifiable = false

			if list_win and vim.api.nvim_win_is_valid(list_win) then
				set_menu_wrapping(list_win, should_wrap_lines(list_win, lines))
			end
			if M._menu and M._menu.list_buf == list_buf then
				M._menu.items = items
			end
			return
		end

		setup_ui_highlights()

		local lines = {}
		local meta = {}
		for i, it in ipairs(items) do
			local pin_slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(it.path) or nil
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

		vim.bo[list_buf].modifiable = true
		vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
		vim.bo[list_buf].modifiable = false

		if list_win and vim.api.nvim_win_is_valid(list_win) then
			set_menu_wrapping(list_win, should_wrap_lines(list_win, lines))
		end
		if M._menu and M._menu.list_buf == list_buf then
			M._menu.items = items
		end

		vim.api.nvim_buf_clear_namespace(list_buf, M._ui_ns, 0, -1)
		for i = 1, #items do
			local m = meta[i]
			local line = lines[i]
			if not (m and line) then
				break
			end

			vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, "MRUBuffersIndex", i - 1, 0, 2)

			local pin_hl = m.pin_slot and "MRUBuffersPin" or "MRUBuffersClosed"
			vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, pin_hl, i - 1, 4, 7)

			if m.icon_len > 0 and m.icon_hl then
				local icon_col = 9
				vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, m.icon_hl, i - 1, icon_col, icon_col + m.icon_len)
			end

			local name_hl = m.pin_slot and "MRUBuffersPinnedName" or "MRUBuffersName"
			if m.suffix == "  [closed]" then
				name_hl = "MRUBuffersClosed"
			end
			vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, name_hl, i - 1, m.name_col, -1)

			if m.suffix == (M.ui.modified_icon or " ●") then
				local start = #line - #m.suffix
				vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, "MRUBuffersModified", i - 1, start, -1)
			elseif m.suffix == "  [closed]" then
				local start = #line - #m.suffix
				vim.api.nvim_buf_add_highlight(list_buf, M._ui_ns, "MRUBuffersClosed", i - 1, start, -1)
			end
		end
	end

	function M._close_menu()
		if M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win) then
			pcall(vim.api.nvim_win_close, M._menu.list_win, true)
		end
		if M._menu.footer_win and vim.api.nvim_win_is_valid(M._menu.footer_win) then
			pcall(vim.api.nvim_win_close, M._menu.footer_win, true)
		end
		if M._menu.frame_win and vim.api.nvim_win_is_valid(M._menu.frame_win) then
			pcall(vim.api.nvim_win_close, M._menu.frame_win, true)
		end

		if M._menu.list_buf and vim.api.nvim_buf_is_valid(M._menu.list_buf) then
			pcall(vim.api.nvim_buf_delete, M._menu.list_buf, { force = true })
		end
		if M._menu.footer_buf and vim.api.nvim_buf_is_valid(M._menu.footer_buf) then
			pcall(vim.api.nvim_buf_delete, M._menu.footer_buf, { force = true })
		end
		if M._menu.frame_buf and vim.api.nvim_buf_is_valid(M._menu.frame_buf) then
			pcall(vim.api.nvim_buf_delete, M._menu.frame_buf, { force = true })
		end

		M._menu.frame_buf = nil
		M._menu.frame_win = nil
		M._menu.list_buf = nil
		M._menu.list_win = nil
		M._menu.footer_buf = nil
		M._menu.footer_win = nil
		M._menu.origin_win = nil
		M._menu.items = nil
	end

	function M._refresh_menu()
		if not (M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win)) then
			return
		end
		if not (M._menu.list_buf and vim.api.nvim_buf_is_valid(M._menu.list_buf)) then
			return
		end

		local row = vim.api.nvim_win_get_cursor(M._menu.list_win)[1]
		local fresh = mru_items()

		render_menu(M._menu.list_buf, M._menu.list_win, fresh)
		local max_row = math.max(1, math.min(row, #fresh))
		pcall(vim.api.nvim_win_set_cursor, M._menu.list_win, { max_row, 0 })

		if M._menu.footer_buf and M._menu.footer_win and vim.api.nvim_win_is_valid(M._menu.footer_win) then
			update_menu_footer(M._menu.footer_buf, M._menu.footer_win, M._menu.list_win, M._menu.items or fresh)
		end
	end

	function M.open_menu()
		if M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win) then
			M._close_menu()
			return
		end

		local origin_buf = vim.api.nvim_get_current_buf()
		local origin_path = type(M._path_for_buf) == "function" and M._path_for_buf(origin_buf) or nil
		local origin_win = vim.api.nvim_get_current_win()

		local items = mru_items()
		if #items == 0 then
			vim.notify("MRU ring: empty")
			return
		end

		local cols = vim.o.columns
		local lines = vim.o.lines

		local w = math.min(M.ui.width, math.max(30, cols - 4))
		local h = math.min(M.ui.height, math.max(6, lines - 6))
		local footer_enabled = not (M.ui and M.ui.show_footer == false)

		local title = M.ui.title
		if M.ui.fancy == true and M.ui.show_count_in_title ~= false then
			title = string.format(" %s (%d) ", title or "MRU Buffers", #items)
		end

		local frame_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[frame_buf].buftype = "nofile"
		vim.bo[frame_buf].bufhidden = "wipe"
		vim.bo[frame_buf].swapfile = false
		vim.bo[frame_buf].modifiable = false

		local frame_win = vim.api.nvim_open_win(frame_buf, false, {
			relative = "editor",
			width = w,
			height = h,
			col = math.floor((cols - w) / 2),
			row = math.floor((lines - h) / 2),
			style = "minimal",
			border = M.ui.border,
			title = title,
			title_pos = "center",
			focusable = false,
		})

		if M.ui.fancy == true then
			setup_ui_highlights()
			vim.wo[frame_win].winhighlight =
				"Normal:MRUBuffersNormal,FloatBorder:MRUBuffersBorder,FloatTitle:MRUBuffersTitle"
		end

		local list_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[list_buf].buftype = "nofile"
		vim.bo[list_buf].bufhidden = "wipe"
		vim.bo[list_buf].swapfile = false
		vim.bo[list_buf].filetype = "mru-ring"
		vim.bo[list_buf].modifiable = false

		local footer_buf, footer_win
		if footer_enabled then
			footer_buf = vim.api.nvim_create_buf(false, true)
			vim.bo[footer_buf].buftype = "nofile"
			vim.bo[footer_buf].bufhidden = "wipe"
			vim.bo[footer_buf].swapfile = false
			vim.bo[footer_buf].filetype = "mru-ring-footer"
			vim.bo[footer_buf].modifiable = false
		end

		local list_win = vim.api.nvim_open_win(list_buf, true, {
			relative = "win",
			win = frame_win,
			width = w,
			height = footer_enabled and (h - 1) or h,
			col = 0,
			row = 0,
			style = "minimal",
			border = "none",
		})

		if footer_enabled and footer_buf then
			footer_win = vim.api.nvim_open_win(footer_buf, false, {
				relative = "win",
				win = frame_win,
				width = w,
				height = 1,
				col = 0,
				row = h - 1,
				style = "minimal",
				border = "none",
				focusable = false,
			})
		end

		vim.wo[list_win].cursorline = true
		vim.wo[list_win].wrap = false
		vim.wo[list_win].number = false
		vim.wo[list_win].relativenumber = false
		vim.wo[list_win].signcolumn = "no"

		if footer_win then
			vim.wo[footer_win].wrap = false
			vim.wo[footer_win].number = false
			vim.wo[footer_win].relativenumber = false
			vim.wo[footer_win].signcolumn = "no"
		end

		if M.ui.fancy == true then
			setup_ui_highlights()
			vim.wo[list_win].winhighlight = "Normal:MRUBuffersNormal,CursorLine:MRUBuffersCursorLine"
			if footer_win then
				vim.wo[footer_win].winhighlight = "Normal:MRUBuffersNormal"
			end
		end

		M._menu.frame_buf = frame_buf
		M._menu.frame_win = frame_win
		M._menu.list_buf = list_buf
		M._menu.list_win = list_win
		M._menu.footer_buf = footer_buf
		M._menu.footer_win = footer_win
		M._menu.origin_win = origin_win

		render_menu(list_buf, list_win, items)

		local target_line = 1
		if origin_path then
			for i, it in ipairs(items) do
				if it.path == origin_path then
					target_line = i
					break
				end
			end
		end
		vim.api.nvim_win_set_cursor(list_win, { target_line, 0 })

		if footer_enabled and footer_buf and footer_win then
			update_menu_footer(footer_buf, footer_win, list_win, M._menu.items or items)
		end

		vim.api.nvim_create_autocmd("CursorMoved", {
			group = M._augroup,
			buffer = list_buf,
			callback = function()
				if not (M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win)) then
					return
				end
				if M._menu.footer_buf and M._menu.footer_win and vim.api.nvim_win_is_valid(M._menu.footer_win) then
					update_menu_footer(M._menu.footer_buf, M._menu.footer_win, M._menu.list_win, M._menu.items or items)
				end
			end,
		})

		local function with_items(fn)
			return function()
				if not (M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win)) then
					return
				end
				local fresh = mru_items()
				fn(fresh)
			end
		end

		vim.keymap.set(
			"n",
			"<CR>",
			with_items(function(fresh)
				local row = vim.api.nvim_win_get_cursor(0)[1]
				local it = fresh[row]
				if not it then
					return
				end
				local target_win = M._menu.origin_win
				M._close_menu()
				if target_win and vim.api.nvim_win_is_valid(target_win) then
					pcall(vim.api.nvim_set_current_win, target_win)
				end
				if it.bufnr and U.buf_valid(it.bufnr) then
					vim.cmd(("buffer %d"):format(it.bufnr))
					if type(M._normalize_file_buffer) == "function" then
						M._normalize_file_buffer(it.bufnr)
					end
				else
					pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(it.path)))
					local b = vim.fn.bufnr(it.path, false)
					if b and b > 0 and U.buf_valid(b) then
						vim.cmd(("buffer %d"):format(b))
						if type(M._normalize_file_buffer) == "function" then
							M._normalize_file_buffer(b)
						end
					else
						vim.cmd(("edit %s"):format(vim.fn.fnameescape(it.path)))
						if type(M._normalize_file_buffer) == "function" then
							M._normalize_file_buffer(vim.api.nvim_get_current_buf())
						end
					end
				end
			end),
			{ buffer = list_buf, silent = true }
		)

		vim.keymap.set("n", "q", function()
			M._close_menu()
		end, { buffer = list_buf, silent = true })

		vim.keymap.set("n", "<Esc>", function()
			M._close_menu()
		end, { buffer = list_buf, silent = true })

		-- Close selected buffer (only if it has no unsaved changes). Pinned entries
		-- are still kept in the MRU ring and will show as [closed] after close.
		vim.keymap.set(
			"n",
			"c",
			with_items(function(fresh)
				local row = vim.api.nvim_win_get_cursor(0)[1]
				local it = fresh[row]
				if not it or not it.path then
					return
				end

				local bufnr = it.bufnr
				if not (bufnr and U.buf_valid(bufnr)) then
					local b = vim.fn.bufnr(it.path, false)
					bufnr = (b and b > 0 and U.buf_valid(b)) and b or nil
				end
				if not bufnr then
					vim.notify("MRU: buffer already closed", vim.log.levels.INFO)
					return
				end

				if vim.bo[bufnr].modified then
					vim.notify("MRU: buffer has unsaved changes", vim.log.levels.WARN)
					return
				end

				local origin_win = M._menu and M._menu.origin_win or nil
				local list_win = M._menu and M._menu.list_win or nil
				local win_before = vim.api.nvim_get_current_win()

				-- `nvim_buf_delete` behaves more reliably when invoked from a normal
				-- editor window (not a floating menu window), so temporarily switch.
				if origin_win and vim.api.nvim_win_is_valid(origin_win) then
					pcall(vim.api.nvim_set_current_win, origin_win)
				end

				local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })

				-- Restore focus to the menu if it still exists.
				if list_win and vim.api.nvim_win_is_valid(list_win) then
					pcall(vim.api.nvim_set_current_win, list_win)
				else
					pcall(vim.api.nvim_set_current_win, win_before)
				end
				if not ok then
					vim.notify("MRU: failed to close buffer", vim.log.levels.WARN)
					return
				end

				local refreshed = mru_items()
				render_menu(list_buf, list_win, refreshed)
				local new_row = math.min(row, #refreshed)
				vim.api.nvim_win_set_cursor(0, { math.max(1, new_row), 0 })
				if footer_enabled and footer_buf and footer_win then
					update_menu_footer(footer_buf, footer_win, list_win, M._menu.items or refreshed)
				end
			end),
			{ buffer = list_buf, silent = true, desc = "Close buffer (if saved)" }
		)

		vim.keymap.set(
			"n",
			"x",
			with_items(function(fresh)
				local row = vim.api.nvim_win_get_cursor(0)[1]
				local it = fresh[row]
				if not it then
					return
				end
				local slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(it.path) or nil
				if slot then
					M.unpin(slot)
				else
					local free = type(M._first_free_pin_slot) == "function" and M._first_free_pin_slot() or nil
					if not free then
						vim.notify(("MRU: no free pin slots (1-%d)"):format(M.pin_slots), vim.log.levels.WARN)
						return
					end
					if type(M._pin_path) == "function" then
						M._pin_path(it.path, free, it.bufnr)
					end
					if type(M._save_pins) == "function" then
						M._save_pins()
					end
					vim.notify(("MRU: pinned to %d"):format(free), vim.log.levels.INFO)
				end

				local refreshed = mru_items()
				render_menu(list_buf, list_win, refreshed)
				local new_row = math.min(row, #refreshed)
				vim.api.nvim_win_set_cursor(0, { math.max(1, new_row), 0 })
				if footer_enabled and footer_buf and footer_win then
					update_menu_footer(footer_buf, footer_win, list_win, M._menu.items or refreshed)
				end
			end),
			{ buffer = list_buf, silent = true, desc = "Pin/unpin selected" }
		)

		vim.keymap.set(
			"n",
			"X",
			with_items(function(fresh)
				if type(M._pin_slot_for_path) ~= "function" then
					return
				end
				if type(M._first_free_pin_slot) ~= "function" then
					return
				end
				if type(M._pin_path) ~= "function" then
					return
				end

				local row = vim.api.nvim_win_get_cursor(0)[1]

				local pinned = 0
				for _, it in ipairs(fresh) do
					if not it or not it.path then
						break
					end
					if not M._pin_slot_for_path(it.path) then
						local free = M._first_free_pin_slot()
						if not free then
							break
						end
						M._pin_path(it.path, free, it.bufnr)
						pinned = pinned + 1
					end
				end

				if pinned > 0 and type(M._save_pins) == "function" then
					M._save_pins()
				end

				local refreshed = mru_items()
				render_menu(list_buf, list_win, refreshed)
				local new_row = math.min(row, #refreshed)
				vim.api.nvim_win_set_cursor(0, { math.max(1, new_row), 0 })
				if footer_enabled and footer_buf and footer_win then
					update_menu_footer(footer_buf, footer_win, list_win, M._menu.items or refreshed)
				end
			end),
			{ buffer = list_buf, silent = true, desc = "Pin top MRU into free slots" }
		)

		vim.keymap.set("n", "r", function()
			local fresh = mru_items()
			render_menu(list_buf, list_win, fresh)
			if footer_enabled and footer_buf and footer_win then
				update_menu_footer(footer_buf, footer_win, list_win, M._menu.items or fresh)
			end
		end, { buffer = list_buf, silent = true, desc = "Refresh MRU menu" })
	end
end
