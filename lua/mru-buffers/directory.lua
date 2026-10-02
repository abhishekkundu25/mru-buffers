return function(M, U)
	local states = {}
	local active

	local function contains(path, directory)
		local prefix = directory:gsub("/+$", "") .. "/"
		return type(path) == "string" and path:sub(1, #prefix) == prefix
	end

	local function current_directory()
		local win = vim.api.nvim_get_current_win()
		local menu = M._menu
		if menu and (win == menu.list_win or win == menu.frame_win or win == menu.footer_win) then
			win = menu.origin_win
		elseif M._is_telescope_ui(vim.api.nvim_get_current_buf()) then
			win = M._picker_origin_win or win
		end
		if not (win and vim.api.nvim_win_is_valid(win)) then
			win = vim.api.nvim_get_current_win()
		end
		return U.normalize_path(vim.fn.getcwd(win)):gsub("/+$", "") .. "/"
	end

	function M._in_directory(path)
		return active and contains(path, active.directory) or false
	end

	function M._directory_file(override, name)
		local hash = active.hash
		if type(override) == "string" and override ~= "" then
			local base, extension = override:match("^(.*)(%.[^/.]+)$")
			return (base or override) .. "-" .. hash .. (extension or "")
		end
		return vim.fn.stdpath("data") .. "/mru-buffers/" .. hash .. "/" .. name .. ".json"
	end

	function M._activate_directory()
		local directory = current_directory()
		if active and active.directory == directory then
			return false
		end
		if active then
			M._save_mru()
			M._save_pins()
			active.list, active.pins, active.pos = M._list, M._pins, M._pos
		end
		local state = states[directory]
		local is_new = not state
		if is_new then
			state = { directory = directory, hash = vim.fn.sha256(directory), list = {}, pins = {}, pos = 1 }
			states[directory] = state
		end
		active = state
		M._list, M._pins, M._pos = state.list, state.pins, state.pos
		M._navigation.reset()
		if is_new then
			M._load_mru()
			M._load_pins()
			-- Seed eligible buffers already open when this directory is first used.
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				local path = vim.api.nvim_buf_get_name(buf)
				if contains(path, directory) and M._buf_real(buf) and not M._find_index(path) then
					table.insert(M._list, path)
				end
			end
			M._enforce_max()
			M._record(vim.api.nvim_get_current_buf())
		end
		M._bootstrap_mru()
		return true
	end
end
