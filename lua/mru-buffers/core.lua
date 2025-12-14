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
		if bt ~= "" and U.list_contains(M.ignore.buftype, bt) then
			return true
		end

		local ft = vim.bo[buf].filetype or ""
		if ft ~= "" and U.list_contains(M.ignore.filetype, ft) then
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
		return type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) ~= nil
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
				if b and b > 0 and U.buf_valid(b) and buf_real(b) then
					keep = true
				elseif is_pinned_path(path) then
					keep = true
				elseif M.keep_closed == true then
					-- Keep closed (non-pinned) entries in the MRU list so the ring
					-- acts like a file history; still capped by `max`.
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

	local function mru_persist_path()
		if type(M.keep_closed_file) == "string" and M.keep_closed_file ~= "" then
			return M.keep_closed_file
		end
		return vim.fn.stdpath("state") .. "/mru-buffers-mru.json"
	end

	local function mru_legacy_persist_path()
		-- Backwards compat: older versions stored MRU in stdpath("data").
		if type(M.keep_closed_file) == "string" and M.keep_closed_file ~= "" then
			return nil
		end
		return vim.fn.stdpath("data") .. "/mru-buffers-mru.json"
	end

	local function save_mru()
		if not (M.keep_closed == true and M.keep_closed_persist == true) then
			return
		end

		local out = { version = 1, list = {}, pos = tonumber(M._pos) or 1 }
		for _, path in ipairs(M._list or {}) do
			if type(path) == "string" and path ~= "" then
				out.list[#out.list + 1] = path
			end
		end

		local ok, encoded = pcall(U.json_encode, out)
		if not ok or type(encoded) ~= "string" then
			return
		end

		local file = mru_persist_path()
		pcall(vim.fn.writefile, { encoded }, file)
	end

	local function load_mru()
		if not (M.keep_closed == true and M.keep_closed_persist == true) then
			return
		end

		local file = mru_persist_path()
		if vim.fn.filereadable(file) ~= 1 then
			local legacy = mru_legacy_persist_path()
			if legacy and vim.fn.filereadable(legacy) == 1 then
				file = legacy
			else
				return
			end
		end

		local lines = vim.fn.readfile(file)
		local decoded_ok, decoded = pcall(U.json_decode, table.concat(lines, "\n"))
		if not decoded_ok or type(decoded) ~= "table" then
			return
		end

		local list = decoded.list
		if type(list) ~= "table" then
			return
		end

		local new = {}
		local seen = {}
		for _, path in ipairs(list) do
			if type(path) == "string" and path ~= "" then
				path = U.normalize_path(path)
				if path and not seen[path] then
					-- keep only existing files; non-existent paths aren't useful
					if vim.fn.filereadable(path) == 1 then
						seen[path] = true
						new[#new + 1] = path
					end
				end
			end
		end

		M._list = new
		if #M._list == 0 then
			M._pos = 1
		else
			local pos = tonumber(decoded.pos) or 1
			M._pos = math.min(math.max(1, pos), #M._list)
		end

		enforce_max()

		-- If we loaded from the legacy location, save once to the new default.
		if file == mru_legacy_persist_path() then
			save_mru()
		end
	end

	-- expose internal helpers for other modules
	M._should_ignore = should_ignore
	M._buf_real = buf_real
	M._is_telescope_ui = is_telescope_ui
	M._normalize_file_buffer = normalize_file_buffer
	M._path_for_buf = path_for_buf
	M._enforce_max = enforce_max
	M._prune = prune
	M._find_index = find_index
	M._clear_preview = clear_preview
	M._save_mru = save_mru
	M._load_mru = load_mru

	-- ========= public: MRU core =========
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
		if not (b and b > 0 and U.buf_valid(b)) then
			pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(path)))
			b = vim.fn.bufnr(path, false)
		end
		if b and b > 0 and U.buf_valid(b) then
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
			M._preview_active = true
			M._preview_buf = vim.api.nvim_get_current_buf()
			M._preview_key_counter_at_enter = M._key_counter
		end

		return ok
	end

	function M.prev()
		if M._menu and M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win) then
			local target_win = M._menu.origin_win
			if type(M._close_menu) == "function" then
				M._close_menu()
			end
			if target_win and vim.api.nvim_win_is_valid(target_win) then
				pcall(vim.api.nvim_set_current_win, target_win)
			end
		end

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
		if M._menu and M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win) then
			local target_win = M._menu.origin_win
			if type(M._close_menu) == "function" then
				M._close_menu()
			end
			if target_win and vim.api.nvim_win_is_valid(target_win) then
				pcall(vim.api.nvim_set_current_win, target_win)
			end
		end

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
end
