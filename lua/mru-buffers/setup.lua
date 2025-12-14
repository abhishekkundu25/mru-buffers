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
			M.keep_closed = opts.keep_closed == true
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
			M.persist_file = opts.persist_file
		end

		update_cycle_keys(opts.cycle_keys)

		if not M._augroup then
			M._augroup = vim.api.nvim_create_augroup("MRUBuffers", { clear = true })
		else
			vim.api.nvim_clear_autocmds({ group = M._augroup })
		end

		-- Keypress tracker (only used to gate "touch" commits)
		if not M._key_ns then
			M._key_ns = vim.api.nvim_create_namespace("mru_ring_keytrack")
			vim.on_key(function(ch)
				if not M._preview_active then
					return
				end
				if vim.api.nvim_get_current_buf() ~= M._preview_buf then
					return
				end
				M._key_counter = M._key_counter + 1
				M._last_key = vim.fn.keytrans(ch)
			end, M._key_ns)
		end

		-- Record normal BufEnter, but do not let Telescope cancel reorder MRU
		vim.api.nvim_create_autocmd("BufEnter", {
			group = M._augroup,
			callback = function(args)
				local buf = args.buf

				-- entering telescope UI
				if type(M._is_telescope_ui) == "function" and M._is_telescope_ui(buf) then
					if not M._ui_active then
						M._ui_active = true
						M._ui_origin_buf = vim.fn.bufnr("#")
						M._ui_origin_pos = M._pos
					end
					return
				end

				-- leaving telescope UI
				if M._ui_active then
					local origin = M._ui_origin_buf
					local origin_pos = M._ui_origin_pos
					M._ui_active, M._ui_origin_buf, M._ui_origin_pos = false, nil, nil

					-- Cancel -> ended up back at origin: do nothing
					if origin and buf == origin then
						if origin_pos then
							M._pos = origin_pos
						end
						return
					end
				end

				-- if we entered due to our MRU cycling, do not record here
				if M._nav_lock then
					return
				end

				-- refresh pinned bufnr when entering a pinned file
				if type(M._path_for_buf) == "function" and type(M._pin_slot_for_path) == "function" then
					local path = M._path_for_buf(buf)
					local slot = path and M._pin_slot_for_path(path) or nil
					if slot and M._pins[slot] then
						M._pins[slot].bufnr = buf
					end
				end

				-- normal navigation: commit immediately
				if type(M._clear_preview) == "function" then
					M._clear_preview()
				end
				M._record(buf)
			end,
		})

		-- Commit preview only after real user input (not internal CursorMoved)
		vim.api.nvim_create_autocmd(M.touch_events, {
			group = M._augroup,
			callback = function()
				if not M.commit_on_touch then
					return
				end
				if not M._preview_active then
					return
				end

				local cur = vim.api.nvim_get_current_buf()
				if cur ~= M._preview_buf then
					return
				end
				if type(M._buf_real) == "function" and not M._buf_real(cur) then
					return
				end

				-- If no keypress happened since we entered preview, ignore (internal events)
				if M._key_counter == M._preview_key_counter_at_enter then
					return
				end

				-- If the last keypress is one of our cycle keys, ignore (just cycling)
				if M.cycle_keys[M._last_key] then
					return
				end

				-- Otherwise, user actually did something => commit
				if type(M._clear_preview) == "function" then
					M._clear_preview()
				end
				M._record(cur)
			end,
		})

		-- If we leave preview buffer without committing, discard preview state
		vim.api.nvim_create_autocmd("BufLeave", {
			group = M._augroup,
			callback = function(args)
				if not M.commit_on_touch then
					return
				end
				if not M._preview_active then
					return
				end
				if args.buf ~= M._preview_buf then
					return
				end
				if type(M._clear_preview) == "function" then
					M._clear_preview()
				end
			end,
		})

		vim.api.nvim_create_autocmd("BufWipeout", {
			group = M._augroup,
			callback = function(args)
				-- keep pins even if the underlying buffer is wiped
				if args and args.buf then
					for _, pin in pairs(M._pins) do
						if pin and pin.bufnr == args.buf then
							pin.bufnr = nil
						end
					end
				end
				if type(M._prune) == "function" then
					M._prune()
				end
				if M._preview_active and not U.buf_valid(M._preview_buf) then
					if type(M._clear_preview) == "function" then
						M._clear_preview()
					end
				end
			end,
		})

		if M.persist_pins and type(M._load_pins) == "function" then
			M._load_pins()
			vim.api.nvim_create_autocmd("VimLeavePre", {
				group = M._augroup,
				callback = function()
					if type(M._save_pins) == "function" then
						M._save_pins()
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
			if type(M._prune) == "function" then
				M._prune()
			end
			local out = {}
			for i, path in ipairs(M._list) do
				if type(path) == "string" and path ~= "" then
					local b = vim.fn.bufnr(path, false)
					local pin_slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) or nil
					local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
					local here = (i == M._pos) and "  <==" or ""
					if b and b > 0 and U.buf_valid(b) then
						table.insert(out, string.format("%3d  %s  #%d  %s%s", i, pin_tag, b, path, here))
					else
						table.insert(out, string.format("%3d  %s  (closed)  %s%s", i, pin_tag, path, here))
					end
				end
			end
			vim.notify(#out > 0 and table.concat(out, "\n") or "MRU ring: empty")
		end, { force = true })

		apply_keymaps()
		return M
	end
end
