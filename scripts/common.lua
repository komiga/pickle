
-- FIXME: u g h, why
if precore then
	dofile("../dep/togo/scripts/common.lua")
else
	dofile("dep/togo/scripts/common.lua")
end

function pickle_libs()
	return {}
end

function pickle_apps()
	return {
		"core"
	}
end
