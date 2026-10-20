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

		if not M._find_index(path) then
			table.insert(M._list, path)
			M._enforce_max()
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
		local pins = {}
		for slot, pin in pairs(M._pins) do
			pins[tostring(slot)] = { path = pin.path }
		end
		U.write_json(persist_path(), { version = 1, pins = pins })
	end

	local function load_pins()
		local decoded = M.persist_pins and U.read_json(persist_path())
		if not (decoded and type(decoded.pins) == "table") then
			return
		end
		for slot, pin in pairs(decoded.pins) do
			local path = type(pin) == "table" and U.normalize_path(pin.path)
			if path then
				pin_path(path, slot, nil)
			end
		end
	end

	-- Menu and Telescope `x`: unpin a pinned entry, otherwise take the first free slot.
	local function toggle_pin(item)
		local slot = pin_slot_for_path(item.path)
		if slot then
			M.unpin(slot)
			return true
		end
		local free = first_free_pin_slot()
		if not free then
			vim.notify(("MRU: no free pin slots (1-%d)"):format(M.pin_slots), vim.log.levels.WARN)
			return false
		end
		if not pin_path(item.path, free, item.bufnr) then
			vim.notify("MRU: cannot pin a file outside the current directory", vim.log.levels.WARN)
			return false
		end
		save_pins()
		vim.notify(("MRU: pinned to %d"):format(free), vim.log.levels.INFO)
		return true
	end

	-- Menu and Telescope `X`: fill free slots from the top of `items`.
	local function pin_top(items)
		local pinned = 0
		for _, item in ipairs(items) do
			if not pin_slot_for_path(item.path) then
				local free = first_free_pin_slot()
				if not free then
					break
				end
				if pin_path(item.path, free, item.bufnr) then
					pinned = pinned + 1
				end
			end
		end
		if pinned > 0 then
			save_pins()
		end
		return pinned > 0
	end

	M._pin_slot_for_path = pin_slot_for_path
	M._first_free_pin_slot = first_free_pin_slot
	M._save_pins = save_pins
	M._load_pins = load_pins
	M._toggle_pin = toggle_pin
	M._pin_top = pin_top

	function M.pin(slot)
		M._activate_directory()
		slot = normalize_slot(slot)
		if not slot then
			vim.notify(("MRU: pin slot must be 1-%d"):format(M.pin_slots), vim.log.levels.WARN)
			return
		end

		local cur = vim.api.nvim_get_current_buf()
		if not M._buf_real(cur) then
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
		M._prune()
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
