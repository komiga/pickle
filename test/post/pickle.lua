
local P = require "Pickle"
local F = require "Pickle.Filter"

P.configure{
	build_path = "public",
}

local Post = require "src/Post"

-- construct posts over preludes in post/**.html
P.filter("post", F.match(".*%.html", Post))

local page_data_404 = [[
<html>
<head>
	<title>404 - URL not found</title>
</head>
<body>

<h1>404 - URL not found</h1>

<p>Custom 404 page.</p>

</body>
</html>
]]

P.filter(function(_, _, _)
	return P.output(nil, "404.html", page_data_404)
end)
