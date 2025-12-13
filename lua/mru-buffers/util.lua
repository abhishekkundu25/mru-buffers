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
