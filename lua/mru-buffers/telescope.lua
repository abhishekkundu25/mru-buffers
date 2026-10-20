return function(M, U)
	-- Optional Telescope picker over `M.entries()`. Telescope is only required
	-- when `M.telescope()` / `:MRUTelescope` runs.

	local function setup_highlights()
		for group, target in pairs({
			MRUBuffersTelescopePin = "DiagnosticHint",
			MRUBuffersTelescopePath = "Normal",
			MRUBuffersTelescopeClosed = "Comment",
			MRUBuffersTelescopeModified = "DiagnosticWarn",
			MRUBuffersTelescopeGitAdd = "DiffAdd",
			MRUBuffersTelescopeGitDel = "DiffDelete",
		}) do
			vim.api.nvim_set_hl(0, group, { link = target, default = true })
		end
	end

	-- Set while a picker is open so background git results can redraw it.
	local refresh_open_picker = function() end
	function M._refresh_picker()
		refresh_open_picker()
	end

	function M.telescope(opts)
		M._picker_origin_win = vim.api.nvim_get_current_win()
		opts = opts or {}
		if not pcall(require, "telescope") then
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

		local function make_entry(item, stats)
			local path, bufnr = item.path, item.bufnr
			local slot = M._pin_slot_for_path(path)
			local pin = slot and ("[" .. slot .. "] ") or "    "
			local rel = vim.fn.fnamemodify(path, ":~:.")
			local icon, icon_hl = tutils.get_devicons(path, opts.disable_devicons)
			icon = (icon and icon ~= "") and icon or " "
			local modified = bufnr and vim.bo[bufnr].modified
			local status = not bufnr and "  [closed]" or modified and " [unsaved]" or ""
			local name_hl = not bufnr and "MRUBuffersTelescopeClosed"
				or modified and "MRUBuffersTelescopeModified"
				or "MRUBuffersTelescopePath"
			local st = stats[path]
			local badge, ranges = "", {}
			if st then
				badge, ranges = M._git_format_badge(st.add, st.del)
				badge = " [" .. badge .. "]"
			end

			return {
				value = item,
				path = path,
				ordinal = table.concat({ rel, path, slot and ("[" .. slot .. "]") or "   " }, " "),
				display = function()
					-- `transform_path` needs the picker layout, so it runs at display time.
					local ok, name = pcall(tutils.transform_path, opts, path)
					name = (ok and type(name) == "string" and name ~= "") and name or rel
					local name_col = #pin + 1 + #icon + 1
					local hls = {
						{ { 0, #pin }, slot and "MRUBuffersTelescopePin" or "TelescopeResultsNumber" },
						{ { name_col, name_col + #name + #badge + #status }, name_hl },
					}
					if icon_hl then
						table.insert(hls, { { #pin + 1, #pin + 1 + #icon }, icon_hl })
					end
					for key, group in pairs({ add = "MRUBuffersTelescopeGitAdd", del = "MRUBuffersTelescopeGitDel" }) do
						local r = ranges[key]
						if r then
							local s = name_col + #name + 2 + r.start - 1 -- after " ["
							hls[#hls + 1] = { { s, s + r.len }, group }
						end
					end
					return pin .. " " .. icon .. " " .. name .. badge .. status, hls
				end,
			}
		end

		local function make_finder()
			local items = M.entries()
			local stats = {}
			if M.git.enabled == true and M.git.show_in_telescope ~= false then
				stats = M._git_stats_for_paths(vim.tbl_map(function(it)
					return it.path
				end, items))
			end
			return finders.new_table({
				results = items,
				entry_maker = function(item)
					return make_entry(item, stats)
				end,
			})
		end

		local function refresh_picker(prompt_bufnr, path)
			local picker = action_state.get_current_picker(prompt_bufnr)
			local row = picker:get_selection_row()
			picker:refresh(make_finder(), { reset_prompt = false })
			-- Hold the row while results settle, then follow the entry by path.
			pcall(picker.set_selection, picker, row)
			vim.defer_fn(function()
				if picker:is_done() or not picker.manager then
					return
				end
				for i = 1, picker.manager:num_results() do
					if picker.manager:get_entry(i).path == path then
						row = picker:get_row(i)
						break
					end
				end
				pcall(picker.set_selection, picker, row)
			end, 25)
		end

		pickers
			.new(opts, {
				prompt_title = "MRU Buffers  x/<M-x>:pin  X:bulk-pin  c/<M-c>:close",
				finder = make_finder(),
				sorter = conf.generic_sorter(opts),
				previewer = conf.file_previewer(opts),
				attach_mappings = function(prompt_bufnr, map)
					local function selected()
						local entry = action_state.get_selected_entry()
						return entry and entry.value
					end

					refresh_open_picker = function()
						if vim.api.nvim_buf_is_valid(prompt_bufnr) then
							local item = selected()
							refresh_picker(prompt_bufnr, item and item.path)
						end
					end

					actions.select_default:replace(function()
						local item = selected()
						actions.close(prompt_bufnr)
						if item and not M._navigation.open(item, false) then
							vim.notify("MRU: failed to open entry", vim.log.levels.WARN)
						end
					end)

					local function pin_action()
						local item = selected()
						if item and M._toggle_pin(item) then
							refresh_picker(prompt_bufnr, item.path)
						end
					end

					local function bulk_pin_action()
						local item = selected()
						if M._pin_top(M.entries()) then
							refresh_picker(prompt_bufnr, item and item.path)
						end
					end

					local function close_action()
						local item = selected()
						local win = action_state.get_current_picker(prompt_bufnr).original_win_id
						if item and M._close_if_saved(item, win) then
							refresh_picker(prompt_bufnr, item.path)
						end
					end

					map("n", "x", pin_action)
					-- Insert-mode keys avoid Telescope's defaults (<C-x> split, <C-c> close).
					map("i", "<M-x>", pin_action)
					map("n", "X", bulk_pin_action)
					map("n", "c", close_action)
					map("i", "<M-c>", close_action)
					return true
				end,
			})
			:find()
	end
end
