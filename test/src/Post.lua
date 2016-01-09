
local U = require "togo.utility"
local P = require "Pickle"
local M = U.module("Post")

U.class(M)

function M:__init(source, file, destination)
	-- TODO
	U.log("Post(%s, %s, %s)", source, file, destination)
end

return M
