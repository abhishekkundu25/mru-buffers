return function(M, U)
	-- Optional Telescope integration.
	-- This is intentionally lazy/soft-dependent: requiring this plugin does not
	-- require Telescope unless the user calls `M.telescope()` / `:MRUTelescope`.

	local function collect_items()
		if type(M._prune) == "function" then
			M._prune()
		end

		local items = {}
		for _, path in ipairs(M._list or {}) do
			if type(path) == "string" and path ~= "" then
				local b = vim.fn.bufnr(path, false)
				local is_real = b and b > 0 and U.buf_valid(b) and type(M._buf_real) == "function" and M._buf_real(b)
				local pinned = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) ~= nil
				if is_real or pinned then
					table.insert(items, { path = path, bufnr = is_real and b or nil })
				end
			end
		end
		return items
	end

	local function open_item(item)
		if not (item and item.path) then
			return
		end

		if item.bufnr and U.buf_valid(item.bufnr) then
			vim.cmd(("buffer %d"):format(item.bufnr))
			if type(M._normalize_file_buffer) == "function" then
				M._normalize_file_buffer(item.bufnr)
			end
			return
		end

		pcall(vim.cmd, ("badd %s"):format(vim.fn.fnameescape(item.path)))
		local b = vim.fn.bufnr(item.path, false)
		if b and b > 0 and U.buf_valid(b) then
			vim.cmd(("buffer %d"):format(b))
			if type(M._normalize_file_buffer) == "function" then
				M._normalize_file_buffer(b)
			end
			return
		end

		pcall(vim.cmd, ("edit %s"):format(vim.fn.fnameescape(item.path)))
		if type(M._normalize_file_buffer) == "function" then
			M._normalize_file_buffer(vim.api.nvim_get_current_buf())
		end
	end

	local function close_item(item)
		if not (item and item.path) then
			return false, "invalid"
		end
		local bufnr = item.bufnr
		if not (bufnr and U.buf_valid(bufnr)) then
			local b = vim.fn.bufnr(item.path, false)
			bufnr = (b and b > 0 and U.buf_valid(b)) and b or nil
		end
		if not bufnr then
			return false, "closed"
		end
		if vim.bo[bufnr].modified then
			return false, "modified"
		end
		local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
		return ok, ok and "closed" or "failed"
	end

	local function pin_toggle_item(item)
		if not (item and item.path) then
			return false
		end
		if type(M._pin_slot_for_path) ~= "function" then
			return false
		end

		local slot = M._pin_slot_for_path(item.path)
		if slot then
			if type(M.unpin) == "function" then
				M.unpin(slot)
			end
			return true
		end

		local free = type(M._first_free_pin_slot) == "function" and M._first_free_pin_slot() or nil
		if not free then
			vim.notify(("MRU: no free pin slots (1-%d)"):format(M.pin_slots), vim.log.levels.WARN)
			return false
		end
		if type(M._pin_path) == "function" then
			M._pin_path(item.path, free, item.bufnr)
		end
		if type(M._save_pins) == "function" then
			M._save_pins()
		end
		return true
	end

	function M.telescope(opts)
		opts = opts or {}

		local ok_t, telescope = pcall(require, "telescope")
		if not ok_t or not telescope then
			vim.notify("MRU: Telescope not found", vim.log.levels.WARN)
			return
		end

		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local previewers = require("telescope.previewers")
		local putils = require("telescope.previewers.utils")
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		local function make_finder()
			local results = collect_items()
			return finders.new_table({
				results = results,
				entry_maker = function(item)
					local path = item.path
					local bufnr = item.bufnr
					local pin_slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) or nil
					local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
					local disp = vim.fn.fnamemodify(path, ":~:.")
					local suffix = ""
					if bufnr and U.buf_valid(bufnr) and vim.bo[bufnr].modified then
						suffix = " ●"
					elseif not bufnr then
						suffix = "  [closed]"
					end
					local display = string.format("%s  %s%s", pin_tag, disp, suffix)

					return {
						value = item,
						display = display,
						ordinal = disp,
						path = path,
						bufnr = bufnr,
					}
				end,
			})
		end

		local function refresh_picker(prompt_bufnr)
			local picker = action_state.get_current_picker(prompt_bufnr)
			picker:refresh(make_finder(), { reset_prompt = false })
		end

		pickers
			.new(opts, {
				prompt_title = "MRU Buffers",
				finder = make_finder(),
				sorter = conf.generic_sorter(opts),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						if entry and entry.path and entry.path ~= "" then
							putils.buffer_previewer_maker(entry.path, self.state.bufnr, { bufname = self.state.bufname })
						end
					end,
				}),
				attach_mappings = function(prompt_bufnr, map)
					local function selected()
						local e = action_state.get_selected_entry()
						return e and e.value or nil
					end

					actions.select_default:replace(function()
						local item = selected()
						actions.close(prompt_bufnr)
						open_item(item)
					end)

					local function pin_action()
						local item = selected()
						if pin_toggle_item(item) then
							refresh_picker(prompt_bufnr)
						end
					end

					local function close_action()
						local item = selected()
						local ok_close, reason = close_item(item)
						if not ok_close then
							if reason == "modified" then
								vim.notify("MRU: buffer has unsaved changes", vim.log.levels.WARN)
							elseif reason == "closed" then
								vim.notify("MRU: buffer already closed", vim.log.levels.INFO)
							else
								vim.notify("MRU: failed to close buffer", vim.log.levels.WARN)
							end
							return
						end
						refresh_picker(prompt_bufnr)
					end

					map("n", "x", pin_action)
					map("i", "<C-x>", pin_action)
					map("n", "c", close_action)
					map("i", "<C-c>", close_action)
					return true
				end,
			})
			:find()
	end
end

