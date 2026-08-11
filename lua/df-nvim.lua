local M = {}

function M.dflens()
	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_open_tabpage(buf, true, {})
	local job = vim.fn.jobstart({ "visidata", "/tmp/dflens_test.csv" }, { term = true }) -- TODO :use on_exit foe jobstart exit.
end

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("OpenDFLens", M.dflens, {})

	local keymap = opts.keymap or "<leader>hw"

	vim.keymap.set("n", keymap, M.dflens, {
		desc = "From Plugin",
		silent = true,
	})
end

return M
