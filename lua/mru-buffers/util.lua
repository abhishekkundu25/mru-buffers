local U = {}

function U.buf_valid(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

function U.list_contains(t, v)
	for _, x in ipairs(t) do
		if x == v then
			return true
		end
	end
	return false
end

function U.normalize_path(path)
	if not path or path == "" then
		return nil
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function is_windows()
	return package.config:sub(1, 1) == "\\"
end

function U.joinpath(...)
	if vim.fs and vim.fs.joinpath then
		return vim.fs.joinpath(...)
	end
	local parts = { ... }
	local sep = is_windows() and "\\" or "/"
	local out = {}
	for _, p in ipairs(parts) do
		if type(p) == "string" and p ~= "" then
			out[#out + 1] = p:gsub(sep .. "+$", "")
		end
	end
	return table.concat(out, sep)
end

local function split_path(path)
	local sep = is_windows() and "\\" or "/"
	path = path:gsub(sep .. "+", sep)
	local out = {}
	for part in path:gmatch("[^" .. sep .. "]+") do
		out[#out + 1] = part
	end
	return out, sep
end

function U.relpath(path, root)
	path = U.normalize_path(path)
	root = U.normalize_path(root)
	if not path or not root then
		return nil
	end

	local sep = is_windows() and "\\" or "/"
	local norm_path = path:gsub(sep .. "+", sep)
	local norm_root = root:gsub(sep .. "+", sep):gsub(sep .. "+$", "")

	-- fast path: nested
	if norm_path:sub(1, #norm_root + 1) == norm_root .. sep then
		return norm_path:sub(#norm_root + 2)
	end
	if norm_path == norm_root then
		return "."
	end

	local path_parts = split_path(norm_path)
	local root_parts = split_path(norm_root)

	local i = 1
	while i <= #path_parts and i <= #root_parts and path_parts[i] == root_parts[i] do
		i = i + 1
	end

	local ups = {}
	for _ = i, #root_parts do
		ups[#ups + 1] = ".."
	end
	local rest = {}
	for j = i, #path_parts do
		rest[#rest + 1] = path_parts[j]
	end

	local rel_parts = {}
	for _, p in ipairs(ups) do
		rel_parts[#rel_parts + 1] = p
	end
	for _, p in ipairs(rest) do
		rel_parts[#rel_parts + 1] = p
	end

	return table.concat(rel_parts, sep)
end

function U.find_project_root(start_dir, markers)
	if type(start_dir) ~= "string" or start_dir == "" then
		return nil
	end
	if type(markers) ~= "table" or #markers == 0 then
		return nil
	end

	local dir = U.normalize_path(start_dir)
	if not dir then
		return nil
	end

	local ok, found = pcall(vim.fs.find, markers, { path = dir, upward = true })
	if not ok or type(found) ~= "table" or #found == 0 then
		return nil
	end

	local marker_path = found[1]
	if type(marker_path) ~= "string" or marker_path == "" then
		return nil
	end
	return U.normalize_path(vim.fn.fnamemodify(marker_path, ":p:h"))
end

function U.json_encode(v)
	if vim.json and vim.json.encode then
		return vim.json.encode(v)
	end
	return vim.fn.json_encode(v)
end

function U.json_decode(s)
	if vim.json and vim.json.decode then
		return vim.json.decode(s)
	end
	return vim.fn.json_decode(s)
end

function U.keytrans(lhs)
	if not lhs or lhs == "" then
		return lhs
	end
	return vim.fn.keytrans(lhs)
end

return U
