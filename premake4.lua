
dofile("scripts/precore_import.lua")

local _, G, R = precore.helpers()

precore.init(
	nil,
	{
		"precore.clang-opts",
		"precore.c++11-core",
	}
)

precore.import(".")
precore.apply_global("pickle.projects")

-- precore.print_debug()

if _ACTION == "clean" then
	os.rmdir(G"${BUILD_PATH}")

	local sol = precore.state.solutions["pickle"]
	assert(sol)
	for _, proj in pairs(sol.projects) do
		if proj.env["PICKLE_LIBRARY"] then
			os.rmdir(proj.obj.basedir .. "/test/build")
		end
	end
end
