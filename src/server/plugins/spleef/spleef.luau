-- Spleef: break the floor, drop your rivals. The host owns arena protection,
-- exclusive membership, teleports, bounded restoration, and movement-policy
-- evidence; this script owns match phases, batching, and presentation.

local cfg = server.config or {}
local function number(field, default, min, max)
	local value = tonumber(cfg[field]) or default
	if value < min then value = min end
	if value > max then value = max end
	return value
end

local countdown_ms = number("countdown_seconds", 10, 3, 120) * 1000
local results_ms = number("results_seconds", 8, 3, 120) * 1000
local tick_ms = number("tick_ms", 250, 100, 2000)
local max_participants = number("max_participants", 16, 2, 16)
local flight_dq = number("flight_dq_violations", 3, 1, 10)
local kick_on_flight = cfg.kick_on_flight == true

local template_key = "arena"
local state = "unconfigured" -- unconfigured|waiting|countdown|active|results|reset
local box, elim_height, entry, spectator
local region, session
local players = {} -- id -> {gen, name, eliminated, batch, departed, violations}
local pending = {} -- elimination batch candidates, id -> true
local batch_count = 0
local phase_end = 0

local function in_box(b, x, y, z)
	return x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 and z >= b.z0 and z <= b.z1
end

local function active_members()
	local members = {}
	if not session then return members end
	for _, m in ipairs(session:members()) do
		local p = players[m.id]
		if p and p.gen == m.gen and not p.eliminated then members[#members + 1] = m end
	end
	return members
end

local function ready_in_arena()
	local count = 0
	if not session then return 0 end
	for _, m in ipairs(session:members()) do
		local p = players[m.id]
		if p and p.gen == m.gen and not p.eliminated and in_box(box, m.x, m.y, m.z) then
			count = count + 1
		end
	end
	return count
end

local function load_arena()
	if server.store_get("ready") ~= 1 then return end
	local b = {
		x0 = server.store_get("x0"), y0 = server.store_get("y0"), z0 = server.store_get("z0"),
		x1 = server.store_get("x1"), y1 = server.store_get("y1"), z1 = server.store_get("z1"),
	}
	region = server.claim(b)
	if not region then
		server.log("Spleef arena claim conflicts with another plugin; recapture a non-overlapping arena")
		return
	end
	box = b
	elim_height = server.store_get("elim")
	entry = { x = server.store_get("entry_x"), y = server.store_get("entry_y"), z = server.store_get("entry_z") }
	spectator = { x = server.store_get("spec_x"), y = server.store_get("spec_y"), z = server.store_get("spec_z") }
	state = "waiting"
end
load_arena()

local function ensure_session()
	if session then return session end
	session = server.create_session({ capacity = max_participants })
	return session
end

local function drop_player(id)
	local p = players[id]
	players[id] = nil
	if session and p then
		session:remove({ id = id, gen = p.gen })
	end
end

local function join(caller)
	local s = ensure_session()
	if not s then
		server.send_message(caller, "Spleef cannot open another match right now")
		return
	end
	local index = #s:members()
	if not s:admit(caller) then
		server.send_message(caller, "You are already in another game")
		return
	end
	players[caller.id] = { gen = caller.gen, name = caller.name, eliminated = false, batch = 0, departed = false, violations = 0 }
	local tx = math.min(entry.x + (index % 8) * 2, box.x1)
	if not s:travel(caller, tx, entry.y, entry.z) then
		server.send_message(caller, "Walk into the arena to take part")
	end
	s:announce("&e" .. caller.name .. " joined spleef")
end

local function leave_or_forfeit(caller)
	local p = players[caller.id]
	if not p or p.gen ~= caller.gen then
		server.send_message(caller, "You are not in the match")
		return
	end
	if state == "active" then
		p.departed = true
		pending[caller.id] = true
		server.send_message(caller, "You forfeit the match")
		return
	end
	drop_player(caller.id)
	server.send_message(caller, "You left the match")
	if session then
		session:announce("&e" .. p.name .. " left spleef (" .. #active_members() .. " ready)")
	end
end

local function finish(s, survivors)
	state = "results"
	phase_end = server.now() + results_ms
	local offset = (#survivors > 0) and 2 or 1
	local places = {}
	for _, p in pairs(players) do
		if p.batch > 0 then
			local place = batch_count - p.batch + offset
			local group = places[place]
			if not group then
				group = { names = {}, departed = 0 }
				places[place] = group
			end
			table.insert(group.names, p.name)
			if p.departed then group.departed = group.departed + 1 end
		end
	end

	if #survivors == 1 then
		s:announce("&6" .. survivors[1].name .. " wins spleef!")
	elseif places[1] and places[1].departed == #places[1].names then
		s:announce("&eThe match ended without a winner")
	elseif places[1] then
		s:announce("&eDraw: " .. table.concat(places[1].names, ", "))
	end
	-- Place 1 is covered by the winner/draw line above; share the rest.
	local labels = { [2] = "&e2nd place", [3] = "&e3rd place" }
	for place = 2, 3 do
		local group = places[place]
		if group then
			s:announce(labels[place] .. ": " .. table.concat(group.names, ", "))
		end
	end
end

local function begin_reset()
	state = "reset"
	if session then session:lock_travel(false) end
	if not (box and region) then
		if session then session:finish() session = nil end
		players = {}
		pending = {}
		state = box and "waiting" or "unconfigured"
		return
	end
	server.restore(box, template_key, function(ok)
		if ok then
			server.clear_dirty(template_key)
		else
			server.log("Spleef arena restore failed; startup recovery will repair it")
		end
		if session then session:finish() session = nil end
		players = {}
		pending = {}
		batch_count = 0
		state = "waiting"
		server.broadcast("&eThe spleef arena is open again")
	end)
end

local function start_match(s)
	-- The arena may now be damaged, so the recovery record must exist before
	-- the first breakable block.
	if not server.mark_dirty(box, template_key) then
		s:announce("&cSpleef arena preparation failed; the match cannot start")
		return
	end
	s:lock_travel(true)
	batch_count = 0
	pending = {}
	state = "active"
	s:announce("&eGO! Break the floor and drop your rivals!")
end

local function process_eliminations(s)
	local ids = {}
	for id in pairs(pending) do ids[#ids + 1] = id end
	if #ids == 0 then return end
	pending = {}
	batch_count = batch_count + 1
	local fell = {}
	for _, id in ipairs(ids) do
		local p = players[id]
		if p and not p.eliminated then
			p.eliminated = true
			p.batch = batch_count
			fell[#fell + 1] = p.name
			if not p.departed then
				s:travel({ id = id, gen = p.gen }, spectator.x, spectator.y, spectator.z)
			end
		end
	end
	if #fell == 0 then return end
	s:announce("&eFell: " .. table.concat(fell, ", "))
	local survivors = active_members()
	if #survivors <= 1 then finish(s, survivors) end
end

local pos1, pos2, elim_override

local function capture_arena(caller)
	if state ~= "unconfigured" and state ~= "waiting" then
		server.send_message(caller, "Cannot reconfigure during a match")
		return
	end
	if not (pos1 and pos2 and entry and spectator) then
		server.send_message(caller, "Set pos1, pos2, entry, and spectate first")
		return
	end
	local b = {
		x0 = math.min(pos1.x, pos2.x), y0 = math.min(pos1.y, pos2.y), z0 = math.min(pos1.z, pos2.z),
		x1 = math.max(pos1.x, pos2.x), y1 = math.max(pos1.y, pos2.y), z1 = math.max(pos1.z, pos2.z),
	}
	if not server.capture(b, template_key) then
		server.send_message(caller, "Capture failed: the arena must be inside the world and at most 262144 blocks")
		return
	end
	if region then region:release() region = nil end
	region = server.claim(b)
	if not region then
		server.send_message(caller, "The arena overlaps another plugin's protected region")
		return
	end
	server.clear_dirty(template_key)
	elim_height = elim_override or b.y0
	box = b
	server.store_set("x0", b.x0)
	server.store_set("y0", b.y0)
	server.store_set("z0", b.z0)
	server.store_set("x1", b.x1)
	server.store_set("y1", b.y1)
	server.store_set("z1", b.z1)
	server.store_set("elim", elim_height)
	server.store_set("entry_x", entry.x)
	server.store_set("entry_y", entry.y)
	server.store_set("entry_z", entry.z)
	server.store_set("spec_x", spectator.x)
	server.store_set("spec_y", spectator.y)
	server.store_set("spec_z", spectator.z)
	server.store_set("ready", 1)
	state = "waiting"
	server.send_message(caller, "Spleef arena captured; players can join with /spleef")
end

server.register_command{
	name = "spleef",
	description = "Join or leave the spleef match.",
	caller = "player",
	handler = function(caller)
		if not box then
			server.send_message(caller, "Spleef is not configured; an operator must set up the arena")
			return
		end
		local p = players[caller.id]
		if p and p.gen ~= caller.gen then
			players[caller.id] = nil
			p = nil
		end
		if p then
			leave_or_forfeit(caller)
			return
		end
		if state == "active" or state == "countdown" then
			server.send_message(caller, "A match is already underway")
			return
		end
		if state ~= "waiting" then
			server.send_message(caller, "Please wait for the arena to reset")
			return
		end
		join(caller)
	end,
}

server.register_command{
	name = "spleefop",
	description = "Configure and run the spleef arena.",
	arguments = {
		{ name = "action", type = "string", description = "pos1, pos2, entry, spectate, height, capture, unclaim, or end" },
		{ name = "y", type = "number", optional = true, description = "Elimination height (height only)" },
	},
	caller = "player",
	permission = "op",
	handler = function(caller, args)
		local action = args.action
		if action == "pos1" then
			pos1 = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Spleef corner 1 set")
		elseif action == "pos2" then
			pos2 = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Spleef corner 2 set")
		elseif action == "entry" then
			entry = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Spleef entry spot set")
		elseif action == "spectate" then
			spectator = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Spleef spectator spot set")
		elseif action == "height" then
			if not args.y then
				server.send_message(caller, "Usage: /spleefop height <y>")
				return
			end
			elim_override = math.floor(args.y)
			server.send_message(caller, "Elimination height set to " .. elim_override)
		elseif action == "unclaim" then
			if region then region:release() region = nil end
			state = "unconfigured"
			server.send_message(caller, "Spleef arena released; edit the world, then capture again")
		elseif action == "capture" then
			capture_arena(caller)
		elseif action == "end" then
			if state == "active" or state == "countdown" or state == "results" then
				begin_reset()
				server.send_message(caller, "Spleef match ended")
			else
				server.send_message(caller, "No match is running")
			end
		else
			server.send_message(caller, "Usage: /spleefop <pos1|pos2|entry|spectate|height|capture|unclaim|end>")
		end
	end,
}

server.set_interval(function()
	if state == "waiting" then
		if session and ready_in_arena() >= 2 then
			state = "countdown"
			phase_end = server.now() + countdown_ms
			session:announce("&eSpleef starts in " .. (countdown_ms / 1000) .. " seconds!")
		end
	elseif state == "countdown" then
		local s = session
		if not s or ready_in_arena() < 2 then
			state = "waiting"
			if s then s:announce("&eCountdown paused; need at least two players in the arena") end
			return
		end
		if server.now() >= phase_end then
			start_match(s)
		end
	elseif state == "active" then
		if session then process_eliminations(session) end
	elseif state == "results" then
		if server.now() >= phase_end then begin_reset() end
	end
end, tick_ms)

server.on_player_move(function(player, x, y, z)
	if state ~= "active" or not elim_height then return end
	local p = players[player.id]
	if not p or p.gen ~= player.gen or p.eliminated then return end
	if y < elim_height then pending[player.id] = true end
end)

server.on_movement_violation(function(player, kind)
	if state ~= "active" then return end
	local p = players[player.id]
	if not p or p.gen ~= player.gen or p.eliminated then return end
	p.violations = p.violations + 1
	if p.violations < flight_dq then
		server.send_message(player, "&cMovement violation " .. p.violations .. "/" .. flight_dq .. " (" .. kind .. ")")
		return
	end
	server.broadcast("&e" .. p.name .. " was disqualified for flying")
	pending[player.id] = true
	if kick_on_flight then
		server.kick(player, "Flying in spleef")
	end
end)

server.on_player_leave(function(player)
	local p = players[player.id]
	if not p or p.gen ~= player.gen then return end
	if state == "active" then
		p.departed = true
		pending[player.id] = true
		server.broadcast("&e" .. p.name .. " forfeited (disconnected)")
	else
		players[player.id] = nil
		if session and state ~= "reset" then
			session:announce("&e" .. p.name .. " left spleef")
		end
	end
end)

server.on_block_attempt(function(player, attempt)
	if not (box and region) then return nil end
	if not in_box(box, attempt.x, attempt.y, attempt.z) then return nil end
	local p = players[player.id]
	if not p or p.gen ~= player.gen then return "deny" end
	if attempt.mode == "create" then return "deny" end
	if state ~= "active" or p.eliminated then return "deny" end
	return nil
end)
