u8R""__RAW_STRING__(

local U = require "togo.utility"
local P = require "Pickle"

local M = U.module(...)

function M.match(pattern, func)
	pattern = "^" .. pattern .. "$"
	return function(source, file, destination)
		if string.match(file, pattern) then
			return func(source, file, destination)
		end
		return false
	end
end

function M.copy(source, file, destination)
	return P.output(P.path(source, file), P.path(destination, file), P.FileMedium())
end

return M

)"__RAW_STRING__"