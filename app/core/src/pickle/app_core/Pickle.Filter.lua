u8R""__RAW_STRING__(

local U = require "togo.utility"
local P = require "Pickle"

local M = U.module(...)

function M.match(pattern, func)
	pattern = "^" .. pattern .. "$"
	return function(source, file, destination)
		if string.match(file, pattern) then
			func(source, file, destination)
		end
	end
end

function M.copy(source, file, destination)
	P.output(P.path(source, file), P.path(destination, file), P.File)
end

return M

)"__RAW_STRING__"