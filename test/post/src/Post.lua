
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

local prelude_vf = P.ValueFilter("Post")
:filter("title", "string")

function M:__init(source, file, destination)
	source = P.path(source, file)
	self.url = P.path("post", file)
	self.template = P.Template(source, nil, tpl_layout)

	local prelude_data = {}
	self.template:prelude(prelude_data)
	prelude_vf:consume(self, prelude_data)

	P.output(source, P.path(destination, self.url), self, self)
	M.posts[source] = self
end

function M:write(source, destination, _)
	return self.template:write(source, destination, self)
end

function M:replace(o, prev)
	M.posts[o.source] = self
	return true
end

function M:data(o)
	return self.template:data(o)
end

return M
