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

	local function open_buffers()
		local wanted = {}
		for _, entry in ipairs(M._list) do
			local path = type(entry) == "number" and path_for_buf(entry) or entry
			if path then
				wanted[path] = true
			end
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
		local new = {}
		local new_pos = 1
		local seen = {}

		for i, entry in ipairs(M._list) do
			local path = entry
			if type(entry) == "number" then
				path = path_for_buf(entry)
			end
			if type(path) == "string" and path ~= "" and not seen[path] then
				local b = buffers[path]
				local keep = false
				if b then
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

	local function mru_persist_path()
		return M._directory_file(M.keep_closed_file, "mru")
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
		local dir = vim.fn.fnamemodify(file, ":h")
		if dir and dir ~= "" then
			pcall(vim.fn.mkdir, dir, "p")
		end

		local w_ok, w_res = pcall(vim.fn.writefile, { encoded }, file)
		if not w_ok or w_res ~= 0 then
			if not M._mru_persist_warned then
				M._mru_persist_warned = true
				pcall(vim.notify, ("MRU: failed to write MRU persistence file: %s"):format(file), vim.log.levels.WARN)
			end
		end
	end

	local function load_mru()
		if not (M.keep_closed == true and M.keep_closed_persist == true) then
			return
		end

		local file = mru_persist_path()
		if vim.fn.filereadable(file) ~= 1 then
			return
		end

		local r_ok, lines = pcall(vim.fn.readfile, file)
		if not r_ok or type(lines) ~= "table" then
			return
		end
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
				if path and M._in_directory(path) and not seen[path] then
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

	-- expose internal helpers for other modules
	M._should_ignore = should_ignore
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
		if type(M._list) == "table" and #M._list > 0 then
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
