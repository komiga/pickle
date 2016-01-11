
local U = require "togo.utility"
local IO = require "togo.io"
local P = require "Pickle"
local M = U.module("Post")

U.class(M)


local tpl_layout = P.Template(nil, [[
<html>
<head>
	<title>{{ title }}</title>
</head>

<body>
	<h1>{{ title }}</h1>

	{! content !}
</body>
</html>
]])

local prelude_vf = P.ValueFilter("Post")
:filter("url", "string")
:filter("title", "string")

function M:__init(source, file, destination)
	source = P.path(source, file)
	self.template = P.Template(source, nil, tpl_layout)

	local prelude = {
		url = P.path("post", file),
		title = "",
	}
	self.template:prelude(prelude)
	prelude_vf:consume(self, prelude)

	P.output(source, P.path(destination, self.url), self, self)
end

function M:write(source, destination, _)
	return self.template:write(source, destination, self)
end

function M:replace(repl, o, op)
	self.url = repl.url
	self.title = repl.title
	self.template:replace(repl.template)
	return true
end

function M:data(o)
	return self.template:data(o)
end

return M
