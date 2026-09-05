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

-- Splits a raw, unsplit command-arg string into (value, layout), where layout
-- is an optional trailing keyword (quoted or not) from LAYOUTS.
local function parse_arg_and_layout(raw)
	local value = raw
	local layout = "tab"

	local quote, quoted_value, rest_after_quote = raw:match("^([\"'])(.-)%1%s*(.-)%s*$") -- unwrap matching quotes
	if quote then
		value = quoted_value
		if LAYOUTS[rest_after_quote] then
			layout = rest_after_quote
		end
	else
		local rest, lastWord = raw:match("^(.-)%s+(%S+)$") -- split off the last whitespace-separated word as a possible layout keyword
		if rest and LAYOUTS[lastWord] then
			value = rest
			layout = lastWord
		end
	end

	return value, layout
end

function M.open_viewer(opts)
	local filepath, layout = parse_arg_and_layout(opts.args) -- unsplit, so filepaths with spaces survive
	M.open_if_closed(filepath, layout)
end

-- :DfInspect <python expr> [layout] — evaluates `expr` in the current paused
-- debug frame, serializes it to a temp CSV, and opens that in the viewer.
function M.dap_inspect(opts)
	local expression, layout = parse_arg_and_layout(opts.args)
	require("df-nvim.dap").inspect(expression, layout)
end

-- Reads the variable name off the current line in a dap-ui Scopes/Watches
-- buffer and inspects it the same way :DfInspect would.
function M.dap_inspect_cursor(layout)
	local line = vim.api.nvim_get_current_line()
	-- dap-ui renders variables as "<indent/icon> name: value"; strip everything
	-- up to the first identifier-looking token before the colon.
	local name = line:match("^%s*[^%w_]-([%w_][%w_.%[%]]*)%s*:")
	if not name then
		vim.notify("df-nvim: no variable found on this line", vim.log.levels.WARN)
		return
	end
	require("df-nvim.dap").inspect(name, layout)
end

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("OpenDFLens", M.dflens, {})
	vim.api.nvim_create_user_command("OpenViewer", M.open_viewer, { nargs = "+" }) -- one or more arguments
	vim.api.nvim_create_user_command("CloseViewer", M.close_if_open, {})

	if opts.dap ~= false and pcall(require, "dap") then
		vim.api.nvim_create_user_command("DfInspect", M.dap_inspect, { nargs = "+" })

		if pcall(require, "dapui") then
			local inspect_keymap = opts.dap_inspect_keymap or "gd"
			vim.api.nvim_create_autocmd("FileType", {
				pattern = { "dapui_scopes", "dapui_watches" },
				callback = function(args)
					vim.keymap.set("n", inspect_keymap, function()
						M.dap_inspect_cursor()
					end, { buffer = args.buf, silent = true, desc = "Inspect dataframe in VisiData" })
				end,
			})
		end
	end

	local keymap = opts.keymap or "<leader>hw"

	vim.keymap.set("n", keymap, M.dflens, {
		desc = "From Plugin",
		silent = true,
	})
end

return M
