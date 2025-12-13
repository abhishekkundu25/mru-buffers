return function(M, U)
	local function project_root_for_buf(bufnr)
		if M.pins_scope ~= "project" then
			return nil
		end

		if type(M.project_root) == "function" then
			local ok, root = pcall(M.project_root, bufnr)
			root = ok and type(root) == "string" and root ~= "" and U.normalize_path(root) or nil
			if root then
				return root
			end
		end

		local path = nil
		if U.buf_valid(bufnr) then
			path = vim.api.nvim_buf_get_name(bufnr)
		end

		local cwd = vim.loop.cwd()
		if not path or path == "" then
			return U.normalize_path(cwd)
		end

		local dir = vim.fn.fnamemodify(path, ":p:h")
		local root = U.find_project_root(dir, M.project_markers)
		return U.normalize_path(root or cwd)
	end

	local function pins_table_for_root(root)
		if M.pins_scope ~= "project" then
			M._pins_global = M._pins_global or {}
			return M._pins_global, nil
		end

		root = U.normalize_path(root)
		if not root then
			root = U.normalize_path(vim.loop.cwd())
		end

		M._pins_projects = M._pins_projects or {}
		if not M._pins_projects[root] then
			M._pins_projects[root] = {}
		end
		return M._pins_projects[root], root
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

	local function pin_slot_for_path(path, root)
		if not path or path == "" then
			return nil
		end
		local pins = pins_table_for_root(root)
		for slot, pin in pairs(pins) do
			if pin and pin.path == path then
				return slot
			end
		end
		return nil
	end

	local function first_free_pin_slot(root)
		local pins = pins_table_for_root(root)
		for i = 1, M.pin_slots do
			if not pins[i] then
				return i
			end
		end
		return nil
	end

	local function pin_path(path, slot, bufnr, root)
		path = U.normalize_path(path)
		slot = normalize_slot(slot)
		if not path or not slot then
			return false
		end

		local pins = pins_table_for_root(root)

		-- enforce one slot per path (if re-pinning, clear any other slot)
		for s, p in pairs(pins) do
			if s ~= slot and p and p.path == path then
				pins[s] = nil
			end
		end

		pins[slot] = { path = path, bufnr = bufnr }

		if type(M._find_index) == "function" and type(M._enforce_max) == "function" then
			if not M._find_index(path) then
				table.insert(M._list, path)
				M._enforce_max()
			end
		end
		return true
	end

	local function persist_path()
		if type(M.persist_file) == "string" and M.persist_file ~= "" then
			return M.persist_file
		end
		if M.pins_scope == "project" then
			return vim.fn.stdpath("data") .. "/mru-buffers-pins-project.json"
		end
		return vim.fn.stdpath("data") .. "/mru-buffers-pins.json"
	end

	local function save_pins()
		if not M.persist_pins then
			return
		end

		local out
		if M.pins_scope == "project" then
			out = { version = 2, scope = "project", projects = {} }
			for root, pins in pairs(M._pins_projects or {}) do
				if type(root) == "string" and type(pins) == "table" then
					local proj = {}
					for slot = 1, M.pin_slots do
						local pin = pins[slot]
						if pin and pin.path and pin.path ~= "" then
							local rel = U.relpath(pin.path, root) or pin.path
							proj[tostring(slot)] = { path = rel }
						end
					end
					if next(proj) ~= nil then
						out.projects[root] = proj
					end
				end
			end
		else
			out = { version = 1, scope = "global", pins = {} }
			for slot = 1, M.pin_slots do
				local pin = (M._pins_global or {})[slot]
				if pin and pin.path and pin.path ~= "" then
					out.pins[tostring(slot)] = { path = pin.path }
				end
			end
		end

		local ok, encoded = pcall(U.json_encode, out)
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
		local decoded_ok, decoded = pcall(U.json_decode, table.concat(lines, "\n"))
		if not decoded_ok or type(decoded) ~= "table" then
			return
		end

		if M.pins_scope == "project" then
			if decoded.scope ~= "project" or type(decoded.projects) ~= "table" then
				return
			end
			for root, proj in pairs(decoded.projects) do
				if type(root) == "string" and type(proj) == "table" then
					for slot_str, pin in pairs(proj) do
						local slot = normalize_slot(slot_str)
						local rel = type(pin) == "table" and pin.path or nil
						if slot and type(rel) == "string" and rel ~= "" then
							local abs
							if rel:match("^%a:[/\\]") or rel:sub(1, 1) == "/" or rel:sub(1, 2) == "\\\\" then
								abs = U.normalize_path(rel)
							else
								abs = U.normalize_path(U.joinpath(root, rel))
							end
							if abs then
								pin_path(abs, slot, nil, root)
							end
						end
					end
				end
			end
			return
		end

		if decoded.scope ~= nil and decoded.scope ~= "global" then
			return
		end

		local pins = decoded.pins
		if type(pins) ~= "table" then
			return
		end

		for slot_str, pin in pairs(pins) do
			local slot = normalize_slot(slot_str)
			local path = type(pin) == "table" and pin.path or nil
			path = U.normalize_path(path)
			if slot and path then
				pin_path(path, slot, nil, nil)
			end
		end
	end

	local function each_pin_entry(fn)
		if type(fn) ~= "function" then
			return
		end
		if M.pins_scope == "project" then
			for root, pins in pairs(M._pins_projects or {}) do
				if type(pins) == "table" then
					for slot = 1, M.pin_slots do
						local pin = pins[slot]
						if pin then
							fn(pin, slot, root, pins)
						end
					end
				end
			end
			return
		end

		local pins = M._pins_global or {}
		for slot = 1, M.pin_slots do
			local pin = pins[slot]
			if pin then
				fn(pin, slot, nil, pins)
			end
		end
	end

	local function refresh_pin_bufnr(bufnr)
		if not U.buf_valid(bufnr) then
			return
		end
		local path = U.normalize_path(vim.api.nvim_buf_get_name(bufnr))
		if not path then
			return
		end
		each_pin_entry(function(pin)
			if pin and pin.path == path then
				pin.bufnr = bufnr
			end
		end)
	end

	local function clear_pin_bufnr(bufnr)
		if type(bufnr) ~= "number" then
			return
		end
		each_pin_entry(function(pin)
			if pin and pin.bufnr == bufnr then
				pin.bufnr = nil
			end
		end)
	end

	local function is_pinned_anywhere(path)
		path = U.normalize_path(path)
		if not path then
			return false
		end
		local found = false
		each_pin_entry(function(pin)
			if pin and pin.path == path then
				found = true
			end
		end)
		return found
	end

	M._normalize_slot = normalize_slot
	M._pin_slot_for_path = pin_slot_for_path
	M._first_free_pin_slot = first_free_pin_slot
	M._pin_path = pin_path
	M._save_pins = save_pins
	M._load_pins = load_pins
	M._project_root_for_buf = project_root_for_buf
	M._pins_table_for_root = pins_table_for_root
	M._each_pin_entry = each_pin_entry
	M._refresh_pin_bufnr = refresh_pin_bufnr
	M._clear_pin_bufnr = clear_pin_bufnr
	M._is_pinned_anywhere = is_pinned_anywhere

	function M.pin(slot)
		slot = normalize_slot(slot)
		if not slot then
			vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
			return
		end

		local cur = vim.api.nvim_get_current_buf()
		if type(M._buf_real) == "function" and not M._buf_real(cur) then
			vim.notify("MRU: cannot pin this buffer", vim.log.levels.WARN)
			return
		end

		local path = U.normalize_path(vim.api.nvim_buf_get_name(cur))
		if not path then
			vim.notify("MRU: cannot pin unnamed buffer", vim.log.levels.WARN)
			return
		end

		local root = project_root_for_buf(cur)
		pin_path(path, slot, cur, root)
		save_pins()
		vim.notify(("MRU: pinned %s to %d"):format(vim.fn.fnamemodify(path, ":~:."), slot), vim.log.levels.INFO)
	end

	function M.unpin(slot)
		slot = normalize_slot(slot)
		if not slot then
			vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
			return
		end
		local root = project_root_for_buf(vim.api.nvim_get_current_buf())
		local pins = pins_table_for_root(root)
		pins[slot] = nil
		if type(M._prune) == "function" then
			M._prune()
		end
		save_pins()
	end

	function M.jump(slot)
		slot = normalize_slot(slot)
		if not slot then
			vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
			return
		end

		local root = nil
		if M._menu and M._menu.origin_win and vim.api.nvim_win_is_valid(M._menu.origin_win) then
			local origin_buf = vim.api.nvim_win_get_buf(M._menu.origin_win)
			root = project_root_for_buf(origin_buf)
		else
			root = project_root_for_buf(vim.api.nvim_get_current_buf())
		end

		local pins = pins_table_for_root(root)
		local pin = pins[slot]
		if not pin or not pin.path then
			vim.notify(("MRU: no pin in slot %d"):format(slot), vim.log.levels.INFO)
			return
		end

		local path = U.normalize_path(pin.path)
		if not path then
			vim.notify(("MRU: invalid pin in slot %d"):format(slot), vim.log.levels.WARN)
			return
		end

		local origin_win = nil
		if M._menu and M._menu.list_win and vim.api.nvim_win_is_valid(M._menu.list_win) then
			origin_win = M._menu.origin_win
			if type(M._close_menu) == "function" then
				M._close_menu()
			end
			if origin_win and vim.api.nvim_win_is_valid(origin_win) then
				pcall(vim.api.nvim_set_current_win, origin_win)
			end
		end

		local function go()
			-- If we still have a valid bufnr, use it.
			if pin.bufnr and U.buf_valid(pin.bufnr) then
				vim.cmd(("buffer %d"):format(pin.bufnr))
				if type(M._normalize_file_buffer) == "function" then
					M._normalize_file_buffer(pin.bufnr)
				end
				return true
			end

			-- Try to find an existing buffer for this path.
			local existing = vim.fn.bufnr(path, false)
			if existing and existing > 0 and U.buf_valid(existing) then
				pin.bufnr = existing
				vim.cmd(("buffer %d"):format(existing))
				if type(M._normalize_file_buffer) == "function" then
					M._normalize_file_buffer(existing)
				end
				return true
			end

			-- Reopen from disk as a normal listed buffer.
			pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(path)))
			local b = vim.fn.bufnr(path, false)
			if b and b > 0 and U.buf_valid(b) then
				pin.bufnr = b
				vim.cmd(("buffer %d"):format(b))
				if type(M._normalize_file_buffer) == "function" then
					M._normalize_file_buffer(b)
				end
				return true
			end

			local ok = pcall(vim.cmd, ("edit %s"):format(vim.fn.fnameescape(path)))
			if ok and type(M._normalize_file_buffer) == "function" then
				M._normalize_file_buffer(vim.api.nvim_get_current_buf())
			end
			return ok
		end

		local ok = pcall(go)
		if not ok then
			vim.notify(("MRU: failed to open pin %d"):format(slot), vim.log.levels.WARN)
		end
	end
end
