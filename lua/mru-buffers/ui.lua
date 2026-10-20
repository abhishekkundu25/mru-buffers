return function(M, U)
	-- Harpoon-like floating menu: a bordered frame holding the list and a one-line footer.
	local menu = M._menu
	local ns = vim.api.nvim_create_namespace("MRUBuffersUI")

	-- Re-linked on every open so a `:colorscheme` change cannot drop them.
	local function setup_highlights()
		for group, target in pairs({
			MRUBuffersNormal = "Normal",
			MRUBuffersBorder = "FloatBorder",
			MRUBuffersTitle = "FloatTitle",
			MRUBuffersCursorLine = "CursorLine",
			MRUBuffersIndex = "LineNr",
			MRUBuffersPin = "DiagnosticHint",
			MRUBuffersPinnedName = "Directory",
			MRUBuffersName = "Normal",
			MRUBuffersModified = "DiagnosticWarn",
			MRUBuffersClosed = "Comment",
			MRUBuffersHint = "Comment",
			MRUBuffersGitAdd = "DiffAdd",
			MRUBuffersGitDel = "DiffDelete",
		}) do
			vim.api.nvim_set_hl(0, group, { link = target, default = true })
		end
	end

	local function devicon(path)
		if not M.ui.show_icons then
			return
		end
		-- Check the option first: a failed `require` searches the whole runtimepath.
		local ok, devicons = pcall(require, "nvim-web-devicons")
		if ok then
			return devicons.get_icon(vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
		end
	end

	local function valid_win(win)
		return win and vim.api.nvim_win_is_valid(win)
	end

	local function set_lines(buf, lines)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end

	-- Soft-wrap only when some line is wider than the window.
	local function set_wrap(win, lines)
		local width, wrap = vim.api.nvim_win_get_width(win), false
		for _, line in ipairs(lines) do
			wrap = wrap or vim.fn.strdisplaywidth(line) > width
		end
		local wo = vim.wo[win]
		wo.wrap, wo.linebreak, wo.breakindent = wrap, wrap, wrap
		wo.breakindentopt = wrap and "shift:2,min:10" or ""
		wo.showbreak = wrap and string.rep(" ", 10) or ""
	end

	-- Line layout: "%2d  [p]  <icon> <name> [+a -d]<status>"; the name starts at byte 9 + icon.
	local function render_list(items)
		local fancy = M.ui.fancy == true
		local stats = {}
		if M.git.enabled == true and M.git.show_in_menu ~= false then
			stats = M._git_stats_for_paths(vim.tbl_map(function(it)
				return it.path
			end, items))
		end

		local lines, marks = {}, {}
		for i, it in ipairs(items) do
			local slot = M._pin_slot_for_path(it.path)
			local icon, icon_hl
			if fancy then
				icon, icon_hl = devicon(it.path)
			end
			local prefix = ("%2d  %s  %s"):format(i, slot and ("[" .. slot .. "]") or "   ", icon and (icon .. " ") or "")
			local name = vim.fn.fnamemodify(it.path, ":~:.")
			local st = stats[it.path]
			local badge, badge_ranges = "", {}
			if st then
				badge, badge_ranges = M._git_format_badge(st.add, st.del)
				badge = " [" .. badge .. "]"
			end
			local status = ""
			if not it.bufnr then
				status = "  [closed]"
			elseif vim.bo[it.bufnr].modified then
				status = fancy and M.ui.modified_icon or "  [unsaved]"
			end
			local line = prefix .. name .. badge .. status
			lines[i] = line

			if fancy then
				local function mark(s, e, group, priority)
					marks[#marks + 1] = { i - 1, s, e, group, priority }
				end
				mark(0, 2, "MRUBuffersIndex")
				mark(4, 7, slot and "MRUBuffersPin" or "MRUBuffersClosed")
				if icon and icon_hl then
					mark(9, 9 + #icon, icon_hl)
				end
				local name_hl = not it.bufnr and "MRUBuffersClosed" or slot and "MRUBuffersPinnedName" or "MRUBuffersName"
				-- Lower priority so the git counts drawn over the badge win.
				mark(#prefix, #line - #status, name_hl, 4095)
				local badge_col = #prefix + #name + 2 -- after " ["
				for key, group in pairs({ add = "MRUBuffersGitAdd", del = "MRUBuffersGitDel" }) do
					local r = badge_ranges[key]
					if r then
						mark(badge_col + r.start - 1, badge_col + r.start - 1 + r.len, group)
					end
				end
				if status ~= "" then
					mark(#line - #status, #line, it.bufnr and "MRUBuffersModified" or "MRUBuffersClosed")
				end
			end
		end

		set_lines(menu.list_buf, lines)
		vim.api.nvim_buf_clear_namespace(menu.list_buf, ns, 0, -1)
		for _, m in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(menu.list_buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = m[5] })
		end
		set_wrap(menu.list_win, lines)
		menu.items = items
	end

	local function cycle_hint()
		local maps = type(M.keymaps) == "table" and M.keymaps or {}
		local keys = {}
		for _, key in ipairs({ maps.prev, maps.next }) do
			if key and key ~= "" then
				keys[#keys + 1] = U.keytrans(key)
			end
		end
		return #keys > 0 and (table.concat(keys, "/") .. ": cycle") or "cycle: prev/next"
	end

	-- Footer hints follow the selected row: which slot `x` would use, whether `c` can close.
	local function render_footer()
		if not valid_win(menu.footer_win) then
			return
		end
		local fancy = M.ui.fancy == true
		local it = menu.items[vim.api.nvim_win_get_cursor(menu.list_win)[1]]
		local slot = it and M._pin_slot_for_path(it.path)
		local free = M._first_free_pin_slot()
		local buf = it and M._entry_buf(it)

		local parts = {
			not it and "x: pin/unpin"
				or slot and ("x: unpin [%d]"):format(slot)
				or free and ("x: pin -> [%d]"):format(free)
				or ("x: pin (no slots 1-%d)"):format(M.pin_slots),
			free and "X: pin top" or "X: no slots",
			not it and "c: close" or not buf and "c: closed" or vim.bo[buf].modified and "c: modified" or "c: close",
		}
		if fancy then
			vim.list_extend(parts, { "<CR>: open", "r: refresh", cycle_hint() })
		end
		parts[#parts + 1] = "q/<Esc>: close"
		local footer = table.concat(parts, fancy and "  •  " or "   ")

		set_lines(menu.footer_buf, { footer })
		vim.api.nvim_buf_clear_namespace(menu.footer_buf, ns, 0, -1)
		if fancy then
			vim.api.nvim_buf_set_extmark(menu.footer_buf, ns, 0, 0, { end_col = #footer, hl_group = "MRUBuffersHint" })
		end
		set_wrap(menu.footer_win, { footer })
	end

	function M._close_menu()
		-- Buffers are `bufhidden=wipe`, so closing the windows also wipes them.
		for _, win in ipairs({ menu.list_win, menu.footer_win, menu.frame_win }) do
			if valid_win(win) then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		for key in pairs(menu) do
			menu[key] = nil
		end
	end

	function M._refresh_menu()
		if not valid_win(menu.list_win) then
			return
		end
		local row = vim.api.nvim_win_get_cursor(menu.list_win)[1]
		local items = M.entries()
		render_list(items)
		vim.api.nvim_win_set_cursor(menu.list_win, { math.max(1, math.min(row, #items)), 0 })
		render_footer()
	end

	local function scratch_buf(filetype)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = filetype
		vim.bo[buf].modifiable = false
		return buf
	end

	function M.open_menu()
		if valid_win(menu.list_win) then
			M._close_menu()
			return
		end

		local origin_path = M._path_for_buf(vim.api.nvim_get_current_buf())
		local origin_win = vim.api.nvim_get_current_win()
		local items = M.entries()
		if #items == 0 then
			vim.notify("MRU ring: empty")
			return
		end

		local fancy = M.ui.fancy == true
		local footer = M.ui.show_footer ~= false
		local w = math.min(M.ui.width, math.max(30, vim.o.columns - 4))
		local h = math.min(M.ui.height, math.max(6, vim.o.lines - 6))
		local title = M.ui.title
		if fancy and M.ui.show_count_in_title ~= false then
			title = (" %s (%d) "):format(title, #items)
		end
		if fancy then
			setup_highlights()
		end

		local function child(buf, enter, row, height, focusable)
			return vim.api.nvim_open_win(buf, enter, {
				relative = "win",
				win = menu.frame_win,
				width = w,
				height = height,
				col = 0,
				row = row,
				style = "minimal",
				border = "none", -- ignore a global 'winborder'
				focusable = focusable,
			})
		end

		menu.origin_win = origin_win
		menu.frame_buf = scratch_buf("")
		menu.frame_win = vim.api.nvim_open_win(menu.frame_buf, false, {
			relative = "editor",
			width = w,
			height = h,
			col = math.floor((vim.o.columns - w) / 2),
			row = math.floor((vim.o.lines - h) / 2),
			style = "minimal",
			border = M.ui.border,
			title = title,
			title_pos = "center",
			focusable = false,
		})
		menu.list_buf = scratch_buf("mru-ring")
		menu.list_win = child(menu.list_buf, true, 0, footer and h - 1 or h, true)
		vim.wo[menu.list_win].cursorline = true
		if footer then
			menu.footer_buf = scratch_buf("mru-ring-footer")
			menu.footer_win = child(menu.footer_buf, false, h - 1, 1, false)
		end
		if fancy then
			vim.wo[menu.frame_win].winhighlight =
				"Normal:MRUBuffersNormal,FloatBorder:MRUBuffersBorder,FloatTitle:MRUBuffersTitle"
			vim.wo[menu.list_win].winhighlight = "Normal:MRUBuffersNormal,CursorLine:MRUBuffersCursorLine"
			if menu.footer_win then
				vim.wo[menu.footer_win].winhighlight = "Normal:MRUBuffersNormal"
			end
		end

		render_list(items)
		local start = 1
		for i, it in ipairs(items) do
			if it.path == origin_path then
				start = i
				break
			end
		end
		vim.api.nvim_win_set_cursor(menu.list_win, { start, 0 })
		render_footer()

		vim.api.nvim_create_autocmd("CursorMoved", {
			group = M._augroup,
			buffer = menu.list_buf,
			callback = render_footer,
		})

		-- Actions read the displayed snapshot so an event cannot change row identity.
		local function map(lhs, desc, fn)
			vim.keymap.set("n", lhs, function()
				fn(menu.items[vim.api.nvim_win_get_cursor(0)[1]])
			end, { buffer = menu.list_buf, silent = true, desc = desc })
		end
		map("<CR>", "Open selected", function(it)
			-- `open` closes the menu and returns to the origin window first.
			if it and not M._navigation.open(it, false) then
				vim.notify("MRU: failed to open entry", vim.log.levels.WARN)
			end
		end)
		map("q", "Close menu", M._close_menu)
		map("<Esc>", "Close menu", M._close_menu)
		-- Pinned entries stay in the ring and show as [closed] after close.
		map("c", "Close buffer (if saved)", function(it)
			if it and M._close_if_saved(it, menu.origin_win) then
				M._refresh_menu()
			end
		end)
		map("x", "Pin/unpin selected", function(it)
			if it and M._toggle_pin(it) then
				M._refresh_menu()
			end
		end)
		map("X", "Pin top MRU into free slots", function()
			if M._pin_top(menu.items) then
				M._refresh_menu()
			end
		end)
		map("r", "Refresh MRU menu", M._refresh_menu)
	end
end
