-- Build Battle: build on your plot, then judge each other's work.
-- The host owns the arena claim (frozen, so simulation never touches builds),
-- plot clearing/restoration jobs, exclusive membership, session teleports, and
-- the mutation guard; this script owns phases, plot assignment, and voting.

local cfg = server.config or {}
local function number(field, default, min, max)
	local value = tonumber(cfg[field]) or default
	if value < min then value = min end
	if value > max then value = max end
	return value
end

local build_seconds = math.floor(number("build_seconds", 180, 1, 1200))
local judge_seconds = math.floor(number("judge_seconds", 20, 1, 120))
local gather_seconds = math.floor(number("gather_seconds", 60, 1, 300))
local tick_ms = math.floor(number("tick_ms", 250, 50, 2000))

local themes = {}
if type(cfg.themes) == "table" then
	for _, t in ipairs(cfg.themes) do
		if type(t) == "string" and #t > 0 then themes[#themes + 1] = t end
	end
end
if #themes == 0 then
	themes = { "Castle", "Spaceship", "Pirate Cove", "Farm", "Underwater", "Haunted House", "Racetrack", "Festival" }
end

-- Plot geometry: the operator's arena box contains a grid of 15x15x15
-- editable volumes (rows of up to 4) plus foundations, walkways, and viewing
-- spots, all outside the volumes. Plots start one layer above the box bottom
-- so the operator-built floor is never editable.
local PLOT = 15
local GAP = 4
local MARGIN_X = 2
local MARGIN_Z = 3
local FRONT = 2
local MAX_PLOTS = 8

local template_key = "arena"
local state = "unconfigured" -- unconfigured|waiting|preparation|building|judging|results|reset
local box, region, session
local plot_count = math.floor(number("plots", 4, 2, MAX_PLOTS))
local plots = {} -- 1..plot_count: {box, view, owner_id, owner_gen, owner_name, withdrawn, votes}
local players = {} -- id -> {gen, name, plot}
local pos1, pos2
local prep_list, prep_index, prep_failed, reset_wait_fills
local theme, build_end, vote_end, phase_end
local current_vote_plot, judge_queue, judge_cursor

local function build_layout()
	plots = {}
	for i = 1, plot_count do
		local col = (i - 1) % 4
		local row = math.floor((i - 1) / 4)
		local px = box.x0 + MARGIN_X + col * (PLOT + GAP)
		local pz = box.z0 + MARGIN_Z + row * (PLOT + GAP)
		local py = box.y0 + 1
		plots[i] = {
			box = { x0 = px, y0 = py, z0 = pz, x1 = px + PLOT - 1, y1 = py + PLOT - 1, z1 = pz + PLOT - 1 },
			view = { x = px + 7, y = py, z = pz - FRONT },
			owner_id = nil, owner_gen = nil, owner_name = nil, withdrawn = false, votes = {},
		}
	end
end

if server.store_get("ready") == 1 then
	box = {
		x0 = server.store_get("x0"), y0 = server.store_get("y0"), z0 = server.store_get("z0"),
		x1 = server.store_get("x1"), y1 = server.store_get("y1"), z1 = server.store_get("z1"),
	}
	local stored = server.store_get("plots")
	if type(stored) == "number" then
		plot_count = math.max(2, math.min(MAX_PLOTS, math.floor(stored)))
	end
	region = server.claim(box)
	if region then
		build_layout()
		state = "waiting"
	else
		server.log("Build Battle arena claim conflicts with another plugin; recapture a non-overlapping arena")
		box = nil
	end
end

-- Destructive rounds end by restoring the captured template; the dirty record
-- is cleared only after that restore succeeds, so a crash can never leave a
-- half-cleared arena.
local function start_restore()
	state = "reset"
	current_vote_plot = nil
	if not (box and region) then
		state = box and "waiting" or "unconfigured"
		return
	end
	server.restore(box, template_key, function(ok)
		if ok then
			server.clear_dirty(template_key)
		else
			server.log("Build Battle arena restore failed; startup recovery will repair it")
		end
		state = "waiting"
		server.broadcast("&eThe build battle arena is open again")
	end)
end

local function begin_reset()
	-- During preparation the fill chain is still writing; keep draining it and
	-- restore only after the last fill completes, so a canceled round can
	-- never race its own recovery.
	local draining = state == "preparation" and prep_index <= #prep_list
	state = "reset"
	current_vote_plot = nil
	local s = session
	if s then
		local sx, sy, sz = server.get_spawn()
		for _, m in ipairs(s:members()) do
			-- Session-authorized travel ignores the round's travel lock; a
			-- member whose spawn return fails keeps membership so finish()
			-- returns them to their entry spot instead.
			if s:travel(m, sx, sy, sz) then s:remove(m) end
		end
		s:finish()
		session = nil
	end
	players = {}
	for i = 1, #plots do
		local p = plots[i]
		p.owner_id, p.owner_gen, p.owner_name, p.withdrawn, p.votes = nil, nil, nil, false, {}
	end
	if draining then
		reset_wait_fills = true
	else
		start_restore()
	end
end

local function begin_building()
	local s = session
	for i = 1, #plots do
		local p = plots[i]
		if p.owner_id and not p.withdrawn then
			s:travel({ id = p.owner_id, gen = p.owner_gen }, p.view.x, p.view.y, p.view.z)
		end
	end
	theme = themes[math.random(#themes)]
	build_end = server.now() + build_seconds * 1000
	state = "building"
	-- Flying is permitted by simply not reacting to movement-policy evidence;
	-- the protocol cannot switch a client's fly control on.
	s:announce("&eTheme: &6" .. theme .. "&e! You have " .. build_seconds .. " seconds. Build only inside your own plot.")
end

local function fill_next()
	if prep_index > #prep_list then
		if state == "preparation" then
			if prep_failed then
				session:announce("&cPlot clearing failed; the round cannot start")
				start_restore()
			else
				begin_building()
			end
		elseif state == "reset" and reset_wait_fills then
			reset_wait_fills = false
			start_restore()
		end
		return
	end
	server.fill(prep_list[prep_index], "air", function(ok)
		if not ok then prep_failed = true end
		prep_index = prep_index + 1
		fill_next()
	end)
end

local function start_preparation()
	local s = session
	prep_list = {}
	prep_failed = false
	for i = 1, #plots do
		local p = plots[i]
		if p.owner_id and not p.withdrawn then prep_list[#prep_list + 1] = p.box end
	end
	if #prep_list < 2 then return end
	-- The recovery record must exist before the first destructive fill. If it
	-- cannot be written the round is torn down instead of retried every tick.
	if not server.mark_dirty(box, template_key) then
		s:announce("&cBuild Battle preparation failed; the round cannot start")
		for _, m in ipairs(s:members()) do s:remove(m) end
		players = {}
		for i = 1, #plots do
			local p = plots[i]
			p.owner_id, p.owner_gen, p.owner_name = nil, nil, nil
		end
		s:finish()
		session = nil
		return
	end
	s:lock_travel(true)
	prep_index = 1
	state = "preparation"
	s:announce("&eThe round is starting; plots are being cleared...")
	fill_next()
end

local function begin_results()
	local s = session
	current_vote_plot = nil
	local ranked = {}
	for i = 1, #plots do
		local p = plots[i]
		if p.owner_id and not p.withdrawn then
			local sum, count = 0, 0
			for _, score in pairs(p.votes) do
				sum = sum + score
				count = count + 1
			end
			-- Zero-vote builds are unranked; withdrawn builds are excluded.
			if count > 0 then ranked[#ranked + 1] = { plot = i, avg = sum / count, place = 1 } end
		end
	end
	for _, r in ipairs(ranked) do
		for _, o in ipairs(ranked) do
			if o.avg > r.avg then r.place = r.place + 1 end
		end
	end
	-- Sorted by place, then plot index: the first entry of place 1 is the
	-- first winning plot in judging order, used for the shared-winner gather.
	table.sort(ranked, function(a, b)
		if a.place ~= b.place then return a.place < b.place end
		return a.plot < b.plot
	end)
	local by_place = {}
	for _, r in ipairs(ranked) do
		local g = by_place[r.place]
		if not g then
			g = { names = {}, plot = r.plot, avg = r.avg }
			by_place[r.place] = g
		end
		g.names[#g.names + 1] = plots[r.plot].owner_name
	end
	if not by_place[1] then
		s:announce("&eNo scored builds this round; there is no winner")
		begin_reset()
		return
	end
	server.broadcast("&6" .. table.concat(by_place[1].names, " & ") .. " won build battle with theme: " .. theme)
	local labels = { "&6Winner", "&e2nd place", "&e3rd place" }
	for place = 1, 3 do
		local g = by_place[place]
		if g then
			s:announce(labels[place] .. " (" .. string.format("%.1f", g.avg) .. "): " .. table.concat(g.names, ", "))
		end
	end
	local win = plots[by_place[1].plot]
	for _, m in ipairs(s:members()) do
		s:travel(m, win.view.x, win.view.y, win.view.z)
	end
	phase_end = server.now() + gather_seconds * 1000
	state = "results"
	s:announce("&eGathering at the winning build for " .. gather_seconds .. " seconds")
end

local function judge_next()
	local s = session
	while judge_cursor <= #judge_queue do
		local p = plots[judge_queue[judge_cursor]]
		if p.owner_id and not p.withdrawn then break end
		judge_cursor = judge_cursor + 1
	end
	if judge_cursor > #judge_queue then
		begin_results()
		return
	end
	local index = judge_queue[judge_cursor]
	local p = plots[index]
	current_vote_plot = index
	for _, m in ipairs(s:members()) do
		s:travel(m, p.view.x, p.view.y, p.view.z)
	end
	vote_end = server.now() + judge_seconds * 1000
	s:announce("&eNow judging " .. p.owner_name .. "'s build — /vote <1-10> (" .. judge_seconds .. "s)")
end

local function begin_judging()
	state = "judging"
	judge_queue = {}
	for i = 1, #plots do
		local p = plots[i]
		if p.owner_id and not p.withdrawn then judge_queue[#judge_queue + 1] = i end
	end
	judge_cursor = 1
	current_vote_plot = nil
	judge_next()
end

server.register_command{
	name = "buildbattle",
	aliases = { "bb" },
	description = "Join or leave the build battle round.",
	caller = "player",
	handler = function(caller)
		if not box then
			server.send_message(caller, "Build Battle is not configured; an operator must set up the arena")
			return
		end
		local p = players[caller.id]
		if p and p.gen ~= caller.gen then
			players[caller.id] = nil
			p = nil
		end
		if p then
			local plot = plots[p.plot]
			if state == "waiting" then
				-- The round never started, so the plot goes back on the market.
				if plot and plot.owner_id == caller.id then
					plot.owner_id, plot.owner_name = nil, nil
				end
			else
				-- Departure withdraws the build and removes the departed
				-- player's votes; there is no automatic rejoin.
				if plot and plot.owner_id == caller.id then plot.withdrawn = true end
				for i = 1, #plots do plots[i].votes[caller.id] = nil end
				if current_vote_plot == p.plot then current_vote_plot = nil end
			end
			players[caller.id] = nil
			if session then
				session:remove(caller)
				session:announce("&e" .. p.name .. " left build battle")
			end
			server.send_message(caller, "You left the round")
			return
		end
		if state ~= "waiting" then
			server.send_message(caller, state == "unconfigured" and "Build Battle is not configured" or "A round is underway; please wait for it to finish")
			return
		end
		local s = session
		if not s then
			s = server.create_session({ capacity = #plots })
			if not s then
				server.send_message(caller, "Build Battle cannot open another round right now")
				return
			end
			session = s
		end
		if not s:admit(caller) then
			server.send_message(caller, "You are already in another game")
			return
		end
		local index = 0
		for i = 1, #plots do
			if plots[i].owner_id == nil then
				index = i
				break
			end
		end
		if index == 0 then
			-- Possible only when withdrawn plots shrank the free pool below
			-- the session capacity.
			s:remove(caller)
			server.send_message(caller, "The round is full")
			return
		end
		plots[index].owner_id = caller.id
		plots[index].owner_gen = caller.gen
		plots[index].owner_name = caller.name
		players[caller.id] = { gen = caller.gen, name = caller.name, plot = index }
		if not s:travel(caller, plots[index].view.x, plots[index].view.y, plots[index].view.z) then
			server.send_message(caller, "Walk to the front of your plot to build")
		end
		s:announce("&e" .. caller.name .. " joined build battle (" .. #s:members() .. "/" .. #plots .. ")")
	end,
}

server.register_command{
	name = "vote",
	description = "Score the build being judged.",
	arguments = {
		{ name = "score", type = "number", description = "Score from 1 to 10" },
	},
	caller = "player",
	handler = function(caller, args)
		if state ~= "judging" or not current_vote_plot then
			server.send_message(caller, "Voting is not open")
			return
		end
		-- Votes never extend the window: the deadline is checked at every
		-- attempt, not only when the tick advances the phase.
		if server.now() >= vote_end then
			server.send_message(caller, "Voting for this build is closed")
			return
		end
		local p = players[caller.id]
		if not p or p.gen ~= caller.gen then
			server.send_message(caller, "Only round participants may vote")
			return
		end
		local plot = plots[current_vote_plot]
		if plot.owner_id == caller.id then
			server.send_message(caller, "You cannot vote for your own build")
			return
		end
		local score = math.floor(args.score)
		if score < 1 or score > 10 then
			server.send_message(caller, "Score must be between 1 and 10")
			return
		end
		-- One replaceable vote per voter and plot; missing votes abstain.
		plot.votes[caller.id] = score
		server.send_message(caller, "You scored " .. score .. " for " .. plot.owner_name .. "'s build")
	end,
}

server.register_command{
	name = "bbop",
	description = "Configure and run the build battle arena.",
	arguments = {
		{ name = "action", type = "string", description = "pos1, pos2, plots, capture, unclaim, or end" },
		{ name = "n", type = "number", optional = true, description = "Plot count for plots (2-8)" },
	},
	caller = "player",
	permission = "op",
	handler = function(caller, args)
		local action = args.action
		if action == "pos1" then
			pos1 = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Build battle corner 1 set")
		elseif action == "pos2" then
			pos2 = { x = caller.x, y = caller.y, z = caller.z }
			server.send_message(caller, "Build battle corner 2 set")
		elseif action == "plots" then
			if not args.n then
				server.send_message(caller, "Usage: /bbop plots <2-8>")
				return
			end
			plot_count = math.max(2, math.min(MAX_PLOTS, math.floor(args.n)))
			server.store_set("plots", plot_count)
			server.send_message(caller, "Plot count set to " .. plot_count .. "; capture the arena to apply it")
		elseif action == "capture" then
			if state ~= "unconfigured" and state ~= "waiting" then
				server.send_message(caller, "Cannot reconfigure during a round")
				return
			end
			if not (pos1 and pos2) then
				server.send_message(caller, "Set pos1 and pos2 first")
				return
			end
			local b = {
				x0 = math.min(pos1.x, pos2.x), y0 = math.min(pos1.y, pos2.y), z0 = math.min(pos1.z, pos2.z),
				x1 = math.max(pos1.x, pos2.x), y1 = math.max(pos1.y, pos2.y), z1 = math.max(pos1.z, pos2.z),
			}
			-- Build the floor at the box bottom and keep the volume above it
			-- (one layer plus fifteen plot layers) and the walkways clear.
			local cols = math.min(plot_count, 4)
			local rows = math.ceil(plot_count / 4)
			local need_w = 2 * MARGIN_X + cols * PLOT + (cols - 1) * GAP
			local need_d = MARGIN_Z + 2 + rows * PLOT + (rows - 1) * GAP
			local need_h = PLOT + 2
			local w = b.x1 - b.x0 + 1
			local d = b.z1 - b.z0 + 1
			local h = b.y1 - b.y0 + 1
			if w < need_w or d < need_d or h < need_h then
				server.send_message(caller, "Arena is too small for " .. plot_count .. " plots; it needs at least "
					.. need_w .. "x" .. need_h .. "x" .. need_d .. " (x*y*z)")
				return
			end
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
			-- A fresh template supersedes any pending recovery record.
			server.clear_dirty(template_key)
			if session then
				session:finish()
				session = nil
				players = {}
			end
			box = b
			build_layout()
			server.store_set("x0", b.x0)
			server.store_set("y0", b.y0)
			server.store_set("z0", b.z0)
			server.store_set("x1", b.x1)
			server.store_set("y1", b.y1)
			server.store_set("z1", b.z1)
			server.store_set("plots", plot_count)
			server.store_set("ready", 1)
			state = "waiting"
			server.send_message(caller, "Build battle arena captured; players can join with /buildbattle")
		elseif action == "unclaim" then
			if state ~= "unconfigured" and state ~= "waiting" then
				server.send_message(caller, "Cannot reconfigure during a round")
				return
			end
			if region then region:release() region = nil end
			state = "unconfigured"
			server.send_message(caller, "Build battle arena released; edit the world, then capture again")
		elseif action == "end" then
			if state == "preparation" or state == "building" or state == "judging" or state == "results" then
				begin_reset()
				server.send_message(caller, "Build battle round ended")
			else
				server.send_message(caller, "No round is running")
			end
		else
			server.send_message(caller, "Usage: /bbop <pos1|pos2|plots|capture|unclaim|end>")
		end
	end,
}

server.set_interval(function()
	if state == "waiting" then
		if session and #session:members() >= 2 then start_preparation() end
	elseif state == "preparation" or state == "building" or state == "judging" then
		local s = session
		if not s or #s:members() < 2 then
			-- Fewer than two participants before results cancels the round.
			if s then s:announce("&cNot enough builders remain; the round was canceled") end
			begin_reset()
			return
		end
		if state == "building" then
			if server.now() >= build_end then begin_judging() end
		elseif state == "judging" then
			if not current_vote_plot or server.now() >= vote_end then
				judge_cursor = judge_cursor + 1
				judge_next()
			end
		end
	elseif state == "results" then
		if server.now() >= phase_end then begin_reset() end
	end
end, tick_ms)

server.on_player_leave(function(player)
	local p = players[player.id]
	if not p or p.gen ~= player.gen then return end
	local plot = plots[p.plot]
	if state == "waiting" then
		if plot and plot.owner_id == player.id then
			plot.owner_id, plot.owner_name = nil, nil
		end
	elseif state ~= "unconfigured" and state ~= "reset" then
		if plot and plot.owner_id == player.id then plot.withdrawn = true end
		for i = 1, #plots do plots[i].votes[player.id] = nil end
		if current_vote_plot == p.plot then current_vote_plot = nil end
		if session then session:announce("&e" .. p.name .. " left build battle") end
	end
	players[player.id] = nil
end)

server.on_block_attempt(function(player, attempt)
	if not (box and region) then return nil end
	if attempt.x < box.x0 or attempt.x > box.x1 or attempt.y < box.y0 or attempt.y > box.y1
		or attempt.z < box.z0 or attempt.z > box.z1 then return nil end
	local p = players[player.id]
	if not p or p.gen ~= player.gen then return "deny" end
	-- Editing closes exactly at the build deadline even while earlier edits
	-- are still queued: the deadline is checked here, on the ordered context.
	if state ~= "building" or server.now() >= build_end then return "deny" end
	local plot = plots[p.plot]
	if not plot
		or attempt.x < plot.box.x0 or attempt.x > plot.box.x1
		or attempt.y < plot.box.y0 or attempt.y > plot.box.y1
		or attempt.z < plot.box.z0 or attempt.z > plot.box.z1 then return "deny" end
	return nil
end)
