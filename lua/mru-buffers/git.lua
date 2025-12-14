return function(M, U)
	-- Git diffstat (add/remove line counts) for files in the MRU list.
	-- Optional and disabled by default via `git.enabled = false`.

	M.git = M.git
		or {
			enabled = false,
			include_unstaged = true,
			include_staged = true,
			show_in_menu = true,
			show_in_telescope = true,
			refresh_ms = 1500,
			column = {
				add_prefix = "+",
				del_prefix = "-",
				cell_width = 5, -- width per cell, including prefix (e.g. "+12  ")
				sep = " ",
			},
		}

	M._git_cache = M._git_cache or { roots = {}, dir_roots = {} }

	local function now_ms()
		-- `reltimefloat` is present in 0.9+ and doesn't require libuv hrtime.
		return math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
	end

	local function normalize_root(path)
		path = U.normalize_path(path)
		if not path then
			return nil
		end
		-- ensure trailing slash for stable join/display
		if path:sub(-1) ~= "/" then
			path = path .. "/"
		end
		return path
	end

	local function find_git_root_for_dir(dir)
		dir = U.normalize_path(dir)
		if not dir then
			return nil
		end

		local cached = M._git_cache.dir_roots[dir]
		if cached ~= nil then
			return cached or nil
		end

		local root = nil
		if vim.fs and vim.fs.find then
			local ok, found = pcall(vim.fs.find, ".git", { path = dir, upward = true })
			if ok and type(found) == "table" and #found > 0 and type(found[1]) == "string" then
				root = normalize_root(vim.fn.fnamemodify(found[1], ":p:h"))
			end
		end

		M._git_cache.dir_roots[dir] = root or false
		return root
	end

	local function joinpath(a, b)
		if vim.fs and vim.fs.joinpath then
			return vim.fs.joinpath(a, b)
		end
		if a:sub(-1) == "/" then
			return a .. b
		end
		return a .. "/" .. b
	end

	local function parse_renamed_path(p)
		-- Handle common rename formats:
		--  - "old => new"
		--  - "dir/{old => new}/file"
		--  - "{old => new}"
		if not p or p == "" then
			return p
		end

		local pre, old_mid, new_mid, suf = p:match("^(.-){(.-)%s=>%s(.-)}(.*)$")
		if pre then
			return pre .. new_mid .. suf
		end

		local _, _, rhs = p:find("^.-%s=>%s(.*)$")
		if rhs and rhs ~= "" then
			return rhs
		end

		return p
	end

	local function parse_numstat(lines, root)
		local out = {}
		root = normalize_root(root)
		if not (root and type(lines) == "table") then
			return out
		end

		for _, line in ipairs(lines) do
			if type(line) == "string" and line ~= "" then
				local a, d, file = line:match("^(%d+)\t(%d+)\t(.+)$")
				if not a then
					-- binary files show "-\t-\tfile"
					a, d, file = line:match("^%-%\t%-%\t(.+)$")
				end
				if file then
					file = parse_renamed_path(file)
					local abs = U.normalize_path(joinpath(root, file))
					if abs then
						local prev = out[abs] or { add = 0, del = 0 }
						out[abs] = prev
						if a and d then
							prev.add = prev.add + tonumber(a)
							prev.del = prev.del + tonumber(d)
						end
					end
				end
			end
		end

		return out
	end

	local function systemlist(cmd)
		local ok, lines = pcall(vim.fn.systemlist, cmd)
		if not ok or vim.v.shell_error ~= 0 or type(lines) ~= "table" then
			return nil
		end
		return lines
	end

	local function collect_root_stats(root)
		local cache = M._git_cache.roots[root]
		local refresh_ms = tonumber(M.git and M.git.refresh_ms) or 0
		if cache and refresh_ms > 0 and (now_ms() - cache.ts) < refresh_ms then
			return cache.map
		end

		-- Not a git repo (no .git found)
		if not root then
			return {}
		end

		local map = {}

		if M.git.include_unstaged ~= false then
			local lines = systemlist({ "git", "-C", root, "diff", "--numstat" })
			if lines then
				for abs, st in pairs(parse_numstat(lines, root)) do
					map[abs] = map[abs] or { add = 0, del = 0 }
					map[abs].add = map[abs].add + (st.add or 0)
					map[abs].del = map[abs].del + (st.del or 0)
				end
			end
		end

		if M.git.include_staged == true then
			local lines = systemlist({ "git", "-C", root, "diff", "--cached", "--numstat" })
			if lines then
				for abs, st in pairs(parse_numstat(lines, root)) do
					map[abs] = map[abs] or { add = 0, del = 0 }
					map[abs].add = map[abs].add + (st.add or 0)
					map[abs].del = map[abs].del + (st.del or 0)
				end
			end
		end

		M._git_cache.roots[root] = { ts = now_ms(), map = map }
		return map
	end

	local function stats_for_paths(paths)
		if not (M.git and M.git.enabled == true) then
			return {}
		end
		if type(paths) ~= "table" then
			return {}
		end

		-- group requested files by repo root to avoid running git per file
		local by_root = {}
		for _, p in ipairs(paths) do
			if type(p) == "string" and p ~= "" then
				local abs = U.normalize_path(p)
				if abs then
					local dir = vim.fn.fnamemodify(abs, ":p:h")
					local root = find_git_root_for_dir(dir)
					if root then
						by_root[root] = by_root[root] or {}
						table.insert(by_root[root], abs)
					end
				end
			end
		end

		local out = {}
		for root, abs_paths in pairs(by_root) do
			local root_map = collect_root_stats(root)
			for _, abs in ipairs(abs_paths) do
				local st = root_map[abs]
				if st and ((st.add or 0) > 0 or (st.del or 0) > 0) then
					out[abs] = { add = st.add or 0, del = st.del or 0 }
				end
			end
		end

		return out
	end

	local function format_cells(add, del)
		local col = M.git and M.git.column or {}
		local cell_w = tonumber(col.cell_width) or 5
		local add_prefix = col.add_prefix or "+"
		local del_prefix = col.del_prefix or "-"
		local sep = col.sep or " "

		local function cell(prefix, n)
			if not n or n <= 0 then
				return string.rep(" ", cell_w)
			end
			local s = prefix .. tostring(n)
			if #s < cell_w then
				s = s .. string.rep(" ", cell_w - #s)
			end
			return s
		end

		local a = cell(add_prefix, add)
		local d = cell(del_prefix, del)
		return a .. sep .. d, { cell_w = cell_w, sep = sep, add_len = #a, del_len = #d }
	end

	M._git_find_root_for_dir = find_git_root_for_dir
	M._git_stats_for_paths = stats_for_paths
	M._git_format_cells = format_cells
end

