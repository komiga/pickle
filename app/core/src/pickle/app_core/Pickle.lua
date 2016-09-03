u8R""__RAW_STRING__(

local U = require "togo.utility"
local IO = require "togo.io"
local FS = require "togo.filesystem"
local Internal = require "Pickle.Internal"
local M = U.module(...)

M.LogLevel = {
	info = 1,
	chatter = 2,
	debug = 3,
}

M.config_default = {
	log_level = M.LogLevel.info,
	force_overwrite = false,
	build_path = "public",
	testing_mode = false,
	delay = 1,
	addr = "127.0.0.1",
	port = 4000,
}
M.config = nil
M.context = nil

local BYTE_SLASH = string.byte('/', 1)

function M.log(msg, ...)
	U.type_assert(msg, "string")
	if M.config.log_level >= M.LogLevel.info then
		U.print(msg, ...)
	end
end

function M.log_chatter(msg, ...)
	U.type_assert(msg, "string")
	if M.config.log_level >= M.LogLevel.chatter then
		U.print(msg, ...)
	end
end

function M.log_debug(msg, ...)
	U.type_assert(msg, "string")
	if M.config.log_level >= M.LogLevel.debug then
		U.print(U.get_trace(1) .. ": debug: " .. msg, ...)
	end
end

function M.error(msg, ...)
	error(U.get_trace(1) .. ": error: " .. string.format(msg, ...), 0)
end

function M.error_output(msg, source, destination, ...)
	error(U.get_trace(1) .. ": error: " .. string.format(msg, ...) .. string.format(" [output: %s -> %s]", source, destination), 0)
end

M.ValueFilter = U.class(M.ValueFilter)

function M.ValueFilter:__init(name)
	U.type_assert(name, "string")

	self.name = name
	self.filters = {}
	self.default_filter = nil
end

local function make_value_filter(tc, func)
	if not U.is_instance(tc) then
		U.type_assert_any(tc, {"string", "table"}, true)
	end
	U.type_assert(func, "function", true)
	if tc then
		if not U.is_type(tc, "table") then
			tc = {tc}
		end
	end
	return function(name, state, value)
		if tc then
			U.type_assert_any(value, tc)
		end
		if func then
			local err
			value, err = func(state, value)
			if err ~= nil then
				return err
			end
		end
		if state then
			state[name] = value
		end
		return true
	end
end

function M.ValueFilter:filter(names, tc, func)
	U.type_assert_any(names, {"string", "table"})
	names = U.is_type(names, "table") and names or {names}

	local filter = make_value_filter(tc, func)
	for _, name in ipairs(names) do
		U.assert(not self.filters[name], "filter '%s' already defined", name)
		self.filters[name] = filter
	end
	return self
end

function M.ValueFilter:default(func)
	self.default_filter = func
	return self
end

function M.ValueFilter:transform(func)
	U.type_assert(func, "function", true)
	self.transformer = func
	return self
end

function M.ValueFilter:consume_safe(state, input, fallback)
	U.type_assert(fallback, M.ValueFilter, true)
	U.assert(state == nil or type(state) == "table")
	for key, value in pairs(input) do
		if self.transformer then
			key, value = self.transformer(key, value)
		end
		local filter = self.filters[key] or self.default_filter
		if not filter and fallback then
			filter = fallback.filters[key] or fallback.default_filter
		end
		local err
		if filter then
			err = filter(key, state, value)
		else
			err = "no matching filter"
		end
		if err ~= true then
			return string.format(
				"%s: filter '%s' <= '%s' (of type %s): %s",
				self.name, tostring(key),
				tostring(value), tostring(U.type_class(value)),
				err
			)
		end
	end
	return nil
end

function M.ValueFilter:consume(state, input, fallback)
	local err = self:consume_safe(state, input, fallback)
	if err then
		M.error(err)
	end
end

local config_vf = M.ValueFilter("PickleConfig")
:filter("log_level", nil, function(_, value)
	local given = value
	if U.is_type(value, "string") then
		value = M.LogLevel[value]
	end
	if U.is_type(value, "number") and value >= M.LogLevel.info and value <= M.LogLevel.debug then
		return value
	end
	return nil, string.format("config.log_level is invalid: %s", tostring(given))
end)
:filter("force_overwrite", "boolean")
:filter("testing_mode", "boolean")
:filter("delay", "number", function(_, value)
	return U.max(0, math.floor(value))
end)
:filter("addr", "string")
:filter("port", "number", function(_, value)
	if value < 0 or value > 0xFFFF then
		return nil, "expected an integer in [0, 0xFFFF]"
	end
	return value
end)
:filter("build_path", "string", function(_, value)
	return U.trim_trailing_slashes(value)
end)

function M.configure(config, safe)
	local func = safe and config_vf.consume_safe or config_vf.consume
	return func(config_vf, M.config, config)
end

function M.configure_default(config, safe)
	local func = safe and config_vf.consume_safe or config_vf.consume
	return func(config_vf, M.config_default, config) or M.configure(config)
end

function M.init()
	M.config = {}
	M.context = {
		collected = false,
		built = false,
		template_cache = {},
		filters = {},
		post_collect = {},
		output_index = {},
		output_by_destination = {},
		output_by_source = {},
		any_output = false,
	}
	M.configure(M.config_default)
	M.log_debug("init")
end

function M.path(...)
	local parts = {...}
	local path = ""
	for i, p in pairs(parts) do
		if p ~= nil and p ~= "" then
			U.type_assert(p, "string")
			path = path .. U.trim_slashes(p)
			if i ~= #parts then
				path = path .. "/"
			end
		end
	end
	return path
end

local function path_dir_iter_func(init_path, path)
	if path == nil then
		return init_path
	end
	path = U.path_dir(path)
	return path ~= "" and path or nil
end

local function path_dir_iter(init_path)
	U.type_assert(init_path, "string")
	return path_dir_iter_func, init_path, nil
end

function M.create_path(path)
	if not FS.is_directory(path) then
		local dirs = {}
		for path in path_dir_iter(path) do
			if FS.is_directory(path) then
				break
			end
			table.insert(dirs, path)
		end
		for i = #dirs, 1, -1 do
			if not FS.create_directory(dirs[i], true) then
				return false
			end
		end
	end
	return true
end

local function casual_file_same(a, b)
	if FS.is_file(a) and FS.is_file(b) then
		return FS.file_size(a) == FS.file_size(b)
	end
	return false
end

function M.parse_time(time_str, format)
	local time = {}
	time.secs, time.offset = Internal.strptime(time_str, format)
	return time
end

function M.format_time(time, format)
	if type(time) == "table" then
		return Internal.strftime(time.secs, format, time.offset)
	else
		return Internal.strftime(time, format, 0)
	end
end

--[[do
	local iso_format = "%Y-%m-%dT%H:%M:%S%z"
	local function check(str, secs, offset)
		local time = M.parse_time(str, iso_format)
		local str_rewritten = M.format_time(time, iso_format)
		print("## check: ")
		print("  i " .. str)
		print("  r " .. str_rewritten)
		print("  s " .. tostring(time.secs) .. " " .. tostring(time.secs - secs))
		print("    " .. tostring(secs))
		print("  z " .. tostring(time.offset) .. " " .. tostring(time.offset - offset))
		print("    " .. tostring(offset))
		U.assert(time.offset == offset, "offset")
		U.assert(time.secs == secs, "secs")
		U.assert(str == str_rewritten, "str")
	end
	check("2016-09-03T00:00:00+0000", 1472860800, 0)
	check("2015-10-07T01:34:00-0400", 1444196040, -14400)
end--]]

function M.replace_fields(to, from)
	for k, v in pairs(from) do
		local c = to[k]
		if U.is_instance(c) and U.is_type(c.replace, "function") then
			c:replace(v)
		else
			to[k] = v
		end
	end
end

M.Template = U.class(M.Template)

local function make_subs(repl_pairs)
	local chars = {}
	local repl = {}
	for _, p in ipairs(repl_pairs) do
		table.insert(chars, p[1])
		repl[p[1]] = '&' .. p[2] .. ';'
	end
	return '[' .. table.concat(chars) .. ']', repl
end

local html_group, html_repl = make_subs{
	{"&", "amp"},
	{"<", "lt"},
	{">", "gt"},
}

function M.tpl_out(x)
	if x == nil then
		return ""
	elseif type(x) == "function" then
		return M.tpl_out(x())
	end
	return tostring(x)
end

function M.tpl_out_escape(str)
	if type(str) == "string" then
		return string.gsub(str, html_group, html_repl)
	end
	return M.tpl_out(str)
end

local chunk_metatable = {
	__index = function(t, k)
		return k == "P" and M or rawget(t, "C")[k] or _G[k]
	end,
	__newindex = function(t, k, v)
		rawget(t, "C")[k] = v
	end,
}

local BYTE_NEWLINE = string.byte("\n")

function M.Template:__init(path, data, layout)
	U.type_assert(path, "string", true)
	U.type_assert(data, "string", path ~= nil)
	U.type_assert_any(layout, {"string", M.Template}, true)

	if path == nil then
		path = "<generated>"
	end

	self.path = path
	self.layout = layout and M.get_template(layout) or nil
	self.env = {
		C = nil,
	}
	self.prelude_func = nil
	self.content_func = nil

	if data == nil then
		data = IO.read_file(path)
		if data == nil then
			M.error("failed to read template file: %s", path)
		end
	end

	local func, err
	local csep, csep_end = string.find(data, "---content---\n", 1, true)
	if csep ~= nil and (csep == 1 or string.byte(data, csep - 1, csep - 1) == BYTE_NEWLINE) then
		local prelude_data = string.sub(data, 1, U.max(0, csep - 1))
		-- M.log_debug("template prelude: %s:\n`%s`", path, prelude_data)
		func, err = load(prelude_data, "@" .. path, "t", setmetatable(self.env, chunk_metatable))
		if err then
			M.error("failed to read prelude as Lua:\n%s", err)
		end
		self.prelude_func = func
		data = string.sub(data, U.min(#data, csep_end + 1), -1)
	end

	local row, col
	data, err, row, col = Internal.template_transform(data)
	if err then
		M.error("syntax error in template: %s:%d:%d: %s", path, row, col, err)
	end
	-- M.log_debug("template content: %s:\n`%s`", path, data)
	func, err = load(data, "@" .. path, "t", setmetatable(self.env, chunk_metatable))
	if err then
		M.error("failed to read transformed template as Lua:\n%s", err)
	end
	self.content_func = func
	if path ~= "<generated>" then
		M.add_template_cache(self)
	end
end

local function do_tpl_call(env, func, context)
	rawset(env, "C", context)
	local result = func()
	rawset(env, "C", nil)
	return result
end

function M.Template:prelude(context)
	if context ~= nil then
		U.assert(type(context) == "table")
	else
		context = {}
	end
	return do_tpl_call(self.env, self.prelude_func, context)
end

function M.Template:content(context)
	if context ~= nil then
		U.assert(type(context) == "table")
	else
		context = {}
	end
	local content = do_tpl_call(self.env, self.content_func, context)
	if self.layout then
		content = self.layout:content(setmetatable({
			C = context, content = content
		}, {
			__index = function(t, k)
				return k == "content" and rawget(t, "content") or rawget(t, "C")[k]
			end,
			__newindex = context,
		}))
	end
	return content
end

function M.Template:write(source, destination, context)
	M.log_chatter("template: %s -> %s", source, destination)
	local data = self:content(context)
	if not IO.write_file(destination, data) then
		M.error_output("failed to write file", source, destination)
	end
end

function M.Template:replace(repl, _, _)
	local cached = M.context.template_cache[self.path] ~= nil
	if cached then
		M.context.template_cache[self.path] = nil
	end
	M.replace_fields(self, repl)
	if cached and path ~= "<generated>" then
		M.add_template_cache(self)
	end
	return true
end

function M.Template:data(o)
	return self:content(o.context)
end

function M.add_template_cache(tpl, name)
	U.type_assert(tpl, M.Template)
	if not name or name == "" or name == "<generated>" then
		name = tpl.path
	end
	if name == "<generated>" then
		M.error("cannot cache generated template")
	end
	U.type_assert(name, "string")
	M.context.template_cache[name] = tpl
end

function M.get_template(name)
	if name == nil or name == "" or name == "<generated>" then
		M.error("invalid template name: '%s'", name)
	end
	if U.is_type(name, M.Template) then
		return name
	end
	local tpl = M.context.template_cache[name]
	if not tpl then
		tpl = M.Template(name)
		M.add_template_cache(tpl, name)
	end
	return tpl
end

-- (filter)
-- (source, filter)
-- (source, destination, filter)
function M.filter(a, b, c)
	local source, destination, filter

	if b == nil then
		source = {}
		destination = nil
		filter = a
	elseif c == nil then
		source = a
		destination = nil
		filter = b
	else
		source = a
		destination = U.type_assert(b, "string")
		filter = c
	end

	U.type_assert_any(source, {"string", "table"})
	U.assert(U.is_type(filter, "function") or U.is_functable(filter))

	table.insert(M.context.filters, {
		source = U.is_type(source, "table") and source or {source},
		destination = destination == "" and nil or destination,
		filter = filter,
		processed = false,
	})
end

function M.post_collect(func)
	U.assert(U.is_type(func, "function") or U.is_functable(func))
	table.insert(M.context.post_collect, func)
end

M.FakeMedium = U.class(M.FakeMedium)

function M.FakeMedium:__init(proxy)
	self.proxy = proxy
	U.assert(self.proxy == nil or U.is_instance(self.proxy))
end

function M.FakeMedium:write(_, _, _)
end

function M.FakeMedium:replace(repl, o, op)
	if self.proxy and self.proxy.replace then
		return self.proxy:replace(repl.proxy, o, op)
	end
	return true
end

function M.FakeMedium:data(_)
	return ""
end

M.StringMedium = U.class(M.StringMedium)

function M.StringMedium:__init(data)
	U.type_assert(data, "string")
	self.str = data
end

function M.StringMedium:write(source, destination, _)
	M.log_chatter("string: %s -> %s", source, destination)
	if not IO.write_file(destination, self.str) then
		M.error_output("failed to write file", source, destination)
	end
end

function M.StringMedium:replace(repl, _, _)
	if self.str ~= repl.str then
		self.str = repl.str
		return true
	end
	return false
end

function M.StringMedium:data(_)
	return self.str
end

M.FileMedium = U.class(M.FileMedium)

function M.FileMedium:__init()
end

function M.FileMedium:write(source, destination, _)
	local same = not M.config.force_overwrite and casual_file_same(source, destination)
	M.log_chatter("copy: %s -> %s%s", source, destination, same and " [same]" or "")
	if
		not same and
		not FS.copy_file(source, destination, true)
	then
		M.error_output("failed to copy file", source, destination)
	end
end

function M.FileMedium:replace(_, o, op)
	return o.last_modified ~= op.last_modified
end

function M.FileMedium:data(o)
	local data = IO.read_file(o.source)
	if data == nil then
		M.error("failed to read file: %s", o.source)
	end
	return data
end

function M.output(source, destination, data, context)
	source = U.type_assert(source, "string", true) or "<generated>"
	destination = U.type_assert(destination, "string", true) or ""
	U.assert(#source > 0, "source is empty")
	U.assert(U.is_instance(data, M.FakeMedium) or #destination > 0, "destination is empty")

	local o = {
		index = #M.context.output_index + 1,
		source = source,
		destination = U.trim_leading_slashes(destination),
		medium = nil,
		context = context,
		data_cached = nil,
		last_modified = source ~= "<generated>" and FS.time_last_modified(source) or 0,
	}

	if U.is_type(data, "string") then
		o.medium = M.StringMedium(data)
	elseif U.is_type(data, "function") then
		o.medium = M.FunctionMedium(data)
	elseif U.is_instance(data) then
		o.medium = data
	else
		M.error("data must be a function, string, or class instance")
	end
	U.type_assert(o.medium.write, "function")
	U.type_assert(o.medium.replace, "function")
	U.type_assert(o.medium.data, "function")

	M.context.any_output = true
	local op = M.context.output_by_destination[o.destination] or M.context.output_by_source[o.source]
	if op then
		if o.source ~= op.source then
			M.log(
				"output clobbered:\n%s -> %s\nreplaced by\n%s -> %s",
				op.source, op.destination,
				o.source, o.destination
			)
		end
		if U.type_class(o.medium) == U.type_class(op.medium) then
			if not op.medium:replace(o.medium, o, op) then
				return false
			end
			o.medium = op.medium
		end
		op.medium = nil
		op.context = nil
		op.data_cached = nil
		M.context.output_index[op.index] = nil
		M.context.output_by_destination[op.destination] = nil
		M.context.output_by_source[op.source] = nil
		o.index = op.index
	end
	if #o.destination > 0 then
		M.context.output_by_destination[o.destination] = o
	end
	if o.source ~= "<generated>" then
		M.context.output_by_source[o.source] = o
	end
	M.context.output_index[o.index] = o
	return true
end

function M.collect(cache)
	U.type_assert(cache, "boolean", true)

	if not cache then
		if M.context.collected then
			M.log("NOTE: already collected once this run")
		end

		M.log("collecting")
		if #M.context.filters == 0 then
			M.log("no filters")
		end
	end

	local num_accepted = 0
	local function do_filter(f, source, file, path)
		local o = path and M.context.output_by_source[path] or nil
		if o then
			local last_modified = FS.time_last_modified(path)
			if last_modified == o.last_modified then
				return
			end
			M.log("changed: %s%s", o.source, #o.destination > 0 and (" -> " .. o.destination) or "")
		end
		-- don't retry generation filters
		if f.processed and source == nil then
			return
		end
		local rv = f.filter(source, file, f.destination)
		if U.is_type(rv, "number") then
			num_accepted = num_accepted + U.max(0, rv)
		elseif rv then
			num_accepted = num_accepted + 1
		end
		f.processed = true
	end
	for _, f in ipairs(M.context.filters) do
		if #f.source == 0 then
			if not cache then
				M.log_chatter("processing filter: <generated>%s", f.destination and (" -> " .. f.destination) or "")
			end
			do_filter(f, nil, nil, nil)
		else
			for _, source in ipairs(f.source) do
				if not cache then
					M.log_chatter("processing filter: %s%s", source, f.destination and (" -> " .. f.destination) or "")
				end
				if not FS.is_directory(source) then
					M.error("source does not exist or is not a directory: %s", source)
				end
				for file, _ in FS.iterate_dir(source, FS.EntryType.file, false, true, false) do
					do_filter(f, source, file, M.path(source, file))
				end
			end
		end
	end

	M.context.collected = true

	if num_accepted > 0 then
		for _, f in ipairs(M.context.post_collect) do
			f()
		end
	end
	return num_accepted
end

function M.build_to_cache(all)
	U.type_assert(all, "boolean", true)

	for _, o in ipairs(M.context.output_index) do
		if all or not o.data_cached then
			if not M.context.built then
				M.log_chatter("cache: %s -> %s", o.source, o.destination)
			end
			o.data_cached = o.medium:data(o)
		end
	end
	M.context.built = true
end

function M.build_to_filesystem()
	if M.context.built then
		M.log("NOTE: already built once this run")
	end

	M.log("building to: %s", M.config.build_path)
	if not M.create_path(M.config.build_path) then
		M.error("failed to create build directory: %s", M.config.build_path)
	end

	M.log_chatter("removing stale build data")
	local check_stale_dirs = {}
	for name, entry_type in FS.iterate_dir(M.config.build_path, FS.EntryType.all, false, true, false) do
		if string.sub(name, 1, 4) == ".git" then
			goto l_continue
		end

		if entry_type == FS.EntryType.file then
			if M.context.output_by_destination[name] then
				goto l_continue
			end
			local path = M.path(M.config.build_path, name)
			M.log_chatter("remove (stale): %s", path)
			if not FS.remove_file(path) then
				M.error("failed to remove stale file: %s", path)
			end
		end

		if name ~= "" then
			-- if already a dir, this will remove a trailing slash
			name = U.path_dir(name)
			for i, dir in pairs(check_stale_dirs) do
				local min = U.min(#name, #dir)
				local max = U.max(#name, #dir)
				local a, b = string.find(string.sub(name, 1, min), string.sub(dir, 1, min), 1, true)
				if a == 1 then
					-- common prefix
					if b < max then
						-- replace with longest path
						check_stale_dirs[i] = #name > #dir and name or dir
					end
					-- else: equal
					goto l_continue
				end
			end
			table.insert(check_stale_dirs, name)
		end

		::l_continue::
	end

	-- NB: Hacky optimizations; might have some edge-cases
	table.sort(check_stale_dirs, function(l, r) return #l > #r end)
	local dir_removed = {}
	for _, dir in ipairs(check_stale_dirs) do
		for path in path_dir_iter(dir) do
			if dir_removed[path] then
				break
			end
			path = M.path(M.config.build_path, path)
			if not FS.is_empty_directory(path, true) then
				break
			end
			M.log_chatter("remove directory (stale): %s", path)
			if not FS.remove_directory(path) then
				M.error("failed to remove stale directory: %s", path)
			end
			dir_removed[path] = true
		end
	end

	if M.context.any_output then
		M.log("writing")
	else
		M.log("no output files")
	end
	for _, o in ipairs(M.context.output_index) do
		if #o.destination > 0 then
			local dir = U.path_dir(o.destination)
			if dir ~= "" and not M.create_path(M.path(M.config.build_path, dir)) then
				M.error("failed to create destination directory: %s", o.destination)
			end
			o.medium:write(o.source, M.path(M.config.build_path, o.destination), o.context)
		end
	end

	M.log("build complete")
	M.context.built = true
end

M.init()

return M

)"__RAW_STRING__"