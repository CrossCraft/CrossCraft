-- Essentials: baseline general-purpose commands.
-- Reply targets are connection handles keyed by sender slot; they are cleared
-- when the target connection ends so slot reuse cannot redirect a reply.

local last_reply = {}

local function notify(caller, text)
	server.send_message(caller, text)
end

local function deliver(sender, target, text)
	if not server.send_message(target, "&7[from " .. sender.name .. "] " .. text) then
		notify(sender, "Player is no longer connected")
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
	description = "Send a private message.",
	arguments = {
		{ name = "player", type = "string", description = "Player to message" },
		{ name = "message", type = "string", variadic = true, description = "Message text" },
	},
	caller = "player",
	handler = function(caller, args)
		local target = server.find_player(args.player)
		if not target then
			notify(caller, "Player not found: " .. args.player)
			return
		end
		deliver(caller, target, args.message)
	end,
}

server.register_command{
	name = "reply",
	aliases = {"r"},
	description = "Reply to the last private message.",
	arguments = {
		{ name = "message", type = "string", variadic = true, description = "Message text" },
	},
	caller = "player",
	handler = function(caller, args)
		local target = last_reply[caller.id]
		if not target then
			notify(caller, "Nobody to reply to")
			return
		end
		deliver(caller, target, args.message)
	end,
}

-- Overloaded signatures (/tp <player> vs /tp <x> <y> <z>) do not fit the
-- single-form argument table, so this one keeps a raw usage string.
server.register_command{
	name = "tp",
	usage = "&e/tp <player> -- or -- /tp <x> <y> <z>",
	caller = "player",
	permission = "op",
	handler = function(caller, args)
		if args[1] and not tonumber(args[1]) then
			local target = server.find_player(args[1])
			if not target then
				notify(caller, "Player not found: " .. args[1])
				return
			end
			if not server.teleport(caller, target.x, target.y, target.z) then
				notify(caller, "Teleport failed; destination may be unsafe")
			end
			return
		end
		local x = tonumber(args[1])
		local y = tonumber(args[2])
		local z = tonumber(args[3])
		if not x or not y or not z then
			notify(caller, "Usage: /tp <player> -- or -- /tp <x> <y> <z>")
			return
		end
		if not server.teleport(caller, x, y, z) then
			notify(caller, "Teleport failed; destination may be unsafe")
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
		description = "Return to the stable spawn.",
		caller = "player",
		handler = function(caller)
			local x, y, z = server.get_spawn()
			if not server.teleport(caller, x, y, z) then
				notify(caller, "Spawn is currently unsafe")
			end
		end,
	}
end

server.register_command{
	name = "setspawn",
	description = "Set spawn to current position.",
	arguments = {
		{
			name = "p",
			optional = true,
			type = "string",
			description = "Player to target (default: yourself)",
		},
	},
	caller = "player",
	permission = "op",
	handler = function(caller, args)
		local x, y, z = caller.x, caller.y, caller.z
		if args.p then
			local target = server.find_player(args.p)
			if not target then
				notify(caller, "Player not found: " .. args.p)
				return
			end
			x, y, z = target.x, target.y, target.z
		end
		if not server.set_spawn(x, y, z) then
			notify(caller, "That position is not a safe spawn")
			return
		end
		notify(caller, "Stable spawn updated")
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
