u8R""__RAW_STRING__(

local U = require "togo.utility"
local IO = require "togo.io"
local FS = require "togo.filesystem"
local P = require "Pickle"
local M = U.module(...)

M.info_text = "Pickle 0.00"
M.usage_text = "usage: pickle [options] <command> [command_parameters]"
M.help_hint = "\nuse `pickle help [command_name]` for help"

M.option = {}
M.command = {}

local function load_script(path)
	local source = IO.read_file(path)
	if source == nil then
		P.log("error: failed to read main: %s", path)
		return nil
	end
	local main_chunk = loadstring(source, "@" .. path)
	if main_chunk == nil then
		P.log("error: failed to parse main: %s", path)
		return nil
	end
	return main_chunk
end

local function do_script(paths, command_func)
	local success = true
	local wp_orig = FS.working_dir()
	for _, given_path in ipairs(paths) do
		given_path = given_path.value

		local path = given_path
		if FS.is_directory(path) then
			path = P.path(path, "pickle.lua")
		end
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

		-- Reset config and context
		P.init()
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

make_command(M.option,
"--log", [[
--log=info | chatter | debug
  set log level
]],
function(value)
	if not U.is_type(value, "string") then
		P.log("error: --log takes a string, not a %s", U.type_class(value))
		return false
	end
	local log_level = P.LogLevel[value]
	if not log_level then
		P.log("error: --log of '%s' is invalid", value)
		return false
	end
	P.configure_default{log_level = log_level}
	return true
end)

make_command(M.option,
{"--force-overwrite", "-f"}, [[
-f, --force-overwrite
  force-overwrite build output
]],
function(value)
	if not U.is_type(value, "boolean") then
		P.log("error: --log takes a boolean, not a %s", U.type_class(value))
		return false
	end
	P.configure_default{force_overwrite = value}
	return true
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

		for _, opt in ipairs(M.option) do
			P.log(opt.help_text)
		end
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
			P.build()
		end
	end)
end)

function M.main(argv)
	local _, opts, cmd_opts, cmd_params = U.parse_args(argv)
	for _, p in ipairs(opts) do
		local opt = M.option[p.name]
		if not opt then
			P.log("error: option '%s' not recognized", p.name)
			P.log(M.help_hint)
			return false
		end
		if not opt.func(p.value) then
			return false
		end
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