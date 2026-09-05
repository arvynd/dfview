local M = {}

local SERIALIZERS = {
	pandas = function(expr, path)
		return string.format('%s.to_csv(r"%s")', expr, path)
	end,
	polars = function(expr, path)
		return string.format('%s.write_csv(r"%s")', expr, path)
	end,
}

local function get_session_and_frame()
	local ok, dap = pcall(require, "dap")
	if not ok then
		return nil, nil, "nvim-dap is not installed"
	end

	local session = dap.session()
	if not session then
		return nil, nil, "no active debug session"
	end

	local frame = session.current_frame
	if not frame then
		return nil, nil, "debug session is not paused at a frame"
	end

	return session, frame.id, nil
end

local function evaluate(session, frame_id, expression, callback)
	session:request("evaluate", {
		expression = expression,
		frameId = frame_id,
		context = "repl",
	}, function(err, response)
		if err then
			callback(nil, err.message or vim.inspect(err))
			return
		end
		callback(response, nil)
	end)
end

local function temp_csv_path()
	local dir = vim.fn.stdpath("cache") .. "/df-nvim"
	vim.fn.mkdir(dir, "p")
	return string.format("%s/%d.csv", dir, vim.loop.hrtime())
end

-- Evaluates `expression` in the current paused debug frame, serializes the
-- result to a temp CSV (pandas/polars only), and opens it in the viewer.
function M.inspect(expression, layout)
	local session, frame_id, err = get_session_and_frame()
	if not session then
		vim.notify("df-nvim: " .. err, vim.log.levels.ERROR)
		return
	end

	evaluate(session, frame_id, string.format('type(%s).__module__.split(".")[0]', expression), function(response, eval_err)
		if eval_err then
			vim.notify("df-nvim: failed to evaluate '" .. expression .. "': " .. eval_err, vim.log.levels.ERROR)
			return
		end

		local kind = response.result and response.result:gsub("^['\"]", ""):gsub("['\"]$", "")
		local serialize = SERIALIZERS[kind]
		if not serialize then
			vim.notify(
				string.format("df-nvim: '%s' is not a supported dataframe (got %s)", expression, kind or "unknown"),
				vim.log.levels.ERROR
			)
			return
		end

		local path = temp_csv_path()
		evaluate(session, frame_id, serialize(expression, path), function(_, serialize_err)
			if serialize_err then
				vim.notify("df-nvim: failed to serialize '" .. expression .. "': " .. serialize_err, vim.log.levels.ERROR)
				return
			end

			require("df-nvim").open_if_closed(path, layout)
		end)
	end)
end

return M
