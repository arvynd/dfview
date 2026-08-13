local M = {}

local LAYOUTS = { tab = true, float = true, vsplit = true }

M.state = {
	buf = nil,
	win = nil,
	tab = nil,
	layout = nil,
	job = nil,
}

local function buf_is_valid()
	return M.state.buf ~= nil and vim.api.nvim_buf_is_valid(M.state.buf)
end

local function win_is_valid()
	return M.state.win ~= nil and vim.api.nvim_win_is_valid(M.state.win)
end

local function tab_is_valid()
	return M.state.tab ~= nil and vim.api.nvim_tabpage_is_valid(M.state.tab)
end

local function is_open()
	if not buf_is_valid() then
		return false
	end
	if M.state.layout == "tab" then
		return tab_is_valid()
	end
	return win_is_valid()
end

local function focus()
	if M.state.layout == "tab" then
		vim.api.nvim_set_current_tabpage(M.state.tab)
	else
		vim.api.nvim_set_current_win(M.state.win)
	end
end

local function reset_state()
	M.state.buf = nil
	M.state.win = nil
	M.state.tab = nil
	M.state.layout = nil
	M.state.job = nil
end

local function open(filepath, layout)
	local buf = vim.api.nvim_create_buf(true, true)

	if layout == "float" then
		local width = math.floor(vim.o.columns * 0.8)
		local height = math.floor(vim.o.lines * 0.8)
		M.state.win = vim.api.nvim_open_win(buf, true, {
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
		M.state.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(M.state.win, buf)
	else
		layout = "tab"
		M.state.tab = vim.api.nvim_open_tabpage(buf, true, {})
	end

	M.state.buf = buf
	M.state.layout = layout
	M.state.job = vim.fn.jobstart({ "visidata", filepath }, { term = true }) -- TODO :use on_exit for jobstart exit.
end

-- Focuses the existing viewer if one is open, otherwise opens `filepath` in `layout`.
function M.open_if_closed(filepath, layout)
	layout = LAYOUTS[layout] and layout or "tab"

	if is_open() then
		focus()
		return
	end

	open(filepath, layout)
end

-- Closes the currently open viewer, if any.
function M.close_if_open()
	if not is_open() then
		return
	end

	if M.state.layout == "tab" then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(M.state.tab)) do
			vim.api.nvim_win_close(win, true)
		end
	else
		vim.api.nvim_win_close(M.state.win, true)
	end

	if buf_is_valid() then
		vim.api.nvim_buf_delete(M.state.buf, { force = true })
	end

	reset_state()
end

-- Closes the viewer if open, otherwise opens `filepath` in `layout`.
function M.toggle(filepath, layout)
	if is_open() then
		M.close_if_open()
	else
		M.open_if_closed(filepath, layout)
	end
end

function M.dflens()
	M.toggle("/tmp/dflens_test.csv", "tab")
end

function M.open_viewer(opts)
	local filepath = opts.args -- unsplit, so filepaths with spaces survive
	local layout = "tab"

	local quote, quoted_path, rest_after_quote = opts.args:match("^([\"'])(.-)%1%s*(.-)%s*$") -- unwrap matching quotes
	if quote then
		filepath = quoted_path
		if LAYOUTS[rest_after_quote] then
			layout = rest_after_quote
		end
	else
		local rest, lastWord = opts.args:match("^(.-)%s+(%S+)$") -- split off the last whitespace-separated word as a possible layout keyword
		if rest and LAYOUTS[lastWord] then
			filepath = rest
			layout = lastWord
		end
	end

	M.open_if_closed(filepath, layout)
end

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("OpenDFLens", M.dflens, {})
	vim.api.nvim_create_user_command("OpenViewer", M.open_viewer, { nargs = "+" }) -- one or more arguments
	vim.api.nvim_create_user_command("CloseViewer", M.close_if_open, {})

	local keymap = opts.keymap or "<leader>hw"

	vim.keymap.set("n", keymap, M.dflens, {
		desc = "From Plugin",
		silent = true,
	})
end

return M
