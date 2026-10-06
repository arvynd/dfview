local M = {}

M.config = {
	format = "auto", -- "parquet", "csv", or "auto" (parquet, falling back to csv)
}

-- Python method used to write each supported dataframe kind, per file format.
local WRITERS = {
	parquet = { pandas = "to_parquet", polars = "write_parquet" },
	csv = { pandas = "to_csv", polars = "write_csv" },
}

-- Formats to try, in order, for each `format` option value.
local FORMAT_ORDER = {
	auto = { "parquet", "csv" },
	parquet = { "parquet" },
	csv = { "csv" },
}

M.FORMATS = FORMAT_ORDER

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

local function temp_path(ext)
	local dir = vim.fn.stdpath("cache") .. "/df-nvim"
	vim.fn.mkdir(dir, "p")
	return string.format("%s/%d.%s", dir, vim.loop.hrtime(), ext)
end

-- Writes `expression` to a temp file, trying each format from M.config.format
-- in order until one succeeds. Calls back with (path, nil) or (nil, err).
local function write_frame(session, frame_id, kind, expression, callback)
	local formats = FORMAT_ORDER[M.config.format] or FORMAT_ORDER.auto

	local function try(i)
		local ext = formats[i]
		local path = temp_path(ext)
		local code = string.format('%s.%s(r"%s")', expression, WRITERS[ext][kind], path)
		evaluate(session, frame_id, code, function(_, err)
			if not err then
				callback(path, nil)
			elseif i < #formats then
				vim.notify(
					string.format("df-nvim: %s write failed (%s), falling back to %s", ext, err, formats[i + 1]),
					vim.log.levels.INFO
				)
				try(i + 1)
			else
				callback(nil, err)
			end
		end)
	end

	try(1)
end

-- Evaluates `expression` in the current paused debug frame, serializes the
-- result to a temp file (pandas/polars only), and opens it in the viewer.
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
		if not WRITERS.csv[kind] then
			vim.notify(
				string.format("df-nvim: '%s' is not a supported dataframe (got %s)", expression, kind or "unknown"),
				vim.log.levels.ERROR
			)
			return
		end

		write_frame(session, frame_id, kind, expression, function(path, serialize_err)
			if serialize_err then
				vim.notify("df-nvim: failed to serialize '" .. expression .. "': " .. serialize_err, vim.log.levels.ERROR)
				return
			end

			require("df-nvim").open_if_closed(path, layout)
		end)
	end)
end

return M
