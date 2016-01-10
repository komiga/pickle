
local U = require "togo.utility"
local IO = require "togo.io"
local P = require "Pickle"
local M = U.module("Post")

U.class(M)

M.posts = {}

local tpl_layout = P.Template(nil, [[
<h1>{{ title }}</h1>

{! content !}
]])

function M:__init(source, file, destination)
	source = P.path(source, file)
	self.prop = {
		url = P.path("post", file),
	}
	self.template = P.Template(source, nil, tpl_layout)

	self.template:prelude(self.prop)
	U.type_assert(self.prop.title, "string")

	P.output(source, P.path(destination, self.prop.url), self.template, self.prop)
	table.insert(M.posts, self)
end

return M
