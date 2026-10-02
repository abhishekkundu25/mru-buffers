return function(M, U)
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

	local function first_free_pin_slot()
		for i = 1, M.pin_slots do
			if not M._pins[i] then
				return i
			end
		end
		return nil
	end

	local function pin_path(path, slot, bufnr)
		M._activate_directory()
		path = U.normalize_path(path)
		slot = normalize_slot(slot)
		if not path or not slot or not M._in_directory(path) then
			return false
		end

		-- enforce one slot per path (if re-pinning, clear any other slot)
		for s, p in pairs(M._pins) do
			if s ~= slot and p and p.path == path then
				M._pins[s] = nil
			end
		end

		M._pins[slot] = { path = path, bufnr = bufnr }

		if type(M._find_index) == "function" and type(M._enforce_max) == "function" then
			if not M._find_index(path) then
				table.insert(M._list, path)
				M._enforce_max()
			end
		end
		return true
	end

	local function persist_path()
		return M._directory_file(M.persist_file, "pins")
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

		local ok, encoded = pcall(U.json_encode, out)
		if not ok or type(encoded) ~= "string" then
			return
		end

		local file = persist_path()
		pcall(vim.fn.mkdir, vim.fn.fnamemodify(file, ":h"), "p")
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

		local pins = decoded.pins
		if type(pins) ~= "table" then
			return
		end

		for slot_str, pin in pairs(pins) do
			local slot = normalize_slot(slot_str)
			local path = type(pin) == "table" and pin.path or nil
			path = U.normalize_path(path)
			if slot and path then
				pin_path(path, slot, nil)
			end
		end
	end

	M._normalize_slot = normalize_slot
	M._pin_slot_for_path = pin_slot_for_path
	M._first_free_pin_slot = first_free_pin_slot
	M._pin_path = pin_path
	M._save_pins = save_pins
	M._load_pins = load_pins

	function M.pin(slot)
		M._activate_directory()
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

		if not pin_path(path, slot, cur) then
			vim.notify("MRU: cannot pin a file outside the current directory", vim.log.levels.WARN)
			return
		end
		save_pins()
		vim.notify(("MRU: pinned %s to %d"):format(vim.fn.fnamemodify(path, ":~:."), slot), vim.log.levels.INFO)
	end

	function M.unpin(slot)
		M._activate_directory()
		slot = normalize_slot(slot)
		if not slot then
			vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
			return
		end
		M._pins[slot] = nil
		if type(M._prune) == "function" then
			M._prune()
		end
		save_pins()
	end

	function M.jump(slot)
		M._activate_directory()
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

		local path = U.normalize_path(pin.path)
		if not path then
			vim.notify(("MRU: invalid pin in slot %d"):format(slot), vim.log.levels.WARN)
			return
		end

		if not M._navigation.open({ path = path, bufnr = pin.bufnr }, false) then
			vim.notify(("MRU: failed to open pin %d"):format(slot), vim.log.levels.WARN)
		end
	end
end
