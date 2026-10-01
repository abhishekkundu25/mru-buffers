for _, file in ipairs(vim.fn.glob(assert(vim.env.MRU_REPO) .. "/lua/**/*.lua", false, true)) do
	assert(loadfile(file))
end
print("PASS Lua syntax")
vim.cmd("qa!")
