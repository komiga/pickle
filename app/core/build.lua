
local S, G, R = precore.helpers()

precore.make_config("pickle.lib.core.mmx.dep", nil, {
{project = function(p)
	configuration {}
		includedirs {
			G"${DEP_PATH}/mmx/",
		}
end}})

precore.make_config("pickle.app.core.dep", {
	reverse = true,
}, {
"pickle.base",
"togo.lib.core.dep",
"pickle.lib.core.mmx.dep",
{project = function(p)
	pickle.app_config("core")
end}})

precore.append_config_scoped("pickle.projects", {
{global = function(_)
	pickle.make_app("core", {
		"pickle.app.core.dep",
	})

	configuration {}
		targetname("pickle")
end}})
