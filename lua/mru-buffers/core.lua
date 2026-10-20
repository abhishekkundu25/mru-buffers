return function(M, U)
	-- ========= helpers (core) =========
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
		if not U.buf_valid(buf) then
			return true
		end
		if vim.bo[buf].buflisted ~= true then
			return true
		end

		local bt = vim.bo[buf].buftype or ""
		if bt ~= "" and vim.tbl_contains(M.ignore.buftype, bt) then
			return true
		end

		local ft = vim.bo[buf].filetype or ""
		if ft ~= "" and vim.tbl_contains(M.ignore.filetype, ft) then
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
		if not U.buf_valid(buf) then
			return false
		end
		local ft = vim.bo[buf].filetype or ""
		return ft == "TelescopePrompt" or ft == "TelescopeResults"
	end

	local function normalize_file_buffer(buf)
		if not (buf and U.buf_valid(buf)) then
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
		return U.normalize_path(vim.api.nvim_buf_get_name(buf))
	end

	local function is_pinned_path(path)
		return M._pin_slot_for_path(path) ~= nil
	end

	-- Evicts the oldest unpinned entries; pins may keep the ring above `max`.
	local function enforce_max()
		while #M._list > M.max do
			local removed
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
				M._pos = M._pos - 1
			end
		end
		M._pos = math.max(1, math.min(M._pos, #M._list))
	end

	local function open_buffers()
		local wanted = {}
		for _, path in ipairs(M._list) do
			wanted[path] = true
		end
		local buffers = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			local path = vim.api.nvim_buf_get_name(buf)
			-- Names are cheap; inspect options only for the capped ring's entries.
			if wanted[path] and buf_real(buf) then
				buffers[path] = buf
			end
		end
		return buffers
	end

	local function prune(buffers)
		buffers = buffers or open_buffers()
		local new, new_pos, seen = {}, 1, {}
		for i, path in ipairs(M._list) do
			-- Closed entries stay only when pinned or when `keep_closed` makes the
			-- ring a file history; still capped by `max`.
			if not seen[path] and (buffers[path] or is_pinned_path(path) or M.keep_closed) then
				seen[path] = true
				new[#new + 1] = path
				if i == M._pos then
					new_pos = #new
				end
			end
		end
		M._list, M._pos = new, new_pos
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

	local function mru_persist_path()
		return M._directory_file(M.keep_closed_file, "mru")
	end

	local function persist_mru()
		return M.keep_closed == true and M.keep_closed_persist == true
	end

	local function save_mru()
		if persist_mru() and not U.write_json(mru_persist_path(), { version = 1, list = M._list, pos = M._pos }) then
			if not M._mru_persist_warned then
				M._mru_persist_warned = true
				vim.notify(("MRU: failed to write %s"):format(mru_persist_path()), vim.log.levels.WARN)
			end
		end
	end

	local function load_mru()
		local decoded = persist_mru() and U.read_json(mru_persist_path())
		if not (decoded and type(decoded.list) == "table") then
			return
		end
		local new, seen = {}, {}
		for _, path in ipairs(decoded.list) do
			path = type(path) == "string" and U.normalize_path(path)
			-- Drop files that no longer exist or belong to another directory.
			if path and not seen[path] and M._in_directory(path) and vim.fn.filereadable(path) == 1 then
				seen[path] = true
				new[#new + 1] = path
			end
		end
		M._list, M._pos = new, math.max(1, tonumber(decoded.pos) or 1)
		enforce_max()
	end

	-- One directory-local view for cycling, menu, picker, and integrations.
	function M.entries()
		M._activate_directory()
		local buffers = open_buffers()
		prune(buffers)
		local items = {}
		for _, path in ipairs(M._list) do
			items[#items + 1] = { path = path, bufnr = buffers[path] }
		end
		return items
	end

	local function entry_buf(item)
		if U.buf_valid(item.bufnr) then
			return item.bufnr
		end
		local buf = vim.fn.bufnr(item.path, false)
		return U.buf_valid(buf) and buf or nil
	end

	-- Menu and Telescope `c`: delete an entry's buffer unless it has unsaved
	-- changes. The delete runs in `win` because `nvim_buf_delete` misbehaves
	-- when called from a floating menu or picker window.
	local function close_if_saved(item, win)
		local buf = entry_buf(item)
		if not buf then
			vim.notify("MRU: buffer already closed", vim.log.levels.INFO)
			return false
		end
		if vim.bo[buf].modified then
			vim.notify("MRU: buffer has unsaved changes", vim.log.levels.WARN)
			return false
		end
		local function delete()
			vim.api.nvim_buf_delete(buf, { force = false })
		end
		local ok
		if win and vim.api.nvim_win_is_valid(win) then
			ok = pcall(vim.api.nvim_win_call, win, delete)
		else
			ok = pcall(delete)
		end
		if not ok then
			vim.notify("MRU: failed to close buffer", vim.log.levels.WARN)
		end
		return ok
	end

	-- expose internal helpers for other modules
	M._entry_buf = entry_buf
	M._close_if_saved = close_if_saved
	M._buf_real = buf_real
	M._is_telescope_ui = is_telescope_ui
	M._normalize_file_buffer = normalize_file_buffer
	M._path_for_buf = path_for_buf
	M._enforce_max = enforce_max
	M._prune = prune
	M._find_index = find_index
	M._save_mru = save_mru
	M._load_mru = load_mru
	M._bootstrap_mru = function()
		-- If the plugin is loaded lazily (e.g. `event = "VeryLazy"`), the initial
		-- `BufEnter` may have already happened before our autocmds were registered.
		-- Seed the ring with the current buffer so the MRU isn't empty.
		if #M._list > 0 then
			return
		end
		local cur = vim.api.nvim_get_current_buf()
		if buf_real(cur) then
			M._record(cur)
		end
	end

	-- ========= public: MRU core =========
	function M._record(buf)
		M._activate_directory()
		local path = path_for_buf(buf)
		if not path or not M._in_directory(path) then
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
end
