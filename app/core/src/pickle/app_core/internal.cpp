#line 2 "pickle/app_core/internal.cpp"
/**
@copyright MIT license; see @ref index or the accompanying LICENSE file.
*/

#include <pickle/app_core/internal.hpp>

#include <togo/core/error/assert.hpp>
#include <togo/core/utility/utility.hpp>
#include <togo/core/log/log.hpp>
#include <togo/core/collection/fixed_array.hpp>
#include <togo/core/collection/array.hpp>
#include <togo/core/string/string.hpp>
#include <togo/core/lua/lua.hpp>

#define MMW_IMPLEMENTATION
#define MMW_STATIC
#define MMW_UINT_PTR uintptr_t
#define MMW_ASSERT TOGO_ASSERTE
#define MMW_USE_ASSERT

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wunused-function"

#include <mm_web.h>
#include <signal.h>

#pragma GCC diagnostic pop

namespace pickle {

namespace {

struct Transformer {
	unsigned prev;
	unsigned start;
	unsigned end;
	unsigned row;
	unsigned col;
	char const* data;
	unsigned size;
	FixedArray<char, 128> err;
	Array<char> output;
};

static StringRef min_segment(char const* data, unsigned s, unsigned e) {
	auto sp = data + s;
	auto ep = data + e;
	for (; sp < ep; ++sp) {
		switch (*sp) {
			case '\t': case '\n': case '\r': case ' ': continue;
		}
		break;
	}
	--ep;
	for (; sp < ep; --ep) {
		switch (*ep) {
			case '\t': case '\n': case '\r': case ' ': continue;
		}
		break;
	}
	++ep;
	return {sp, static_cast<unsigned>(ep - sp)};
}

static bool transformer_head(Transformer& t, unsigned& i, StringRef m) {
	unsigned mi = 0;
	char n = m[0];
	for (; i < t.size; ++i, ++t.col) {
		char c = t.data[i];
		if (c == n) {
			if (++mi == m.size) {
				i -= m.size - 1;
				return true;
			}
			n = m[mi];
			continue;
		} else if (c == '\n') {
			t.row++;
			t.col = 0;
		}
		mi = 0;
		n = m[0];
	}
	return false;
}

static bool transformer_tail(Transformer& t, unsigned start, unsigned& i, StringRef m) {
	i = start;
	unsigned mi = 0;
	char n = m[0];
	for (; i < t.size; ++i) {
		char c = t.data[i];
		if (c == n) {
			if (++mi == m.size) {
				i -= m.size - 1;
				return true;
			}
			n = m[mi];
		} else {
			mi = 0;
			n = m[0];
		}
	}
	return false;
}

static bool transformer_find_block_tail(
	Transformer& t,
	StringRef tail,
	StringRef& content
) {
	if (!transformer_tail(t, t.start + 2, t.end, tail)) {
		string::copy(t.err, "unclosed block: ");
		string::append(t.err, {t.data + t.start, 2});
		return false;
	}
	content = min_segment(t.data, t.start + 2, t.end);
	if (content.empty()) {
		string::copy(t.err, "empty block");
		return false;
	}
	return true;
}

#define TX_FIND_BLOCK_TAIL(s) do { \
	if (!transformer_find_block_tail(t, s, content)) { \
		goto l_error; \
	} \
} while (false)

#define TX_ELEMENT "__O[#__O+1]="

#define TX_OUT(s) string::append(t.output, s)
#define TX_OUT_ELEM(s) TX_OUT(TX_ELEMENT s)
#define TX_OUT_CHUNK(s) TX_OUT_ELEM("[=[\n"); TX_OUT(s); TX_OUT("]=]\n")

static bool transformer_block(Transformer& t) {
	StringRef content;
	if (t.start > t.prev) {
		content = {t.data + t.prev, t.start - t.prev};
		// content = min_segment(t.data, t.prev, t.start);
		// if (content.any()) {
			TX_OUT_CHUNK(content);
		// }
		t.prev = t.start;
	}
	char k;
	if (t.start < t.size) {
		k = t.data[t.start + 1];
		switch (k) {
		case '%':
			TX_FIND_BLOCK_TAIL("%}");
			TX_OUT(content);
			if (content[content.size - 1] != '\n') {
				TX_OUT("\n");
			}
			if (t.end + 2 != t.size && t.data[t.end + 2] == '\n') {
				++t.end;
			}
			goto l_block_end;

		case '!':
			TX_FIND_BLOCK_TAIL("!}");
			TX_OUT_ELEM("P.tpl_out(");
			TX_OUT(content);
			TX_OUT(")\n");
			goto l_block_end;

		case '{':
			TX_FIND_BLOCK_TAIL("}}");
			TX_OUT_ELEM("P.tpl_out_escape(");
			TX_OUT(content);
			TX_OUT(")\n");
			goto l_block_end;

		case '@':
			TX_FIND_BLOCK_TAIL("@}");
			TX_OUT_ELEM("__INCLUDE(");
			TX_OUT(content);
			TX_OUT(")\n");
			goto l_block_end;

		l_block_end:
			t.prev = t.end + 2;
			t.start = t.prev;
			break;

		default:
			t.prev = t.start + 1;
			t.start = t.prev;
			break;
		}
	}
	return true;

l_error:
	return false;
}

static StringRef const
s_template_prefix{
u8R"(local __O,__INCLUDE={},function(p, c)
	return P.get_template(p):content(c or C)
end
)"},
s_template_post{
u8R"(return table.concat(__O))"};

static bool transformer_consume(Transformer& t) {
	TX_OUT(s_template_prefix);
	while (transformer_head(t, t.start, "{")) {
		if (!transformer_block(t)) {
			return false;
		}
	}
	if (!transformer_block(t)) {
		return false;
	}
	TX_OUT(s_template_post);
	return true;
}

} // anonymous namespace

/// Transform a template from a string.
signed internal::li_template_transform(lua_State* L) {
	auto data = lua::get_string(L, 1);

	Transformer t{
		0, 0, 0,
		1, 1,
		data.data, data.size,
		{},
		{memory::default_allocator()}
	};
	array::reserve(t.output, 64 * 1024);
	if (!transformer_consume(t)) {
		lua::push_value(L, null_tag{});
		lua::push_value(L, t.err);
		lua::push_value(L, t.row);
		lua::push_value(L, t.col);
		return 4;
	} else {
		lua::push_value(L, StringRef{t.output});
		return 1;
	}
}

namespace {

struct Server {
	TOGO_LUA_MARK_USERDATA(Server);

	lua_State* L;
	mmw_config c;
	mmw_server s;
	void* data;
};
TOGO_LUA_MARK_USERDATA_ANCHOR(Server);

static void server_log(char const* msg) {
	TOGO_LOG("server: ");
	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wformat-security"
	TOGO_LOG(msg);
	#pragma GCC diagnostic pop
	TOGO_LOG("\n");
}

static signed server_dispatch(mmw_con* connection, void* userdata) {
	auto& server = *static_cast<Server*>(userdata);
	auto* L = server.L;
	auto const& r = connection->request;
	if (!string::compare_equal(StringRef{r.method, cstr_tag{}}, "GET")) {
		return 1;
	}
	lua_pushvalue(L, 2);
	lua::push_value(L, StringRef{r.uri, cstr_tag{}});
	lua_call(L, 1, 3);

	StringRef data;
	signed status_code = 200;
	if (lua_type(L, -3) == LUA_TNIL) {
		status_code = 404;
		data = "<html><head><title>404 - URL not found</title></head><body><h1>404 - URL not found</h1></body></html>";
	} else {
		data = lua::get_string(L, -3);
	}
	if (lua_type(L, -2) != LUA_TNIL) {
		status_code = lua::get_integer(L, -2);
	}
	FixedArray<mmw_header, 16> headers{};
	if (lua_type(L, -1) != LUA_TNIL) {
		luaL_checktype(L, -1, LUA_TTABLE);
		lua::push_value(L, null_tag{});
		while (lua_next(L, -2) != 0) {
			fixed_array::push_back(headers, {
				lua::get_string(L, -2).data,
				lua::get_string(L, -1).data
			});
			lua_pop(L, 1);
		}
	}
	mmw_response_begin(
		connection, status_code, data.size,
		begin(headers), fixed_array::size(headers)
	);
	mmw_write(connection, data.data, data.size);
	mmw_response_end(connection);
	lua_pop(server.L, 2);
	return 0;
}

static void server_stop(Server& server) {
	mmw_server_stop(&server.s);
}

TOGO_LI_FUNC_DEF(server_destroy) {
	auto& server = *lua::get_userdata<Server>(L, 1);
	server_stop(server);
	memory::default_allocator().deallocate(server.data);
	return 0;
}

TOGO_LI_FUNC_DEF(server_update) {
	auto& server = *lua::get_userdata<Server>(L, 1);
	luaL_checktype(L, 2, LUA_TFUNCTION);

	mmw_server_update(&server.s);
	return 0;
}

TOGO_LI_FUNC_DEF(server_stop) {
	auto& server = *lua::get_userdata<Server>(L, 1);
	server_stop(server);
	return 0;
}

#define SERVER_FUNC(name) {#name, TOGO_LI_FUNC(server_ ## name)},

static LuaModuleFunctionArray const server_funcs{
	SERVER_FUNC(update)
	SERVER_FUNC(stop)
};

#undef SERVER_FUNC

} // anonymous namespace

/// Make a server.
signed internal::li_make_server(lua_State* L) {
	auto address = lua::get_string(L, 1);
	auto port = lua::get_integer(L, 2);
	auto with_log = luaL_opt(L, lua::get_boolean, 3, false);

	auto& server = *lua::new_userdata<Server>(L);
	server.L = L;
	server.c.userdata = &server;
	server.c.address = address.data;
	server.c.port = port;
	server.c.connection_max = 8;
	server.c.request_buffer_size = 2 * 1024;
	server.c.io_buffer_size = 8 * 1024;
	server.c.log = with_log ? server_log : nullptr;
	server.c.dispatch = server_dispatch;

	mmw_size size;
	mmw_server_init(&server.s, &server.c, &size);
	server.data = memory::default_allocator().allocate(size);
	mmw_server_start(&server.s, server.data);
	server.c.address = nullptr;
	return 1;
}

namespace {

struct SignalNumber {
	StringRef name;
	signed value;
};

#define SIGNAL_NUMBER(n) {#n, n},
static SignalNumber const signal_numbers[]{
	SIGNAL_NUMBER(SIGHUP)
	SIGNAL_NUMBER(SIGINT)
	SIGNAL_NUMBER(SIGQUIT)
	SIGNAL_NUMBER(SIGILL)
	SIGNAL_NUMBER(SIGTRAP)
	SIGNAL_NUMBER(SIGABRT)
	SIGNAL_NUMBER(SIGIOT)
	SIGNAL_NUMBER(SIGBUS)
	SIGNAL_NUMBER(SIGFPE)
	SIGNAL_NUMBER(SIGUSR1)
	SIGNAL_NUMBER(SIGSEGV)
	SIGNAL_NUMBER(SIGUSR2)
	SIGNAL_NUMBER(SIGPIPE)
	SIGNAL_NUMBER(SIGALRM)
	SIGNAL_NUMBER(SIGTERM)
	SIGNAL_NUMBER(SIGSTKFLT)
	SIGNAL_NUMBER(SIGCLD)
	SIGNAL_NUMBER(SIGCHLD)
	SIGNAL_NUMBER(SIGCONT)
	SIGNAL_NUMBER(SIGTSTP)
	SIGNAL_NUMBER(SIGTTIN)
	SIGNAL_NUMBER(SIGTTOU)
	SIGNAL_NUMBER(SIGURG)
	SIGNAL_NUMBER(SIGXCPU)
	SIGNAL_NUMBER(SIGXFSZ)
	SIGNAL_NUMBER(SIGVTALRM)
	SIGNAL_NUMBER(SIGPROF)
	SIGNAL_NUMBER(SIGWINCH)
	SIGNAL_NUMBER(SIGPOLL)
	SIGNAL_NUMBER(SIGIO)
	SIGNAL_NUMBER(SIGPWR)
	SIGNAL_NUMBER(SIGSYS)
};

#undef SIGNAL_NUMBER

static lua_State* sh_state = nullptr;
static lua_Hook sh_hook = nullptr;
static signed sh_hmask = 0;
static signed sh_hcount = 0;
static signed sh_signum = 0;

static void li_signal_handler(lua_State* L, lua_Debug*) {
	lua::table_get_raw(L, LUA_GLOBALSINDEX, "__signal_handler__");
	lua::table_get_index_raw(L, sh_signum);
	if (lua_type(L, -1) == LUA_TFUNCTION) {
		lua::push_value(L, sh_signum);
		lua_call(L, 1, 0);
	}
	lua_pop(L, 2);
	lua_sethook(L, sh_hook, sh_hmask, sh_hcount);
}

static void signal_handler(signed signum) {
	sh_hook = lua_gethook(sh_state);
	sh_hmask = lua_gethookmask(sh_state);
	sh_hcount = lua_gethookcount(sh_state);

	sh_signum = signum;
	lua_sethook(sh_state, li_signal_handler, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}

} // anonymous namespace

/// Set or remove a signal handler.
signed internal::li_set_signal_handler(lua_State* L) {
	signed signum = lua::get_integer(L, 1);
	bool has_handler = lua_type(L, 2) != LUA_TNIL;
	if (has_handler) {
		luaL_checktype(L, 2, LUA_TFUNCTION);
	}

	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wold-style-cast"
	struct ::sigaction sa{};
	sa.sa_flags = 0;
	if (has_handler) {
		sa.sa_handler = signal_handler;
	} else {
		sa.sa_handler = SIG_DFL;
	}
	#pragma GCC diagnostic pop

	bool success = ::sigaction(signum, &sa, nullptr) == 0;
	if (success) {
		lua::table_get_raw(L, LUA_GLOBALSINDEX, "__signal_handler__");
		lua::table_set_copy_index_raw(L, signum, 2);
		lua_pop(L, 1);
	} else {
		TOGO_LOG("error: failed to set signal handler\n");
	}
	lua::push_value(L, success);
	return 1;
}

IGEN_PRIVATE
signed internal::li___module_init__(lua_State* L) {
	lua::register_userdata<Server>(L, TOGO_LI_FUNC(server_destroy), true);
	for (auto& mf : server_funcs) {
		lua::table_set_raw(L, mf.name, mf.func);
	}
	lua_pop(L, 1);

	lua_createtable(L, 0, 0);
	lua::table_set_copy_raw(L, LUA_GLOBALSINDEX, "__signal_handler__", -1);
	lua_pop(L, 1);
	sh_state = L;

	for (auto& sn : signal_numbers) {
		lua::table_set_raw(L, sn.name, sn.value);
	}
	return 0;
}

} // namespace pickle
