vim.opt.rtp:prepend(vim.env.MRU_REPO or "/Users/abhishek/repos/mru-buffers")
local uv = vim.uv or vim.loop
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = uv.fs_realpath(tmp)
vim.fn.mkdir(tmp .. "/empty", "p")
local function file(name)
	local path = tmp .. "/" .. name
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile({ "line one", "line two", "line three" }, path)
	return path
end
local function eq(a, b, label)
	assert(vim.deep_equal(a, b), label .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end
local notifications = {}
vim.notify = function(msg)
	notifications[#notifications + 1] = msg
end
local M = require("mru-buffers")
local function paths()
	local out = {}
	for _, e in ipairs(M.entries()) do
		out[#out + 1] = e.path
	end
	return out
end
local function fresh(opts)
	if vim.bo.filetype == "mru-ring" then
		M.open_menu()
	end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) then
			vim.api.nvim_buf_delete(b, { force = true })
		end
	end
	vim.cmd("enew!")
	package.loaded["mru-buffers"] = nil
	M = require("mru-buffers")
	M.setup(
		vim.tbl_extend(
			"force",
			{ keymaps = false, scope = "global", keep_closed = false, commit_on_touch = true },
			opts or {}
		)
	)
	M.entries()
	notifications = {}
end
local a, b, c = file("project/a.txt"), file("project/sub/b.txt"), file("project-other/c.txt")
local cases = 0
local function test(name, fn)
	fn()
	cases = cases + 1
	print("PASS " .. name)
end

test("immediate commit and both cycle directions", function()
	fresh({ commit_on_touch = false })
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), a, "previous target")
	eq(paths(), { a, b }, "immediate head")
	M.next()
	eq(vim.api.nvim_buf_get_name(0), b, "next target")
	eq(paths(), { b, a }, "next immediate head")
end)
test("preview remains stable until real movement", function()
	fresh()
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	M.prev()
	eq(paths(), { b, a }, "preview does not reorder")
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	eq(paths(), { b, a }, "internal cursor event does not commit")
	vim.api.nvim_feedkeys("j", "xt", false)
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	eq(paths(), { a, b }, "real movement commits")
end)
test("cycle mappings preserve preview order", function()
	fresh({ keymaps = { prev = "H", next = "L", menu = false, pins = false } })
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	vim.api.nvim_feedkeys("HL", "xt", false)
	eq(vim.api.nvim_buf_get_name(0), b, "mapped next returns B")
	eq(paths(), { b, a }, "cycle mappings never commit")
end)
test("default multi-key cycle mappings preserve preview", function()
	fresh({ keymaps = true })
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	vim.api.nvim_feedkeys("[b]b", "xt", false)
	eq(vim.api.nvim_buf_get_name(0), b, "default mappings return B")
	eq(paths(), { b, a }, "multi-key cycling keeps order")
end)
test("closed history and pin retention", function()
	fresh({ keep_closed = true })
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	vim.api.nvim_buf_delete(vim.fn.bufnr(a, false), { force = false })
	eq(paths(), { b, a }, "closed history retained")
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), a, "closed history reopens")
	fresh()
	vim.cmd.edit(a)
	M.pin(1)
	vim.cmd.edit(b)
	vim.api.nvim_buf_delete(vim.fn.bufnr(a, false), { force = false })
	eq(paths(), { b, a }, "closed pin retained")
	M.unpin(1)
	eq(paths(), { b }, "unpin removes closed entry")
end)
test("menu pin and safe close actions", function()
	fresh()
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	M.open_menu()
	vim.api.nvim_feedkeys("x", "xt", false)
	vim.api.nvim_feedkeys("c", "xt", false)
	M.open_menu()
	M.jump(1)
	eq(vim.api.nvim_buf_get_name(0), b, "menu pin survives close")
	vim.api.nvim_buf_set_lines(0, 0, 1, false, { "modified" })
	M.open_menu()
	vim.api.nvim_feedkeys("c", "xt", false)
	assert(vim.api.nvim_buf_is_valid(vim.fn.bufnr(b, false)), "modified buffer is protected")
	M.open_menu()
	vim.bo.modified = false
	M.unpin(1)
end)
test("cwd scope, descendants, sibling prefix, directory changes", function()
	fresh({ scope = "cwd", keep_closed = true })
	vim.cmd.cd(tmp .. "/project")
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	vim.cmd.edit(c)
	eq(paths(), { b, a }, "local view")
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), b, "outside enters head")
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), a, "previous wraps locally")
	M.next()
	eq(vim.api.nvim_buf_get_name(0), b, "next wraps locally")
	M.open_menu()
	local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	assert(not text:find("project-other", 1, true), "menu excludes sibling")
	M.open_menu()
	vim.cmd.cd(tmp .. "/project-other")
	eq(paths(), { c }, "other project retained")
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), c, "single local entry")
	vim.cmd.cd(tmp .. "/empty") -- created below before running
	eq(paths(), {}, "empty local view")
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), c, "empty view leaves current unchanged")
end)
test("window-local cwd and root-directory scope", function()
	fresh({ scope = "cwd", keep_closed = true })
	vim.cmd.edit(a)
	vim.cmd.edit(c)
	vim.cmd.lcd(tmp .. "/project")
	eq(paths(), { a }, "window local cwd")
	vim.cmd.lcd("/")
	eq(paths(), { c, a }, "filesystem root matches absolute paths")
end)
test("pin reopening and modified-buffer protection", function()
	fresh()
	vim.cmd.edit(a)
	M.pin(1)
	vim.cmd.edit(b)
	local closed = vim.fn.bufnr(a, false)
	vim.api.nvim_buf_delete(closed, { force = false })
	M.jump(1)
	eq(vim.api.nvim_buf_get_name(0), a, "reopened pin")
	assert(vim.bo.buflisted, "pin is listed")
	eq(paths()[1], a, "pin commits")
	M.unpin(1)
	vim.o.hidden = false
	vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), a, "failed navigation keeps unsaved buffer")
	vim.bo.modified = false
	M.prev()
	eq(vim.api.nvim_buf_get_name(0), b, "navigation lock recovers after failure")
	vim.o.hidden = true
end)
test("menu selection opens and commits", function()
	fresh()
	vim.cmd.edit(a)
	vim.cmd.edit(b)
	M.open_menu()
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	local key = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(key, "xt", false)
	eq(vim.api.nvim_buf_get_name(0), a, "menu opens selected file")
	eq(paths(), { a, b }, "menu commit")
end)
test("lazy-load bootstrap and setup idempotence", function()
	fresh()
	vim.cmd.edit(a)
	M.setup({ keymaps = false })
	M.setup({ keymaps = false })
	eq(paths(), { a }, "setup seeds and retains one entry")
	local events = vim.api.nvim_get_autocmds({ group = "MRUBuffers", event = "BufEnter" })
	eq(#events, 1, "one enter callback after repeated setup")
end)
local deps = vim.env.MRU_TEST_PLUGINS
if deps then
	for _, name in ipairs({ "plenary.nvim", "telescope.nvim", "nvim-web-devicons" }) do
		vim.opt.rtp:append(deps .. "/" .. name)
	end
	local actions = require("telescope.actions")
	local state = require("telescope.actions.state")
	test("real Telescope scoped results and cancel preserve MRU", function()
		fresh({ scope = "cwd" })
		vim.cmd.cd(tmp .. "/project")
		vim.cmd.edit(a)
		vim.cmd.edit(b)
		vim.cmd.edit(c)
		local before = paths()
		M.telescope({ layout_strategy = "vertical", layout_config = { height = 0.9 }, previewer = false })
		local prompt = vim.api.nvim_get_current_buf()
		local picker = state.get_current_picker(prompt)
		assert(
			vim.wait(2000, function()
				return picker.manager and picker.manager:num_results() == 2
			end),
			"Telescope results ready"
		)
		local found = {}
		for i = 1, picker.manager:num_results() do
			found[#found + 1] = picker.manager:get_entry(i).path
		end
		table.sort(found)
		local expected = { a, b }
		table.sort(expected)
		eq(found, expected, "Telescope scoped results")
		actions.close(prompt)
		eq(vim.api.nvim_buf_get_name(0), c, "cancel restores origin")
		eq(paths(), before, "cancel preserves ring")
	end)
	test("real Telescope selection commits", function()
		fresh()
		vim.cmd.edit(a)
		vim.cmd.edit(b)
		M.telescope({ layout_strategy = "vertical", layout_config = { height = 0.9 }, previewer = false })
		local prompt = vim.api.nvim_get_current_buf()
		local picker = state.get_current_picker(prompt)
		assert(
			vim.wait(2000, function()
				return picker.manager and picker.manager:num_results() == 2
			end),
			"picker ready"
		)
		picker:set_selection(picker:get_row(2))
		actions.select_default(prompt)
		eq(vim.api.nvim_buf_get_name(0), a, "Telescope opens A")
		eq(paths(), { a, b }, "Telescope commits A")
	end)
end
print(string.format("PASS %d regression cases", cases))
vim.cmd.cd("/private/tmp")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
