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

		local dir = FS.path_dir(path)
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
	local log_level = P.LogLevel[value]
	if log_level == nil then
		return nil, "invalid value"
	end
	P.configure_default{log_level = log_level}
	return nil, true
end)
:filter({"--force-overwrite", "-f"}, "boolean", function(_, value)
	P.configure_default{force_overwrite = value}
	return nil, true
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
:transform(function(name, value)
	name, value = vf_opt_transform(name, value)
	local b = find_last(name, BYTE_DASH) or 0
	return string.sub(name, b + 1), value
end)
:filter("addr", "string")
:filter("delay", "string", function(_, value)
	local delay = tonumber(value)
	if delay == nil then
		return nil, "expected an integer"
	end
	return math.floor(delay)
end)
:filter("port", "string", function(_, value)
	local port = tonumber(value)
	if port == nil or port < 0 or port > 0xFFFF then
		return nil, "expected an integer in [0, 0xFFFF]"
	end
	return port
end)

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
		P.log("error: build: expected a single path")
		return false
	end
	local config = {
		delay = 1,
		addr = "127.0.0.1",
		port = 4000,
	}
	local err = server_vf:consume_safe(config, opts)
	if err then
		P.log("error: %s", err)
		return false
	end

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

	local server = Internal.make_server(
		config.addr,
		config.port,
		P.config.log_level >= P.LogLevel.debug
	)
	P.log("server started: http://%s:%d/", config.addr, config.port)

	local function handler(given_uri)
		if #given_uri > 1 and string.sub(given_uri, 1, 1) == '/' then
			given_uri = string.sub(given_uri, 2, -1)
		end
		local uri = given_uri
		if string.sub(uri, -1, -1) == '/' then
			uri = P.path(uri, "index.html")
		end
		local o = P.context.output[uri]
		local data = o and o.data_cached
		local status_code = (data ~= nil) and 200 or 404
		if not data then
			o = P.context.output["404.html"]
			data = o and o.data_cached
		end
		P.log_chatter(
			"GET %s%s => %s",
			given_uri,
			uri ~= given_uri and string.format(" => %s", uri) or "",
			status_code
		)
		return data, status_code
	end

	local signal_received = false
	local dir = FS.path_dir(main_path)
	local wp_orig = FS.working_dir()
	local now
	local last_collect = S.secs_since_epoch()

	Internal.set_signal_handler(Internal.SIGINT, function(_)
		Internal.set_signal_handler(Internal.SIGINT, nil)
		signal_received = true
	end)
	repeat
		if config.delay > 0 then
			now = S.secs_since_epoch()
			if now - last_collect > config.delay then
				P.log_debug("checking for changes")
				if not reload_main() then
					return false
				end
				if dir ~= "" then
					FS.set_working_dir(dir)
				end
				if P.collect(true) > 0 then
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