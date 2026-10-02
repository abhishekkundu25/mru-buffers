vim.opt.rtp:prepend(assert(vim.env.MRU_REPO))
local tmp = assert(vim.env.MRU_TEST_TMP)
local a, b, d = tmp .. "/project/a.txt", tmp .. "/other/b.txt", tmp .. "/other/d.txt"
local function eq(actual, expected, label)
	assert(vim.deep_equal(actual, expected), label .. ": " .. vim.inspect(actual))
end
local function paths(M)
	local out = {}
	for _, item in ipairs(M.entries()) do
		out[#out + 1] = item.path
	end
	return out
end
local M = require("mru-buffers")
vim.cmd.cd(tmp .. "/project")
local relative_storage = vim.env.MRU_TEST_STORAGE == "relative"
local default_storage = vim.env.MRU_TEST_STORAGE == "default"
if vim.env.MRU_TEST_PHASE == "save" then
	-- These old shared files must never be read as directory-local state.
	vim.fn.mkdir(vim.fn.stdpath("data"), "p")
	vim.fn.writefile({ vim.json.encode({ pins = { ["1"] = { path = b } } }) }, tmp .. "/pins.json")
	vim.fn.writefile({ vim.json.encode({ list = { b } }) }, tmp .. "/mru.json")
	vim.fn.writefile(
		{ vim.json.encode({ pins = { ["1"] = { path = b } } }) },
		vim.fn.stdpath("data") .. "/mru-buffers-pins.json"
	)
	vim.fn.writefile({ vim.json.encode({ list = { b } }) }, vim.fn.stdpath("data") .. "/mru-buffers-mru.json")
end
M.setup({
	keymaps = false,
	persist_pins = true,
	persist_file = relative_storage and "pins.json" or (not default_storage and tmp .. "/pins.json" or nil),
	keep_closed = {
		persist = true,
		file = relative_storage and "mru.json" or (not default_storage and tmp .. "/mru.json" or nil),
	},
})
if vim.env.MRU_TEST_PHASE == "save" then
	eq(paths(M), {}, "old shared history is not loaded")
	M.jump(1)
	eq(vim.api.nvim_buf_get_name(0), "", "old shared pin is not loaded")
	vim.cmd.edit(a)
	M.pin(1)
	vim.cmd.cd(tmp .. "/other")
	vim.cmd.edit(b)
	M.pin(1)
	vim.cmd.edit(d)
	vim.cmd.cd(tmp .. "/project")
	eq(paths(M), { a }, "save view is scoped")
else
	eq(paths(M), { a }, "scoped history restored")
	vim.cmd.cd(tmp .. "/other")
	eq(paths(M), { d, b }, "other history including unpinned file restored")
	M.jump(1)
	eq(vim.api.nvim_buf_get_name(0), b, "restored pin reopens")
	vim.cmd.cd(tmp .. "/project")
	M.jump(1)
	eq(vim.api.nvim_buf_get_name(0), a, "original directory pin restored")
	eq(paths(M), { a }, "independent MRU restored")
end
print("PASS persistence " .. vim.env.MRU_TEST_STORAGE .. " " .. vim.env.MRU_TEST_PHASE)
vim.cmd("qa!")
