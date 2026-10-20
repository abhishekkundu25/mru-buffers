local U = {}

function U.buf_valid(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

function U.normalize_path(path)
	if not path or path == "" then
		return nil
	end
	return vim.fn.fnamemodify(path, ":p")
end

function U.keytrans(lhs)
	if not lhs or lhs == "" then
		return lhs
	end
	return vim.fn.keytrans(lhs)
end

-- Last content written per file, so saving unchanged state touches no disk.
local written = {}

-- Writes through a temp file and rename so a crash never leaves a truncated file.
function U.write_json(file, value)
	local encoded = vim.json.encode(value)
	if written[file] == encoded then
		return true
	end
	local ok = pcall(function()
		vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
		assert(vim.fn.writefile({ encoded }, file .. ".tmp") == 0)
		assert(os.rename(file .. ".tmp", file))
	end)
	if ok then
		written[file] = encoded
	end
	return ok
end

function U.read_json(file)
	if vim.fn.filereadable(file) ~= 1 then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
	return ok and type(decoded) == "table" and decoded or nil
end

return U
