#line 2 "pickle/app_core/main.cpp"
/**
@copyright MIT license; see @ref index or the accompanying LICENSE file.
*/

#include <pickle/app_core/config.hpp>
#include <pickle/app_core/types.hpp>
#include <pickle/app_core/internal.hpp>

#include <togo/core/utility/utility.hpp>
#include <togo/core/log/log.hpp>
#include <togo/core/memory/memory.hpp>
#include <togo/core/system/system.hpp>
#include <togo/core/filesystem/filesystem.hpp>
#include <togo/core/io/io.hpp>
#include <togo/core/lua/lua.hpp>

using namespace togo;
using namespace pickle;

namespace {

static LuaModuleFunctionArray const li_internal_funcs{
	TOGO_LI_FUNC_REF(internal, template_transform)
	TOGO_LI_FUNC_REF(internal, make_server)
	TOGO_LI_FUNC_REF(internal, set_signal_handler)
	TOGO_LI_FUNC_REF(internal, strptime)
	TOGO_LI_FUNC_REF(internal, __module_init__)
};

static LuaModuleRef const li_modules[]{
{
	"Pickle",
	"pickle/app_core/Pickle.lua",
	null_ref_tag{},
	#include <pickle/app_core/Pickle.lua>
},
{
	"Pickle.Interface",
	"pickle/app_core/Pickle.Interface.lua",
	null_ref_tag{},
	#include <pickle/app_core/Pickle.Interface.lua>
},
{
	"Pickle.Filter",
	"pickle/app_core/Pickle.Filter.lua",
	null_ref_tag{},
	#include <pickle/app_core/Pickle.Filter.lua>
},
{
	"Pickle.Internal",
	"pickle/app_core/Pickle.Internal.lua",
	li_internal_funcs,
	#include <pickle/app_core/Pickle.Internal.lua>
},
};

} // anonymous namespace

signed main(signed argc, char* argv[]) {
	signed ec = 0;
	memory::init();

	lua_State* L = lua::new_state();
	luaL_openlibs(L);

	lua::register_core(L);
	system::register_lua_interface(L);
	filesystem::register_lua_interface(L);
	io::register_lua_interface(L);

	for (auto& module : li_modules) {
		lua::preload_module(L, module);
	}

	lua::push_value(L, lua::pcall_error_message_handler);
	lua::load_module(L, "Pickle.Interface", true);
	lua::table_get_raw(L, "main");
	lua_remove(L, -2);
	lua_createtable(L, 0, argc);
	for (signed i = 0; i < argc; ++i) {
		lua::table_set_index_raw(L, i + 1, StringRef{argv[i], cstr_tag{}});
	}
	if (lua_pcall(L, 1, 1, -3)) {
		auto error = lua::get_string(L, -1);
		TOGO_LOGF("error: %.*s\n", error.size, error.data);
		ec = 2;
	} else {
		if (!lua::get_boolean(L, -1)) {
			ec = 1;
		}
	}
	lua_pop(L, 2);
	lua_close(L);
	memory::shutdown();
	return ec;
}
