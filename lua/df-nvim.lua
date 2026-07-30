local M = {}

function M.say_hello()
	print("Hello from neovim")
end

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("HelloWorld", M.say_hello, {})

	local keymap = opts.keymap or "<leader>hw"

	vim.keymap.set("n", keymap, M.say_hello, {
		desc = "From Plugin",
		silent = true,
	})
end

return M
