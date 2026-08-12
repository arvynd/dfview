local M = {}

function M.dflens()
	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_open_tabpage(buf, true, {})
	local job = vim.fn.jobstart({ "visidata", "/tmp/dflens_test.csv" }, { term = true }) -- TODO :use on_exit for jobstart exit.
end

local LAYOUTS = { tab = true, float = true, vsplit = true }

function M.open_viewer(opts)
	local filepath = opts.args -- unsplit, so filepaths with spaces survive
	local layout = "tab"

	local rest, lastWord = opts.args:match("^(.-)%s+(%S+)$") -- split off the last whitespace-separated word as a possible layout keyword
	if rest and LAYOUTS[lastWord] then
		filepath = rest
		layout = lastWord
	end

	local buf = vim.api.nvim_create_buf(true, true)

	if layout == "float" then
		local width = math.floor(vim.o.columns * 0.8)
		local height = math.floor(vim.o.lines * 0.8)
		vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2), -- row/col are top-left corner, so center via leftover space
			col = math.floor((vim.o.columns - width) / 2),
			style = "minimal",
			border = "rounded",
		})
	elseif layout == "vsplit" then
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buf)
	else
		vim.api.nvim_open_tabpage(buf, true, {})
	end

	local job = vim.fn.jobstart({ "visidata", filepath }, { term = true }) -- TODO :use on_exit for jobstart exit.
end

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("OpenDFLens", M.dflens, {})
	vim.api.nvim_create_user_command("OpenViewer", M.open_viewer, { nargs = "+" }) -- one or more arguments

	local keymap = opts.keymap or "<leader>hw"

	vim.keymap.set("n", keymap, M.dflens, {
		desc = "From Plugin",
		silent = true,
	})
end

return M
