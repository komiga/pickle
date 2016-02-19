u8R""__RAW_STRING__(

local U = require "togo.utility"
local IO = require "togo.io"
local FS = require "togo.filesystem"
local S = require "togo.system"
local P = require "Pickle"
local Internal = require "Pickle.Internal"
local M = U.module(...)

M.info_text = "Pickle 0.00"
M.usage_text = [[
usage: pickle [options] <command> [command_parameters]
--log=info | chatter | debug
  set log level
  default: info

-f, --force-overwrite
  force-overwrite build output
  default: false
]]
M.help_hint = "\nuse `pickle help [command_name]` for help"

M.command = {}

local function find_last(s, b)
	for i = #s, 1, -1 do
		if string.byte(s, i) == b then
			return i
		end
	end
	return nil
end

local BYTE_DASH = string.byte('-', 1)

local function vf_opt_transform(_, pair)
	return pair.name, pair.value
end

local function load_script(path)
	local source = IO.read_file(path)
	if source == nil then
		P.log("error: failed to read main: %s", path)
		return nil
	end
	local main_chunk, err = load(source, "@" .. path, "t")
	if main_chunk == nil then
		P.log("error: failed to parse main: %s:", path)
		P.log(err)
		return nil
	end
	return main_chunk
end

local function script_path(given_path)
	if FS.is_directory(given_path) then
		given_path = P.path(given_path, "pickle.lua")
	end
	return given_path
end

local function do_script(paths, command_func)
	local success = true
	local wp_orig = FS.working_dir()
	for i, given_path in ipairs(paths) do
		given_path = given_path.value
		local path = script_path(given_path)
		if not FS.is_file(path) then
			P.log("error: file not found (as file or sub-file): %s", given_path)
			return nil
		end
		local main_chunk = load_script(path)
		if not main_chunk then
			return false
		end

		local dir = U.path_dir(path)
		if dir ~= "" then
			FS.set_working_dir(dir)
		end
		if not command_func(main_chunk) then
			break
		end
		FS.set_working_dir(wp_orig)

		if i ~= #paths then
			-- Reset config and context
			P.init()
		end
	end
	FS.set_working_dir(wp_orig)
	return success
end

local function make_command(bucket, names, help_text, func)
	names = U.is_type(names, "table") and names or {names}
	local cmd = {
		name = names[1],
		help_text = help_text,
		func = func,
	}
	for _, name in ipairs(names) do
		bucket[name] = cmd
	end
	table.insert(bucket, cmd)
end

local base_opt_vf = P.ValueFilter("Interface")
:transform(vf_opt_transform)
:filter("--log", "string", function(_, value)
	return nil, P.configure_default({log_level = P.LogLevel[value]}, true)
end)
:filter({"--force-overwrite", "-f"}, "boolean", function(_, value)
	return nil, P.configure_default({force_overwrite = value}, true)
end)

make_command(M.command,
"help", [[
help [command_name]
  prints help for pickle commands
]],
function(opts, params)
	local name = nil
	if #params > 0 then
		name = params[1].value
	end
	if name == nil then
		P.log("%s\n\n%s\n", M.info_text, M.usage_text)
	end
	for _, cmd in ipairs(M.command) do
		local equal = cmd.name == name
		if name == nil or equal then
			P.log(cmd.help_text)
			if name ~= nil then
				return true
			end
		end
	end
	if name ~= nil then
		P.log("unrecognized command: '%s'", name)
		return false
	end
	return true
end)

make_command(M.command,
"build", [[
build <path> [path ...]
  build site
]],
function(opts, params)
	if #params == 0 then
		P.log("error: build: expected parameters")
		return false
	end

	return do_script(params, function(main_chunk)
		main_chunk()
		if not P.context.collected then
			P.collect()
		end
		if not P.context.built then
			P.build_to_filesystem()
		end
	end)
end)

local server_vf = P.ValueFilter("ServerCommand")
:transform(vf_opt_transform)
:filter("--delay", "string", function(_, value)
	value = tonumber(value)
	if value == nil then
		return nil, "expected an integer"
	end
	return nil, P.configure_default({delay = value}, true)
end)
:filter("--addr", "string", function(_, value)
	return nil, P.configure_default({addr = value}, true)
end)
:filter("--port", "string", function(_, value)
	value = tonumber(value)
	if value == nil then
		return nil, "expected an integer"
	end
	return nil, P.configure_default({port = value}, true)
end)

local content_types = {}
do
	local function add_content_type(group, ext, real)
		content_types[ext] = group .. '/' .. (real or ext)
	end
	add_content_type("text", "css")
	add_content_type("text", "html")
	add_content_type("text", "xml")
	add_content_type("text", "js", "javascript")

	add_content_type("image", "svg", "svg+xml")
	add_content_type("image", "png")
	add_content_type("image", "jpg")
	add_content_type("image", "jpeg")
	add_content_type("image", "gif")
	add_content_type("image", "bmp")
	add_content_type("image", "ico")

	add_content_type("application", "woff", "font-woff")
	add_content_type("application", "otf", "font-sfnt")
	add_content_type("application", "ttf", "font-sfnt")
end

make_command(M.command,
"server", [[
server [--delay=<delay>] [--addr=<addr>] [--port=<port>] <path>
  start a server

  --delay=<delay>
    number of seconds to wait before recollecting
    delay <= 0 disables recollection
    default: 1

  --addr=<addr>
    bind to the given address
    default: 127.0.0.1

  --port=<port>
    bind to the given port
    default: 4000
]],
function(opts, params)
	if #params ~= 1 then
		P.log("error: server: expected a single path")
		return false
	end
	local err = server_vf:consume_safe(nil, opts)
	if err then
		P.log("error: %s", err)
		return false
	end

	P.configure_default{testing_mode = true}
	local main_path = script_path(params[1].value)
	local main_last_modified = 0
	local function reload_main()
		local last_modified = FS.time_last_modified(main_path)
		if main_last_modified == last_modified then
			return true
		elseif main_last_modified ~= 0 then
			P.log("reloading script: %s", main_path)
			P.init()
		end
		local success = do_script(params, function(main_chunk)
			main_chunk()
			if not P.context.collected then
				P.collect(true)
			end
			P.build_to_cache(main_last_modified ~= 0)
		end)
		main_last_modified = last_modified
		return success
	end
	if not reload_main() then
		return false
	end

	local server, err = Internal.make_server(
		P.config.addr,
		P.config.port,
		P.config.log_level >= P.LogLevel.debug
	)
	if err then
		P.log("error: failed to start server: %s", err)
		return false
	end
	P.log("server started: http://%s:%d/", P.config.addr, P.config.port)

	local function handler(given_uri)
		local uri = given_uri
		if string.sub(uri, -1, -1) == '/' then
			uri = P.path(given_uri, "index.html")
		end
		uri = U.trim_leading_slashes(uri)
		local o = P.context.output_by_destination[uri]
		if not o and not U.file_extension(uri) then
			uri = P.path(uri, "index.html")
			o = P.context.output_by_destination[uri]
		end
		local status_code = (o ~= nil) and 200 or 404
		local headers = {}
		if status_code == 404 then
			o = P.context.output_by_destination["404.html"]
			if o then
				uri = "404.html"
			end
		end
		headers["Content-Type"] = content_types[U.file_extension(uri)] or "text/plain"

		P.log_chatter(
			"GET %s%s => %s",
			given_uri,
			('/' .. uri) ~= given_uri and string.format(" => %s", uri) or "",
			status_code
		)
		return o.data_cached, status_code, headers
	end

	local signal_received = false
	local dir = U.path_dir(main_path)
	local wp_orig = FS.working_dir()
	local now
	local last_collect = S.secs_since_epoch()

	Internal.set_signal_handler(Internal.SIGINT, function(_)
		Internal.set_signal_handler(Internal.SIGINT, nil)
		signal_received = true
	end)
	repeat
		if P.config.delay > 0 then
			now = S.secs_since_epoch()
			if now - last_collect > P.config.delay then
				P.log_debug("looking for changes")
				if not reload_main() then
					return false
				end
				if dir ~= "" then
					FS.set_working_dir(dir)
				end
				if P.collect(true) > 0 then
					P.log_chatter("rebuilding all")
					P.build_to_cache(true)
				end
				last_collect = S.secs_since_epoch()
				if dir ~= "" then
					FS.set_working_dir(wp_orig)
				end
			end
		end
		server:update(handler)
		S.sleep_ms(50)
	until signal_received
	server:stop()
	return true
end)

function M.main(argv)
	local _, opts, cmd_opts, cmd_params = U.parse_args(argv)
	opts.name = nil
	cmd_opts.name = nil

	local err = base_opt_vf:consume_safe(nil, opts)
	if err then
		P.log("error: %s", err)
		return false
	end

	local cmd = M.command[cmd_params.name]
	if not cmd then
		if cmd_params.name ~= "" then
			P.log("error: command '%s' not recognized", cmd_params.name)
		else
			P.log("error: expected command")
		end
		P.log(M.help_hint)
		return false
	end

	return true == cmd.func(cmd_opts, cmd_params)
end

return M

)"__RAW_STRING__"