vim.opt.rtp:prepend(assert(vim.env.MRU_REPO))
local M = require("mru-buffers")
vim.notify = function() end
M.setup({
	keymaps = false,
	max = 80,
	keep_closed = true,
	git = { enabled = false },
	ui = { fancy = true, show_icons = false },
})
for i = 1, 80 do
	local b = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(b, "/private/tmp/mru-benchmark/file-" .. i .. ".txt")
	vim.api.nvim_set_current_buf(b)
end
local uv = vim.uv or vim.loop
local function bench(name, n, fn)
	for _ = 1, 10 do
		fn()
	end
	local samples = {}
	for _ = 1, 7 do
		collectgarbage("collect")
		local start = uv.hrtime()
		for _ = 1, n do
			fn()
		end
		samples[#samples + 1] = (uv.hrtime() - start) / 1e6 / n
	end
	table.sort(samples)
	print(string.format("%s median=%.4f ms/op max=%.4f ms/op n=%d", name, samples[4], samples[7], n))
end
bench("cycle (80 open entries)", 200, function()
	M.prev()
end)
bench("MRURing (80 open entries)", 200, function()
	vim.cmd.MRURing()
end)
bench("menu open+close (80 entries)", 30, function()
	M.open_menu()
	M.open_menu()
end)
-- Unrelated named buffers must not make the capped MRU view expensive.
for i = 81, 1000 do
	local b = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(b, "/private/tmp/mru-benchmark/file-" .. i .. ".txt")
end
bench("cycle (1000 buffers; capped ring80)", 50, function()
	M.prev()
end)
vim.cmd("qa!")
