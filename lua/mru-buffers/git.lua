return function(M, U)
	-- Git diffstat (add/remove line counts) for files in the MRU list.
	-- Optional and disabled by default via `git.enabled = false`.
	local dir_roots = {} -- dir -> repo root with trailing slash, or false
	-- root -> { map = { [abs] = { add, del } }, ts = ms of last result, running = bool }
	local root_stats = {}

	local function now_ms()
		return math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
	end

	local function find_git_root(dir)
		if dir_roots[dir] == nil then
			local found = vim.fs.find(".git", { path = dir, upward = true })[1]
			-- Strip a trailing separator so `:h` yields the worktree, not `.git`.
			dir_roots[dir] = found and (vim.fn.fnamemodify((found:gsub("[/\\]+$", "")), ":h") .. "/") or false
		end
		return dir_roots[dir] or nil
	end

	-- `git diff --numstat` reports renames as "old => new" or "dir/{old => new}/file".
	local function renamed_path(p)
		local pre, new, suf = p:match("^(.-){.-%s=>%s(.-)}(.*)$")
		if pre then
			return pre .. new .. suf
		end
		return p:match("^.-%s=>%s(.+)$") or p
	end

	local function parse_numstat(root, lines)
		local map = {}
		for _, line in ipairs(lines) do
			-- Binary files report "-\t-\tfile" and count as zero lines.
			local a, d, file = line:match("^([%d-]+)\t([%d-]+)\t(.+)$")
			if file then
				map[U.normalize_path(root .. renamed_path(file))] = { add = tonumber(a) or 0, del = tonumber(d) or 0 }
			end
		end
		return map
	end

	-- One diff covers both options: working tree vs index, index vs HEAD, or
	-- working tree vs HEAD (no double count for lines staged then edited again).
	local function diff_args()
		local unstaged, staged = M.git.include_unstaged ~= false, M.git.include_staged == true
		return unstaged and staged and { "HEAD" } or staged and { "--cached" } or unstaged and {} or nil
	end

	-- Runs at most one `git diff` per repo in the background and redraws the
	-- open menu/picker once, only when the counts changed.
	local function refresh(root, stats)
		local args = diff_args()
		if not args then
			stats.map, stats.ts = {}, now_ms()
			return
		end
		local lines = {}
		stats.running = true
		local job = vim.fn.jobstart(vim.list_extend({ "git", "-C", root, "diff", "--numstat" }, args), {
			stdout_buffered = true,
			on_stdout = function(_, data)
				lines = data
			end,
			on_exit = function(_, code)
				-- A failed diff (e.g. no HEAD before the first commit) shows no counts.
				local map = code == 0 and parse_numstat(root, lines) or {}
				stats.running, stats.ts = false, now_ms()
				if not vim.deep_equal(map, stats.map) then
					stats.map = map
					M._refresh_menu()
					M._refresh_picker()
				end
			end,
		})
		if job <= 0 then
			stats.running, stats.ts = false, now_ms()
		end
	end

	-- Never waits on git: returns the cached counts and refreshes them when stale.
	local function root_map(root)
		local stats = root_stats[root]
		if not stats then
			stats = { map = {}, ts = -math.huge }
			root_stats[root] = stats
		end
		if not stats.running and now_ms() - stats.ts >= (tonumber(M.git.refresh_ms) or 0) then
			refresh(root, stats)
		end
		return stats.map
	end

	-- Returns the cached { [path] = { add, del } } for changed paths, one git job per repo.
	local function stats_for_paths(paths)
		local out = {}
		for _, path in ipairs(paths) do
			local root = find_git_root(vim.fn.fnamemodify(path, ":h"))
			local st = root and root_map(root)[path]
			if st and (st.add > 0 or st.del > 0) then
				out[path] = st
			end
		end
		return out
	end

	local function abbrev(n)
		if n < 1000 then
			return tostring(n)
		end
		if n < 10000 then
			return ("%.1fk"):format(math.floor(n / 100) / 10)
		end
		return math.floor(n / 1000) .. "k"
	end

	-- "+12 -3" plus 1-based byte ranges of each token for highlighting.
	local function format_badge(add, del)
		local col = M.git.column
		local add_tok = add > 0 and (col.add_prefix .. abbrev(add)) or nil
		local del_tok = del > 0 and (col.del_prefix .. abbrev(del)) or nil
		local meta = {}
		if add_tok then
			meta.add = { start = 1, len = #add_tok }
		end
		if del_tok then
			meta.del = { start = add_tok and #add_tok + 2 or 1, len = #del_tok }
		end
		local badge = add_tok and del_tok and (add_tok .. " " .. del_tok) or add_tok or del_tok or ""
		return badge, meta
	end

	M._git_stats_for_paths = stats_for_paths
	M._git_format_badge = format_badge
end
