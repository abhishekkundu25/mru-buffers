return function(M, U)
	-- Optional Telescope integration.
	-- This is intentionally lazy/soft-dependent: requiring this plugin does not
	-- require Telescope unless the user calls `M.telescope()` / `:MRUTelescope`.

	local hl_ready = false
	local function setup_highlights()
		if hl_ready then
			return
		end
		local function link(group, target)
			vim.api.nvim_set_hl(0, group, { link = target, default = true })
		end
		link("MRUBuffersTelescopePin", "DiagnosticHint")
		link("MRUBuffersTelescopePath", "Normal")
		link("MRUBuffersTelescopeClosed", "Comment")
		link("MRUBuffersTelescopeModified", "DiagnosticWarn")
		link("MRUBuffersTelescopeGitAdd", "DiffAdd")
		link("MRUBuffersTelescopeGitDel", "DiffDelete")
		hl_ready = true
	end

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

		setup_highlights()

		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local tutils = require("telescope.utils")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		local show_git = M.git
			and M.git.enabled == true
			and M.git.show_in_telescope ~= false
			and type(M._git_stats_for_paths) == "function"
			and type(M._git_format_badge) == "function"

		local function make_finder()
			local results = collect_items()
			local git_map = nil
			if show_git then
				local paths = {}
				for _, it in ipairs(results) do
					if it and it.path then
						paths[#paths + 1] = it.path
					end
				end
				git_map = M._git_stats_for_paths(paths)
			end

			return finders.new_table({
				results = results,
				entry_maker = function(item)
					local path = item.path
					local bufnr = item.bufnr
					local pin_slot = type(M._pin_slot_for_path) == "function" and M._pin_slot_for_path(path) or nil
					local pin_tag = pin_slot and ("[" .. tostring(pin_slot) .. "]") or "   "
					local disp = select(1, tutils.transform_path(opts, path))
					local is_modified = bufnr and U.buf_valid(bufnr) and vim.bo[bufnr].modified
					local is_closed = not bufnr
					local suffix = is_modified and " [unsaved]" or (is_closed and "  [closed]" or "")

					local icon, icon_hl = tutils.get_devicons(path, opts.disable_devicons)
					icon = (type(icon) == "string" and icon ~= "") and icon or " "

					local git_badge, git_meta, git_add, git_del = "", nil, false, false
					if show_git then
						local abs = U.normalize_path(path)
						local st = abs and git_map and git_map[abs] or nil
						if st then
							git_add = (st.add or 0) > 0
							git_del = (st.del or 0) > 0
							git_badge, git_meta = M._git_format_badge(st.add or 0, st.del or 0)
						end
					end

					return {
						value = item,
						display = function(entry)
							local left_hl = entry.pin_slot and "MRUBuffersTelescopePin" or "TelescopeResultsNumber"
							local right_hl = entry.is_closed and "MRUBuffersTelescopeClosed"
								or (entry.is_modified and "MRUBuffersTelescopeModified" or "MRUBuffersTelescopePath")

							local parts = {}
							local highlights = {}
							local col = 0

							local function push(text)
								if not text or text == "" then
									return 0
								end
								parts[#parts + 1] = text
								local len = #text
								col = col + len
								return len
							end

							local function push_hl(text, hl)
								local start = col
								local len = push(text)
								if hl and len > 0 then
									highlights[#highlights + 1] = { { start, start + len }, hl }
								end
							end

							local pin = entry.pin_tag or "   "
							if #pin < 4 then
								pin = pin .. string.rep(" ", 4 - #pin)
							end
							push_hl(pin, left_hl)
							push(" ")

							if show_git and entry.git_badge and entry.git_badge ~= "" then
								local badge_start = col
								push(entry.git_badge)
								if entry.git_add and entry.git_meta and entry.git_meta.add then
									local s = badge_start + (entry.git_meta.add.start - 1)
									highlights[#highlights + 1] = { { s, s + entry.git_meta.add.len }, "MRUBuffersTelescopeGitAdd" }
								end
								if entry.git_del and entry.git_meta and entry.git_meta.del then
									local s = badge_start + (entry.git_meta.del.start - 1)
									highlights[#highlights + 1] = { { s, s + entry.git_meta.del.len }, "MRUBuffersTelescopeGitDel" }
								end
								push(" ")
							end

							push_hl(entry.icon, entry.icon_hl)
							push(" ")
							push_hl(entry.disp .. entry.suffix, right_hl)

							return table.concat(parts, ""), highlights
						end,
						ordinal = table.concat({ disp, path, pin_tag }, " "),
						path = path,
						bufnr = bufnr,
						disp = disp,
						suffix = suffix,
						pin_slot = pin_slot,
						pin_tag = pin_tag,
						icon = icon,
						icon_hl = icon_hl,
						git_badge = git_badge,
						git_meta = git_meta,
						git_add = git_add,
						git_del = git_del,
						is_closed = is_closed,
						is_modified = is_modified,
					}
				end,
			})
		end

		local function refresh_picker(prompt_bufnr, selected_path)
			local picker = action_state.get_current_picker(prompt_bufnr)
			if not picker then
				return
			end

			local row = picker.get_selection_row and picker:get_selection_row() or nil
			picker:refresh(make_finder(), { reset_prompt = false })

			-- Immediately restore the previous row to avoid visible jumps while the
			-- refreshed results are settling, then (below) refine by path.
			if row ~= nil and picker.set_selection then
				pcall(picker.set_selection, picker, row)
			end

			vim.defer_fn(function()
				local p = action_state.get_current_picker(prompt_bufnr) or picker
				if not p or p:is_done() then
					return
				end

				local target_row = row
				if selected_path and p.manager and p.get_row then
					for i = 1, p.manager:num_results() do
						local entry = p.manager:get_entry(i)
						if entry and entry.path == selected_path then
							target_row = p:get_row(i)
							break
						end
					end
				end

				if target_row ~= nil and p.set_selection then
					pcall(p.set_selection, p, target_row)
				end
			end, 25)
		end

		local function bulk_pin_top()
			if type(M._pin_slot_for_path) ~= "function" then
				return false
			end
			if type(M._first_free_pin_slot) ~= "function" then
				return false
			end
			if type(M._pin_path) ~= "function" then
				return false
			end

			local pinned = 0
			for _, it in ipairs(collect_items()) do
				if it and it.path and not M._pin_slot_for_path(it.path) then
					local free = M._first_free_pin_slot()
					if not free then
						break
					end
					M._pin_path(it.path, free, it.bufnr)
					pinned = pinned + 1
				end
			end

			if pinned > 0 and type(M._save_pins) == "function" then
				M._save_pins()
			end
			return pinned > 0
		end

		pickers
			.new(opts, {
				prompt_title = "MRU Buffers  x:pin  X:bulk-pin  c:close",
				finder = make_finder(),
				sorter = conf.generic_sorter(opts),
				-- Use Telescope's configured file previewer for broad compatibility
				-- across Telescope versions (avoids depending on internal utils).
				previewer = conf.file_previewer(opts),
				attach_mappings = function(prompt_bufnr, map)
					local function selected()
						local e = action_state.get_selected_entry()
						return e and e.value or nil
					end

					local function selected_path()
						local e = action_state.get_selected_entry()
						return e and e.value and e.value.path or nil
					end

					actions.select_default:replace(function()
						local item = selected()
						actions.close(prompt_bufnr)
						open_item(item)
					end)

					local function pin_action()
						local item = selected()
						if pin_toggle_item(item) then
							refresh_picker(prompt_bufnr, item and item.path or selected_path())
						end
					end

					local function bulk_pin_action()
						local path = selected_path()
						if bulk_pin_top() then
							refresh_picker(prompt_bufnr, path)
						end
					end

					local function close_action()
						local item = selected()
						local path = item and item.path or selected_path()

						-- `nvim_buf_delete` can behave inconsistently when invoked from a
						-- floating prompt window. Run the delete in the picker's origin
						-- window context without changing focus (so Telescope stays open).
						local picker = action_state.get_current_picker(prompt_bufnr)
						local origin_win = picker and picker.original_win_id or nil
						local ok_close, reason
						if origin_win and vim.api.nvim_win_is_valid(origin_win) then
							vim.api.nvim_win_call(origin_win, function()
								ok_close, reason = close_item(item)
							end)
						else
							ok_close, reason = close_item(item)
						end

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
						refresh_picker(prompt_bufnr, path)
					end

					map("n", "x", pin_action)
					map("i", "<C-x>", pin_action)
					map("n", "X", bulk_pin_action)
					map("n", "c", close_action)
					map("i", "<C-c>", close_action)
					return true
				end,
			})
			:find()
	end
end
