vim.opt.rtp:prepend(assert(vim.env.MRU_REPO))
local tmp = assert(vim.env.MRU_TEST_TMP)
local a, b = tmp .. "/project/a.txt", tmp .. "/other/b.txt"
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
M.setup({
	keymaps = false,
	scope = "cwd",
	persist_pins = true,
	persist_file = tmp .. "/pins.json",
	keep_closed = { persist = true, file = tmp .. "/mru.json" },
})
if vim.env.MRU_TEST_PHASE == "save" then
	vim.cmd.edit(a)
	M.pin(1)
	vim.cmd.edit(b)
	M.pin(2)
	eq(paths(M), { a }, "save view is scoped")
else
	eq(paths(M), { a }, "scoped history restored")
	vim.cmd.cd(tmp .. "/other")
	eq(paths(M), { b }, "other history restored")
	M.jump(2)
	eq(vim.api.nvim_buf_get_name(0), b, "restored pin reopens")
	M.setup({ scope = "global", keymaps = false })
	eq(paths(M), { b, a }, "all persisted history retained")
end
print("PASS persistence " .. vim.env.MRU_TEST_PHASE)
vim.cmd("qa!")
