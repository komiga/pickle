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

local config_values = {}
local function config_value(name, tc, func)
	config_values[name] = function(config, value)
		if tc then
			U.type_assert(value, tc)
		end
		if func then
			value = func(value)
		end
		config[name] = value
	end
end

config_value("log_level", nil, function(value)
	if U.is_type(value, "string") then
		value = M.LogLevel[value]
	end
	if U.is_type(value, "number") and value >= M.LogLevel.info and value <= M.LogLevel.debug then
		return value
	end
	M.error("config.log_level is invalid: %s", tostring(value))
end)

config_value("force_overwrite", "boolean")

config_value("build_path", "string", function(value)
	return value
	-- return FS.trim_trailing_slashes(value)
end)

local function do_configure(config, input)
	for name, value in pairs(input) do
		local f = config_values[name]
		if not f then
			M.error("config value '%s' not found", name)
		end
		f(config, value)
	end
end

function M.configure(config)
	do_configure(M.config, config)
end

function M.configure_default(config)
	do_configure(M.config_default, config)
	M.configure(config)
end

function M.init()
	M.config = {}
	M.context = {
		collected = false,
		built = false,
		template_cache = {},
		filters = {},
		output = {},
		output_files = {},
	}
	M.configure(M.config_default)
end

function M.path(...)
	local parts = {...}
	local path = ""
	for i, p in pairs(parts) do
		if p ~= nil and p ~= "" then
			U.type_assert(p, "string")
			path = path .. p
			if i ~= #parts and string.byte(p, -1) ~= BYTE_SLASH then
				path = path .. "/"
			end
		end
	end
	if string.byte(path, -1) == BYTE_SLASH then
		path = string.sub(path, 1, -2)
	end
	return path
end

local function path_dir_iter_func(init_path, path)
	if path == nil then
		return init_path
	end
	path = FS.path_dir(path)
	return path ~= "" and path or nil
end

local function path_dir_iter(init_path)
	U.type_assert(init_path, "string")
	return path_dir_iter_func, init_path, nil
end

function M.create_path(path)
	if not FS.is_directory(path) then
		for path in path_dir_iter(path) do
			if not FS.create_directory(path, true) then
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
		return string.gsub(str, html_group, html_sub)
	end
	return M.tpl_out(str)
end

local chunk_metatable = {
	__index = function(t, k)
		return rawget(t, k) or rawget(t, "C")[k] or _G[k]
	end,
	__newindex = function(t, k, v)
		rawget(t, "C")[k] = v
	end,
}

local BYTE_NEWLINE = string.byte("\n")

function M.Template:__init(path, data)
	U.type_assert(path, "string", true)
	U.type_assert(data, "string", path ~= nil)

	if path == nil then
		path = "<generated>"
	end

	self.env = {P = M, C = nil}
	self.path = path

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
		M.log_debug("template prelude: %s:\n`%s`", path, prelude_data)
		func, err = load(prelude_data, "@" .. path, "t", setmetatable(self.env, chunk_metatable))
		if err then
			M.error("failed to read prelude as Lua: %s", err)
		end
		self.prelude_func = func
		data = string.sub(data, U.min(#data, csep_end + 1), -1)
	else
		self.prelude_func = nil
	end

	local row, col
	data, err, row, col = Internal.template_transform(data)
	if err then
		M.error("syntax error in template: %s:%d:%d: %s", path, row, col, err)
	end
	M.log_debug("template content: %s:\n`%s`", path, data)
	func, err = load(data, "@" .. path, "t", setmetatable(self.env, chunk_metatable))
	if err then
		M.error("failed to read transformed template as Lua: %s", err)
	end
	self.content_func = func
end

function M.Template:prelude(context)
	U.type_assert(context, "table", true)
	self.env.C = context or {}
	return self.prelude_func()
end

function M.Template:content(context)
	U.type_assert(context, "table", true)
	self.env.C = context or {}
	return self.content_func()
end

function M.add_template_cache(tpl, name)
	U.type_assert(tpl, M.Template)
	if not name or name == "" or name == "<generated>" then
		name = tpl.path
	end
	if name == "<generated>" then
		P.error("cannot cache generated template")
	end
	U.type_assert(name, "string")
	M.context.template_cache[name] = tpl
end

function M.get_template(name)
	if name == "" or name == "<generated>" then
		name = nil
	end
	local tpl
	if U.is_type(name, M.Template) then
		tpl = name
	elseif name ~= nil then
		tpl = M.context.template_cache[name]
	end
	if not tpl then
		tpl = M.Template(name)
		M.do_add_template_cache(tpl, name)
	end
	return tpl
end

-- (source, filter)
-- (source, destination, filter)
function M.filter(a, b, c)
	local source, destination, filter

	source = a
	if c == nil then
		destination = nil
		filter = b
	else
		destination = U.type_assert(b, "string")
		filter = c
	end

	U.type_assert_any(source, {"string", "table"})
	U.assert(U.is_type(filter, "function") or U.is_functable(filter))

	table.insert(M.context.filters, {
		source = U.is_type(source, "table") and source or {source},
		destination = destination == "" and nil or destination,
		filter = filter,
	})
end

function M.copy_file(source, destination, _, _)
	local same = not M.config.force_overwrite and casual_file_same(source, destination)
	M.log_chatter("copy: %s -> %s%s", source, destination, same and " [same]" or "")
	if
		not same and
		not FS.copy_file(source, destination, true)
	then
		M.error_output("failed to copy file", source, destination)
	end
end

function M.write_string(source, destination, data, _)
	M.log_chatter("string: %s -> %s", source, destination)
	if not IO.write_file(destination, data) then
		M.error_output("failed to write file", source, destination)
	end
end

function M.write_template(source, destination, tpl, context)
	M.log_chatter("template: %s -> %s", source, destination)
	local data = tpl:content(context or {})
	if not IO.write_file(destination, data) then
		M.error_output("failed to write file", source, destination)
	end
end

function M.output(source, destination, data, context)
	source = U.type_assert(source, "string", true) or "<generated>"
	U.type_assert(destination, "string")
	U.type_assert_any(data, {"function", "string", M.Template})

	local o = {
		source = source,
		destination = destination,
		func = nil,
		data = data,
		context = context,
	}

	if U.is_type(data, "function") then
		o.func = data
	elseif U.is_type(data, "string") then
		o.func = M.write_string
	elseif U.is_type(data, M.Template) then
		o.func = M.write_template
	end

	if M.context.output_files[o.destination] then
		M.error("output destination already specified as %s -> %s", o.source, o.destination)
	end
	M.context.output_files[o.destination] = o
	table.insert(M.context.output, o)
end

function M.collect()
	if M.context.collected then
		M.log("NOTE: already collected once this run")
	end
	if #M.context.filters == 0 then
		M.log("no filters")
		return
	end

	M.log("collecting")
	for _, f in ipairs(M.context.filters) do
		for _, source in ipairs(f.source) do
			M.log_chatter("processing filter: %s%s", source, f.destination and (" -> " .. f.destination) or "")
			if not FS.is_directory(source) then
				M.error("source does not exist or is not a directory: %s", source)
			end
			for file, _ in FS.iterate_dir(source, FS.EntryType.file, false, true, false) do
				f.filter(source, file, f.destination)
			end
		end
	end
	M.context.collected = true
end

function M.build()
	if M.context.built then
		M.log("NOTE: already built once this run")
	end

	M.log("building to: %s", M.config.build_path)
	if not M.create_path(M.config.build_path) then
		M.error("failed to create build directory: %s", M.config.build_path)
	end

	M.log("removing stale build data")
	local check_stale_dirs = {}
	for name, entry_type in FS.iterate_dir(M.config.build_path, FS.EntryType.all, false, true, false) do
		if entry_type == FS.EntryType.file then
			if M.context.output_files[name] then
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
			name = FS.path_dir(name)
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

	M.log("writing")
	if #M.context.output == 0 then
		M.log("no output files")
	else
		for _, o in ipairs(M.context.output) do
			local dir = FS.path_dir(o.destination)
			if dir ~= "" and not M.create_path(M.path(M.config.build_path, dir)) then
				M.error("failed to create destination directory: %s", o.destination)
			end
			o.func(o.source, M.path(M.config.build_path, o.destination), o.data, o.context)
		end
	end

	M.context.built = true
	M.log("build complete")
end

M.init()

return M

)"__RAW_STRING__"