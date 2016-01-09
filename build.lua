
dofile("scripts/common.lua")

local S, G, R = precore.helpers()

pickle = {}

precore.make_config_scoped("pickle.env", {
	once = true,
}, {
{global = function()
	precore.define_group("PICKLE", os.getcwd())
end}})

precore.apply_global({
	"precore.env-common",
	"pickle.env",
})
precore.import(G"${DEP_PATH}/togo")

function pickle.library_config(name)
	configuration {}
		includedirs {
			G"${PICKLE_ROOT}/lib/" .. name .. "/src/",
		}
	pickle.link_library(name)
end

function pickle.app_config(name)
	configuration {}
		includedirs {
			G"${PICKLE_ROOT}/app/" .. name .. "/src/",
		}
	pickle.link_library("app_" .. name)
end

function pickle.link_library(name)
	name = "pickle_" .. name
	if not precore.env_project()["NO_LINK"] then
		configuration {"release"}
			links {name}

		configuration {"debug"}
			links {name .. "_d"}
	end
end

function pickle.make_library(name, configs, env)
	configs = configs or {}
	table.insert(configs, 1, "pickle.strict")
	table.insert(configs, 2, "pickle.base")

	env = precore.internal.env_set({
		PICKLE_LIBRARY = true,
		NO_LINK = true,
	}, env or {})

	local p = precore.make_project(
		"lib_" .. name,
		"C++", "StaticLib",
		"${PICKLE_BUILD}/lib/",
		"${PICKLE_BUILD}/out/${NAME}/",
		env, configs
	)

	configuration {"debug"}
		targetsuffix("_d")

	configuration {}
		targetname("pickle_" .. name)
		files {
			"src/**.cpp",
		}

	if os.isfile("test/build.lua") then
		precore.push_wd("test")
		local prev_solution = solution()
		precore.make_solution(
			"lib_" .. name .. "_test",
			{"debug", "release"},
			{"x64", "x32"},
			nil,
			{
				"precore.generic",
			}
		)
		precore.import(".")
		precore.pop_wd()
		solution(prev_solution.name)
	end
end

function pickle.make_app(name, configs, env)
	configs = configs or {}
	table.insert(configs, 1, "pickle.strict")
	table.insert(configs, 2, "pickle.base")

	env = env or {}
	local lib_env = precore.internal.env_set({
		PICKLE_LIB = true,
		NO_LINK = true,
	}, env)
	local lib_proj = precore.make_project(
		"app_" .. name .. "_lib",
		"C++", "StaticLib",
		"${PICKLE_BUILD}/lib/",
		"${PICKLE_BUILD}/out/${NAME}/",
		lib_env, configs
	)

	configuration {"debug"}
		targetsuffix("_d")

	configuration {}
		targetname("pickle_app_" .. name)
		files {
			"src/**.cpp",
		}
		excludes {
			"src/**/main.cpp"
		}

	local app_env = precore.internal.env_set({
		PICKLE_APP = true,
	}, env)
	precore.make_project(
		"app_" .. name,
		"C++", "ConsoleApp",
		"${PICKLE_BUILD}/bin/",
		"${PICKLE_BUILD}/out/${NAME}/",
		app_env, configs
	)

	configuration {"linux"}
		targetsuffix(".elf")

	configuration {}
		targetname(name)
		files {
			"src/**/main.cpp",
		}
end

function pickle.make_test(group, name, srcglob, configs)
	configs = configs or {}
	table.insert(configs, 1, "pickle.strict")
	table.insert(configs, 2, "pickle.base")

	local env = {
		PICKLE_TEST = true,
	}
	precore.make_project(
		group .. "_" .. name,
		"C++", "ConsoleApp",
		"./",
		"../build/${NAME}/",
		env, configs
	)
	if not srcglob then
		srcglob = name .. ".cpp"
	end

	configuration {"linux"}
		targetsuffix(".elf")

	configuration {}
		targetname(name)
		includedirs {
			G"${TOGO_ROOT}/support/",
		}
		files {
			srcglob
		}
end

function pickle.make_tests(group, tests)
	precore.push_wd(group)
	for name, test in pairs(tests) do
		pickle.make_test(group, name, test[1], test[2])
	end
	precore.pop_wd()
end

precore.make_config("pickle.strict", nil, {
{project = function()
	-- NB: -Werror is a pita for GCC. Good for testing, though,
	-- since its error checking is better.
	configuration {"clang"}
		flags {
			"FatalWarnings",
		}
		buildoptions {
			"-Wno-extra-semi",
		}

	configuration {"linux"}
		buildoptions {
			"-pedantic-errors",
			"-Wextra",

			"-Wuninitialized",
			"-Winit-self",

			"-Wmissing-field-initializers",
			"-Wredundant-decls",

			"-Wfloat-equal",
			"-Wold-style-cast",

			"-Wnon-virtual-dtor",
			"-Woverloaded-virtual",

			"-Wunused",
			"-Wundef",
		}
end}})

precore.make_config("pickle.base", nil, {
"togo.base",
{project = function(p)
	configuration {}
		libdirs {
			S"${PICKLE_BUILD}/lib/",
		}

	configuration {"linux"}
		buildoptions {
			"-pthread",
		}

	if not precore.env_project()["NO_LINK"] then
		links {
			"m",
			"dl",
			"pthread",
		}
	end

	configuration {"debug"}
		defines {
			"PICKLE_DEBUG",
		}
end}})

precore.make_config_scoped("pickle.projects", {
	once = true,
}, {
{global = function()
	precore.make_solution(
		"pickle",
		{"debug", "release"},
		{"x64", "x32"},
		nil,
		{
			"precore.generic",
		}
	)

	local env = {
		NO_LINK = true,
	}
	local configs = {
		"pickle.strict",
	}
	for _, name in pairs(pickle.libs) do
		table.insert(configs, 1, "pickle.lib." .. name .. ".dep")
	end
	for _, name in pairs(pickle.apps) do
		table.insert(configs, 1, "pickle.app." .. name .. ".dep")
	end

	precore.make_project(
		"igen",
		"C++", "StaticLib",
		"build/igen/", "build/igen/",
		env, configs
	)

	configuration {"gmake"}
		prebuildcommands {
			"$(SILENT) mkdir -p ./tmp",
			"$(SILENT) ./scripts/run_igen.py -- $(ALL_CXXFLAGS)",
			"$(SILENT) exit 0",
		}
end}})

pickle.libs = pickle_libs()
pickle.apps = pickle_apps()

for _, name in pairs(pickle.libs) do
	precore.import(G"${PICKLE_ROOT}/lib/" .. name)
end
for _, name in pairs(pickle.apps) do
	precore.import(G"${PICKLE_ROOT}/app/" .. name)
end
