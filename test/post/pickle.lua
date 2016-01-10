
local P = require "Pickle"
local F = require "Pickle.Filter"

P.configure{
	build_path = "public",
}

local Post = require "src/Post"

-- construct posts over preludes in post/**.html
P.filter("post", F.match(".*%.html", Post))
