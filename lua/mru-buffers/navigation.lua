return function(M, U)
	-- Navigation owns preview, keypress gating, and picker cancellation state.
	local N = {}
	local locked = false
	local preview_buf, preview_counter
	local key_counter, last_key = 0, ""
	local key_ns
	local picker_origin, picker_pos

	local function clear_preview()
		preview_buf, preview_counter = nil, nil
	end

	local function refresh_pin(buf)
		local path = M._path_for_buf(buf)
		local slot = path and M._pin_slot_for_path(path)
		if slot then
			M._pins[slot].bufnr = buf
		end
	end

	function N.enter(buf)
		M._activate_directory()
		if locked then
			return
		end
		if M._is_telescope_ui(buf) then
			if not picker_origin then
				picker_origin, picker_pos = vim.fn.bufnr("#"), M._pos
			end
			return
		end
		if picker_origin then
			local origin, pos = picker_origin, picker_pos
			picker_origin, picker_pos = nil, nil
			if buf == origin then
				M._pos = pos
				return
			end
		end
		refresh_pin(buf)
		clear_preview()
		M._record(buf)
	end

	function N.touch()
		M._activate_directory()
		local buf = vim.api.nvim_get_current_buf()
		if locked or not M.commit_on_touch or buf ~= preview_buf then
			return
		end
		if key_counter == preview_counter or M.cycle_keys[last_key] or not M._buf_real(buf) then
			return
		end
		clear_preview()
		M._record(buf)
	end

	function N.leave(buf)
		if buf == preview_buf then
			clear_preview()
		end
	end

	function N.wipe(buf)
		for _, pin in pairs(M._pins) do
			if pin.bufnr == buf then
				pin.bufnr = nil
			end
		end
		if preview_buf == buf then
			clear_preview()
		end
	end

	function N.reset()
		clear_preview()
		picker_origin, picker_pos = nil, nil
	end

	function N.configure()
		N.reset()
		if key_ns then
			return
		end
		key_ns = vim.api.nvim_create_namespace("mru_ring_keytrack")
		vim.on_key(function(ch)
			if preview_buf and vim.api.nvim_get_current_buf() == preview_buf then
				key_counter = key_counter + 1
				last_key = vim.fn.keytrans(ch)
			end
		end, key_ns)
	end

	local function restore_menu_origin()
		local menu = M._menu
		if not (menu and menu.list_win and vim.api.nvim_win_is_valid(menu.list_win)) then
			return
		end
		local win = menu.origin_win
		M._close_menu()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
	end

	function N.open(item, preview)
		if not (item and type(item.path) == "string" and item.path ~= "") then
			return false
		end
		locked = true
		local ok = pcall(function()
			restore_menu_origin()
			M._activate_directory()
			assert(M._in_directory(item.path), "MRU: entry is outside the current directory")
			local buf = item.bufnr
			if not U.buf_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= item.path then
				buf = vim.fn.bufnr(item.path, false)
			end
			if not (buf and buf > 0 and U.buf_valid(buf)) then
				vim.cmd(("badd %s"):format(vim.fn.fnameescape(item.path)))
				buf = vim.fn.bufnr(item.path, false)
			end
			if buf and buf > 0 and U.buf_valid(buf) then
				vim.api.nvim_set_current_buf(buf)
			else
				vim.cmd(("edit %s"):format(vim.fn.fnameescape(item.path)))
			end
			M._normalize_file_buffer(vim.api.nvim_get_current_buf())
		end)
		locked = false
		if not ok then
			return false
		end
		local buf = vim.api.nvim_get_current_buf()
		refresh_pin(buf)
		M._pos = M._find_index(item.path) or M._pos
		clear_preview()
		if preview then
			preview_buf, preview_counter = buf, key_counter
		else
			M._record(buf)
		end
		return true
	end

	local function cycle(step)
		locked = true
		local ok, err = pcall(restore_menu_origin)
		locked = false
		if not ok then
			vim.notify("MRU: failed to restore origin window: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		local items = M.entries()
		local count = #items
		if count == 0 then
			vim.notify("MRU: nothing to cycle", vim.log.levels.INFO)
			return
		end
		local current = M._path_for_buf(vim.api.nvim_get_current_buf())
		local index
		for i, item in ipairs(items) do
			if item.path == current then
				index = i
				break
			end
		end
		if count == 1 then
			N.open(items[1], M.commit_on_touch)
			return
		end
		if not index then
			if N.open(items[1], M.commit_on_touch) then
				return
			end
			index = 1
		end
		for _ = 1, count do
			index = ((index - 1 + step) % count) + 1
			local item = items[index]
			if item.path ~= current and N.open(item, M.commit_on_touch) then
				return
			end
		end
		vim.notify("MRU: no valid target", vim.log.levels.INFO)
	end

	function M.prev()
		cycle(1)
	end
	function M.next()
		cycle(-1)
	end
	M._navigation = N
end
