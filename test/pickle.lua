
local P = require "Pickle"
local F = require "Pickle.Filter"

P.configure{
	build_path = "public",
}

local Post = require "src/Post"

-- static/**  ->  build_path root
P.filter("static", F.copy)

-- construct posts over preludes in post/**.html
P.filter("post", F.match(".*%.html", Post))

P.collect()
P.output(nil, "a/test_generated", [[pickle pickle]])

local t = P.Template(nil, [[
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
}
-- P.log_chatter(t:render(c))

P.output(nil, "test_template", t, c)
