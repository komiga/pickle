
local U = require "togo.utility"
local P = require "Pickle"
local F = require "Pickle.Filter"

P.configure{
	build_path = "public",
}

-- static/**  ->  build_path root
P.filter("static", F.copy)

P.collect()
P.output(nil, "a/test_generated", [[pickle pickle]])

local t = P.Template(nil, [[
prelude_test()
---content---
X
pre{{x}}post
X
{% for i = 1, 4 do %}
	{{ i }}
{% end %}
X
X
{% for i = 1, 4 do %}{{ i }}{% end %}
X

pre{{y}}post

X]])

local c = {
	x = 1,
	y = 2,
	f = function()
		return 3
	end,
	prelude_test = function()
		P.log_debug("TRACE")
	end,
}
P.log_debug("\n`%s`", t:content(c))
t:prelude(c)

P.output(nil, "test_template", t, c)
