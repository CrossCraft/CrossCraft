-- Essentials: baseline general-purpose commands.
-- Reply targets are connection handles keyed by sender slot; they are cleared
-- when the target connection ends so slot reuse cannot redirect a reply.

local last_reply = {}

local function usage(caller, text)
	server.send_message(caller, text)
end

local function deliver(sender, target, text)
	if not server.send_message(target, "&7[from " .. sender.name .. "] " .. text) then
		server.send_message(sender, "Player is no longer connected")
		return false
	end
	-- Both sides can reply; targets are generation-checked handles that the
	-- leave handler clears, so a reused slot never redirects a reply.
	last_reply[sender.id] = target
	last_reply[target.id] = sender
	return true
end

server.register_command{
	name = "msg",
	usage = "&e/msg <player> <message>",
	caller = "player",
	handler = function(caller, args)
		local target_name = args[1]
		if not target_name then
			usage(caller, "Usage: /msg <player> <message>")
			return
		end
		local text = table.concat(args, " ", 2)
		if text == "" then
			usage(caller, "Usage: /msg <player> <message>")
			return
		end
		local target = server.find_player(target_name)
		if not target then
			usage(caller, "Player not found: " .. target_name)
			return
		end
		deliver(caller, target, text)
	end,
}

server.register_command{
	name = "reply",
	aliases = {"r"},
	usage = "&e/reply <message> (alias: /r)",
	caller = "player",
	handler = function(caller, args)
		local target = last_reply[caller.id]
		if not target then
			usage(caller, "Nobody to reply to")
			return
		end
		local text = table.concat(args, " ")
		if text == "" then
			usage(caller, "Usage: /reply <message>")
			return
		end
		deliver(caller, target, text)
	end,
}

server.register_command{
	name = "tp",
	usage = "&e/tp <player> -- or -- /tp <x> <y> <z>",
	caller = "player",
	permission = "op",
	handler = function(caller, args)
		if args[1] and not tonumber(args[1]) then
			local target = server.find_player(args[1])
			if not target then
				usage(caller, "Player not found: " .. args[1])
				return
			end
			if not server.teleport(caller, target.x, target.y, target.z) then
				usage(caller, "Teleport failed; destination may be unsafe")
			end
			return
		end
		local x = tonumber(args[1])
		local y = tonumber(args[2])
		local z = tonumber(args[3])
		if not x or not y or not z then
			usage(caller, "Usage: /tp <player> -- or -- /tp <x> <y> <z>")
			return
		end
		if not server.teleport(caller, x, y, z) then
			usage(caller, "Teleport failed; destination may be unsafe")
		end
	end,
}

local spawn_enabled = true
if server.config.spawn ~= nil and server.config.spawn.enabled == false then
	spawn_enabled = false
end

if spawn_enabled then
	server.register_command{
		name = "spawn",
		usage = "&e/spawn -- return to the stable spawn",
		caller = "player",
		handler = function(caller)
			local x, y, z = server.get_spawn()
			if not server.teleport(caller, x, y, z) then
				usage(caller, "Spawn is currently unsafe")
			end
		end,
	}
end

server.register_command{
	name = "setspawn",
	usage = "&e/setspawn -- set the stable spawn to your position",
	caller = "player",
	permission = "op",
	handler = function(caller)
		if not server.set_spawn(caller.x, caller.y, caller.z) then
			usage(caller, "That position is not a safe spawn")
			return
		end
		usage(caller, "Stable spawn updated")
	end,
}

server.on_player_leave(function(player)
	last_reply[player.id] = nil
	for sender_id, target in pairs(last_reply) do
		if target.id == player.id then
			last_reply[sender_id] = nil
		end
	end
end)
