-- dig — the dig tool's queue.
--
-- A click with the dig tool queues the block (up to DIG_QUEUE_MAX; clicking
-- a queued one again takes it off), outlined until it's dug. They're dug in
-- the order clicked: if the block isn't next to us we walk to the nearest
-- spot beside it first (above, below or level with it: anywhere we can
-- stand with it in arm's reach), then swing at it for DIG_TIME, chips of
-- it flying, and only then ask the server (dig_action). A plain block in
-- the world goes at once, without waiting to hear back; if the server says
-- no, it comes back. Moving with the keys drops the queue.
--
-- Blocks on a ship are dug from where we stand (no walking about a moving
-- deck), within REACH.

Dig = {}
Dig.queue = {}
DIG_QUEUE_MAX = 10
DIG_TIME = 0.45 -- seconds of swinging at one block
DIG_NEAR = 2.2 -- chest to the block's middle: close enough to swing at it
DIG_FAR = 24 -- tiles: as far off as a block can be queued (we walk there)
DIG_WALK_MAX = 8 -- seconds to get beside a block before giving up on it
-- what goes at once, not waiting for the server: the plain blocks (not a
-- pot, furniture, scaffolding or water, whose digging does more)
DIG_AT_ONCE = { true, true, true, true, true, false, false, false, false, true, true, true, true, true }

-- Is (the world's, or ship `on`'s) `cell` one we could queue from here?
function Dig.can_queue(me, cell, on)
	if on ~= nil then
		return in_reach(me, cell, on)
	end
	local dx = cell[1] - me.x
	local dy = cell[2] - me.y
	local dz = cell[3] - me.z
	return dx * dx + dy * dy + dz * dz <= DIG_FAR * DIG_FAR
end

function Dig.find(cell, on)
	for i = 1, #Dig.queue do
		local j = Dig.queue[i]
		if j.on == on and j.cell[1] == cell[1] and j.cell[2] == cell[2] and j.cell[3] == cell[3] then
			return i
		end
	end
	return nil
end

-- A dig-tool click on `cell`: queue it, or take it off if it's queued.
function Dig.click(cell, on)
	local i = Dig.find(cell, on)
	if i ~= nil then
		if i == 1 and APP.me ~= nil then
			APP.me.dig = nil
		end
		Dig.drop(i)
		return
	end
	if #Dig.queue >= DIG_QUEUE_MAX then
		local n = tostring(DIG_QUEUE_MAX)
		add_chat(nil, "that's " .. n .. " to dig already: click one to take it off", C_DIM)
		return
	end
	local j = {}
	local cx = cell[1]
	local cy = cell[2]
	local cz = cell[3]
	local c = { cx, cy, cz }
	j.cell = c
	j.on = on
	j.state = "wait"
	local ent = make("cursor", 0, 0, -1000, 1)
	j.ent = ent
	table.insert(Dig.queue, j)
end

function Dig.drop(i)
	local j = Dig.queue[i]
	j.ent:kill()
	table.remove(Dig.queue, i)
end

function Dig.clear()
	while #Dig.queue > 0 do
		Dig.drop(#Dig.queue)
	end
	if APP ~= nil and APP.me ~= nil then
		APP.me.dig = nil
	end
end

-- The middle of a queued block, in the world now (a ship may have moved).
function Dig.middle(j)
	local c = j.cell
	return Ships.frame_pos(j.on, c[1], c[2], c[3] + 0.5)
end

function Dig.near(me, j)
	local x, y, z = Dig.middle(j)
	if x == nil then
		return false
	end
	local dx = x - me.x
	local dy = y - me.y
	local dz = z - (me.z + 0.9)
	return dx * dx + dy * dy + dz * dz <= DIG_NEAR * DIG_NEAR
end

-- Somewhere to stand beside world cell `c` with it in reach, nearest to
-- `me`: feet on solid ground (not water) with two clear cells over them, in
-- one of the eight columns around it or on top of it, level with it, a
-- block over or a block under. nil if there's nowhere.
function Dig.spot(me, c)
	local best = nil
	local best_d = 0
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local x = c[1] + dx
				local y = c[2] + dy
				local f = c[3] + dz
				local on_top = dx == 0 and dy == 0
				if on_top then
					f = c[3] + 1
				end
				if (not on_top or dz == 0) and Dig.standable(x, y, f) then
					local ox = x - me.x
					local oy = y - me.y
					local oz = f - me.z
					local d = ox * ox + oy * oy + oz * oz * 2
					if on_top then
						d = d + 4 -- digging out from under ourselves: a last resort
					end
					if best == nil or d < best_d then
						local s = { x, y, f }
						best = s
						best_d = d
					end
				end
			end
		end
	end
	return best
end

function Dig.standable(x, y, f)
	local under = Blocks.get(x, y, f - 1)
	if under == 0 or under == WATER or Blocks.passable(under, x, y, f - 1) then
		return false
	end
	return Blocks.clear(x, y, f) and Blocks.clear(x, y, f + 1)
end

-- Each frame: work down the queue.
function Dig.update(me, dt)
	for i = 1, #Dig.queue do
		local j = Dig.queue[i]
		local x, y, z, rz = Ships.frame_pos(j.on, j.cell[1], j.cell[2], j.cell[3])
		if x ~= nil then
			j.ent.x = x
			j.ent.y = y
			j.ent.z = z + OUTLINE_DZ
			j.ent.rz = rz
		end
	end
	local j = Dig.queue[1]
	if j == nil then
		me.dig = nil
		return
	end
	-- carried, or at the helm: hold on
	if Carry.carrier_of(APP.my_id) ~= nil or Ships.piloted_by(APP.my_id) ~= nil then
		return
	end
	-- already gone (someone else dug it, or the ship left)
	local frame = Ships.get(j.on)
	local here = 0
	if j.on == nil or frame ~= nil then
		here = Blocks.get_in(frame, j.cell[1], j.cell[2], j.cell[3])
	end
	if here == 0 then
		me.dig = nil
		Dig.drop(1)
		return
	end
	if j.state == "wait" then
		Dig.approach(me, j)
	elseif j.state == "walk" then
		j.t = j.t + dt
		if Dig.near(me, j) then
			me:stop()
			Dig.swing(me, j)
		elseif me.tx == nil or j.t > DIG_WALK_MAX then
			-- got as close as we can: near enough for the server will do
			if in_reach(me, j.cell, j.on) then
				Dig.swing(me, j)
			else
				add_chat(nil, "can't get to that block", C_DIM)
				Dig.drop(1)
			end
		end
	elseif j.state == "swing" then
		local d = me.dig
		if d == nil then
			Dig.swing(me, j)
			return
		end
		local before = d.t
		d.t = d.t + dt
		-- a few chips at each strike, a shower at the end
		local strike = DIG_TIME / DIG_SWINGS
		if flr(d.t / strike) > flr(before / strike) then
			Chips.burst(j, 4)
		end
		if d.t >= DIG_TIME then
			me.dig = nil
			Dig.finish(j)
			Dig.drop(1)
		end
	end
end

-- Next to it already, swing; else walk beside it (in the world) or, on a
-- ship, swing from here if we can reach.
function Dig.approach(me, j)
	if Dig.near(me, j) then
		Dig.swing(me, j)
		return
	end
	if j.on == nil then
		local s = Dig.spot(me, j.cell)
		if s ~= nil then
			if me.anim ~= 0 then
				set_my_anim(0)
			end
			me:walk_to(s[1], s[2], nil)
			j.state = "walk"
			j.t = 0
			return
		end
	end
	if in_reach(me, j.cell, j.on) then
		Dig.swing(me, j)
	else
		add_chat(nil, "can't get to that block", C_DIM)
		Dig.drop(1)
	end
end

function Dig.swing(me, j)
	if me.anim ~= 0 then
		set_my_anim(0)
	end
	local x, y, z = Dig.middle(j)
	if x == nil then
		x = me.x
		y = me.y
		z = me.z
	end
	local d = {}
	d.t = 0
	local at = { x, y, z }
	d.at = at
	me.dig = d
	j.state = "swing"
end

-- Swung at long enough: dig it. A plain world block goes now; if the
-- server won't have it, it comes back.
function Dig.finish(j)
	local c = j.cell
	local frame = Ships.get(j.on)
	local id = Blocks.get_in(frame, c[1], c[2], c[3])
	Chips.burst(j, 10)
	local at_once = j.on == nil and DIG_AT_ONCE[id] == true
	if at_once then
		Blocks.set(c[1], c[2], c[3], 0)
	end
	local payload = cell_payload(c, j.on)
	PHX:push(ACTIONS, "dig_action", payload, function(status, response)
		if status == "ok" then
			if response ~= nil and response.bag ~= nil then
				Bag.set(response.bag)
			end
			return
		end
		if at_once and Blocks.get(c[1], c[2], c[3]) == 0 then
			Blocks.set(c[1], c[2], c[3], id)
		end
		if response ~= nil and response.reason ~= nil then
			add_chat(nil, "can't dig: " .. say_reason(response.reason), C_BAD)
		end
	end)
end

-- Bits of a block flying off it as it's dug: little squares of its own
-- texture (or dust, for a model), thrown up and out, falling, shrinking.
Chips = {}
Chips.list = {}
CHIPS_MAX = 48
CHIP_LIFE = 0.6 -- seconds
CHIP_GRAVITY = 14

function Chips.burst(j, n)
	local x, y, z = Dig.middle(j)
	if x == nil then
		return
	end
	local frame = Ships.get(j.on)
	local id = Blocks.get_in(frame, j.cell[1], j.cell[2], j.cell[3])
	local tex = "dust"
	local name = BLOCK_NAMES[id]
	if name ~= nil and CHIP_TEXTURES[name] then
		tex = name
	end
	for i = 1, n do
		if #Chips.list >= CHIPS_MAX then
			return
		end
		local c = {}
		c.x = x + (rnd() - 0.5) * 0.6
		c.y = y + (rnd() - 0.5) * 0.6
		c.z = z + (rnd() - 0.3) * 0.5
		c.vx = (rnd() - 0.5) * 3
		c.vy = (rnd() - 0.5) * 3
		c.vz = 1.5 + rnd() * 2.5
		c.t = 0
		c.k = 0.08 + rnd() * 0.07
		-- hoisted (SILT-BUGS.md #7)
		local ent = make(tex, c.x, c.y, c.z, c.k)
		c.ent = ent
		table.insert(Chips.list, c)
	end
end

-- the block textures that exist as pictures (assets/*.png)
CHIP_TEXTURES = {
	grass = true,
	dirt = true,
	stone = true,
	wood = true,
	path = true,
	deck = true,
	hull = true,
	balloon = true,
	rail = true,
	helm = true,
}

function Chips.update(dt)
	local i = #Chips.list
	while i >= 1 do
		local c = Chips.list[i]
		c.t = c.t + dt
		if c.t >= CHIP_LIFE then
			c.ent:kill()
			table.remove(Chips.list, i)
		else
			c.vz = c.vz - CHIP_GRAVITY * dt
			c.x = c.x + c.vx * dt
			c.y = c.y + c.vy * dt
			c.z = c.z + c.vz * dt
			local p = c.t / CHIP_LIFE
			c.ent.x = c.x
			c.ent.y = c.y
			c.ent.z = c.z
			c.ent.scale = c.k * (1 - p * p)
		end
		i = i - 1
	end
end
