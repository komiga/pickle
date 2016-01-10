
local U = require "togo.utility"
local IO = require "togo.io"
local P = require "Pickle"
local M = U.module("Post")

U.class(M)

M.posts = {}

local tpl_layout = P.Template(nil, [[
<h1>{{ prop.title }}</h1>

{@ template, prop @}
]])

function M:__init(source, file, destination)
	source = P.path(source, file)
	self.prop = {
		url = P.path("post", file),
	}
	self.template = P.Template(source)

	self.template:prelude(self.prop)
	U.type_assert(self.prop.title, "string")

	P.output(source, P.path(destination, self.prop.url), self)
	table.insert(M.posts, self)
end

function M:write(source, destination)
	P.log_chatter("post: %s -> %s", source, destination)
	local data = tpl_layout:content(self)
	if not IO.write_file(destination, data) then
		P.error_output("failed to write file", source, destination)
	end
end

return M
