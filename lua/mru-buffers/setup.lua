return function(M, U)
	local function add_cycle_key(key)
		if not key or key == "" then
			return
		end
		local normalized = U.keytrans(key)
		if normalized and normalized ~= "" then
			M.cycle_keys[normalized] = true
		end
	end

	local function update_cycle_keys(cycle_opts)
		M.cycle_keys = {}
		if type(cycle_opts) == "table" then
			if cycle_opts.prev or cycle_opts.next then
				add_cycle_key(cycle_opts.prev)
				add_cycle_key(cycle_opts.next)
				return
			end
			for _, key in ipairs(cycle_opts) do
				add_cycle_key(key)
			end
			for key, enabled in pairs(cycle_opts) do
				if type(key) == "string" and enabled == true then
					add_cycle_key(key)
				end
			end
			return
		end

		if type(M.keymaps) == "table" then
			add_cycle_key(M.keymaps.prev)
			add_cycle_key(M.keymaps.next)
		end
	end

	local function apply_keymaps()
		if M.keymaps == false then
			return
		end

		local maps = M.keymaps or {}
		local function map(lhs, rhs, desc)
			if not lhs or lhs == "" then
				return
			end
			vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
		end

		map(maps.menu, function()
			M.open_menu()
		end, "MRU menu")

		map(maps.prev, function()
			M.prev()
		end, "MRU cycle prev")

		map(maps.next, function()
			M.next()
		end, "MRU cycle next")

		local pins = maps.pins
		local defaults = M._default_keymaps
		if pins ~= false and type(defaults) == "table" and type(defaults.pins) == "table" then
			local set_prefix = type(pins) == "table" and pins.set_prefix or defaults.pins.set_prefix
			local jump_prefix = type(pins) == "table" and pins.jump_prefix or defaults.pins.jump_prefix

			for i = 1, M.pin_slots do
				if set_prefix and set_prefix ~= "" then
					map(set_prefix .. tostring(i), function()
						M.pin(i)
					end, ("MRU pin %d"):format(i))
				end
				if jump_prefix and jump_prefix ~= "" then
					map(jump_prefix .. tostring(i), function()
						M.jump(i)
					end, ("MRU jump pin %d"):format(i))
				end
			end
		end
	end

	-- init cycle-keys from default keymaps
	update_cycle_keys()

	function M.setup(opts)
		opts = opts or {}

		if opts.keymaps ~= nil then
			if opts.keymaps == false then
				M.keymaps = false
			elseif opts.keymaps == true then
				M.keymaps = vim.deepcopy(M._default_keymaps)
			elseif type(opts.keymaps) == "table" then
				local base = type(M.keymaps) == "table" and M.keymaps or vim.deepcopy(M._default_keymaps)
				M.keymaps = vim.tbl_deep_extend("force", {}, base, opts.keymaps)
			end
		end

		M.max = opts.max or M.max
		if opts.keep_closed ~= nil then
			if type(opts.keep_closed) == "table" then
				-- `keep_closed = { enabled = true, persist = true, file = "..." }`
				local enabled = opts.keep_closed.enabled
				if enabled == nil then
					enabled = true
				end
				M.keep_closed = enabled == true
				M.keep_closed_persist = opts.keep_closed.persist == true
				if opts.keep_closed.file ~= nil then
					M.keep_closed_file = U.normalize_path(opts.keep_closed.file)
				end
				if M.keep_closed_persist == true then
					M.keep_closed = true
				end
			else
				M.keep_closed = opts.keep_closed == true
				M.keep_closed_persist = false
				M.keep_closed_file = nil
			end
		end
		M.commit_on_touch = (opts.commit_on_touch ~= false)
		M.touch_events = opts.touch_events or M.touch_events
		if opts.ignore then
			M.ignore = vim.tbl_deep_extend("force", M.ignore, opts.ignore)
		end
		if opts.ui then
			M.ui = vim.tbl_deep_extend("force", M.ui or {}, opts.ui)
		end
		if opts.git then
			M.git = vim.tbl_deep_extend("force", M.git or {}, opts.git)
		end

		if opts.persist_pins ~= nil then
			M.persist_pins = opts.persist_pins == true
		end
		if opts.persist_file ~= nil then
			M.persist_file = U.normalize_path(opts.persist_file)
		end

		update_cycle_keys(opts.cycle_keys)

		if not M._augroup then
			M._augroup = vim.api.nvim_create_augroup("MRUBuffers", { clear = true })
		else
			vim.api.nvim_clear_autocmds({ group = M._augroup })
		end

		local navigation = M._navigation
		navigation.configure()
		vim.api.nvim_create_autocmd("BufEnter", {
			group = M._augroup,
			callback = function(args)
				navigation.enter(args.buf)
			end,
		})
		vim.api.nvim_create_autocmd(M.touch_events, {
			group = M._augroup,
			callback = navigation.touch,
		})
		vim.api.nvim_create_autocmd("BufLeave", {
			group = M._augroup,
			callback = function(args)
				navigation.leave(args.buf)
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = M._augroup,
			callback = function(args)
				navigation.wipe(args.buf)
			end,
		})

		M._activate_directory()
		vim.api.nvim_create_autocmd({ "DirChanged", "WinEnter", "TabEnter" }, {
			group = M._augroup,
			callback = function()
				M._activate_directory()
			end,
		})

		if
			(M.persist_pins and type(M._save_pins) == "function")
			or (M.keep_closed == true and M.keep_closed_persist == true and type(M._save_mru) == "function")
		then
			vim.api.nvim_create_autocmd("VimLeavePre", {
				group = M._augroup,
				callback = function()
					if M.persist_pins and type(M._save_pins) == "function" then
						M._save_pins()
					end
					if M.keep_closed == true and M.keep_closed_persist == true and type(M._save_mru) == "function" then
						M._save_mru()
					end
				end,
			})
		end

		vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
			group = M._augroup,
			callback = function()
				if type(M._refresh_menu) ~= "function" then
					return
				end
				pcall(M._refresh_menu)
			end,
		})

		vim.api.nvim_create_user_command("MRUMenu", function()
			M.open_menu()
		end, { force = true })

		vim.api.nvim_create_user_command("MRUTelescope", function()
			if type(M.telescope) ~= "function" then
				vim.notify("MRU: telescope integration not available", vim.log.levels.WARN)
				return
			end
			M.telescope()
		end, { force = true })

		vim.api.nvim_create_user_command("MRUPin", function(cmd)
			M.pin(cmd.args)
		end, {
			nargs = 1,
			force = true,
			complete = function()
				local out = {}
				for i = 1, M.pin_slots do
					out[#out + 1] = tostring(i)
				end
				return out
			end,
		})

		vim.api.nvim_create_user_command("MRUUnpin", function(cmd)
			M.unpin(cmd.args)
		end, {
			nargs = 1,
			force = true,
			complete = function()
				local out = {}
				for i = 1, M.pin_slots do
					out[#out + 1] = tostring(i)
				end
				return out
			end,
		})

		vim.api.nvim_create_user_command("MRURing", function()
			local out = {}
			for i, item in ipairs(M.entries()) do
				local path, b = item.path, item.bufnr
				local pin_slot = M._pin_slot_for_path(path)
				local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
				local here = (M._find_index(path) == M._pos) and "  <==" or ""
				local state = b and ("#%d"):format(b) or "(closed)"
				out[#out + 1] = string.format("%3d  %s  %s  %s%s", i, pin_tag, state, path, here)
			end
			vim.notify(#out > 0 and table.concat(out, "\n") or "MRU ring: empty")
		end, { force = true })

		apply_keymaps()
		return M
	end
end
