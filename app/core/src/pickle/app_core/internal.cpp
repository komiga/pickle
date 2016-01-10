#line 2 "pickle/app_core/internal.cpp"
/**
@copyright MIT license; see @ref index or the accompanying LICENSE file.
*/

#include <pickle/app_core/internal.hpp>

#include <togo/core/utility/utility.hpp>
#include <togo/core/collection/fixed_array.hpp>
#include <togo/core/collection/array.hpp>
#include <togo/core/string/string.hpp>
#include <togo/core/lua/lua.hpp>

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

#define TX_ELEMENT "_O_[#_O_+1]="

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

static StringRef const s_template_prefix{
u8R"(local _O_,__INCLUDE={},function(p, c)
	return P.template(p):render(c or C)
end
)"};

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
	TX_OUT("return table.concat(_O_)");
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
	array::reserve(t.output, 8 * 1024);
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

} // namespace pickle
