-- ships — airships: blocks that fly together, between islands and on into
-- the next universe.
--
-- The universe (Sosh.Sim) flies them. Each is a grid of blocks in its own
-- frame (+x ahead, +y to port, z up; the deck's top at local z 0) and a pose
-- placing that frame in the world, turning only about z. Here each is one
-- entity owning a tile grid of its blocks (`ent:tile`), so the whole ship
-- moves and turns as one. On the web an entity's tiles only reach the
-- renderer in the frame it's made, so a ship whose blocks change is made
-- again rather than edited.
--
-- `ships` rows ({id, x, y, z, heading, vx, vy, vz, spin}) arrive about ten
-- times a second. A ship carries on at the velocity of the last one and
-- eases off any drift from where the server's track puts it, so it glides
-- rather than steps. Anyone standing on deck is carried by the same pose
-- (avatar.lua), so ship and riders never part.
--
-- Furniture, blueprints and the pot can stand in a ship's cells too
-- (FURNITURE, SCAFFOLD): solid, drawn by their own entities, which
-- furniture.lua places by `Ships.frame_pos` every frame.
--
-- Helpers are avatars driven by their rows: each row's velocity is worked
-- out from the last, so they walk rather than glide. They take the other
-- end of heavy furniture when called (Furn.helper_holds).

Ships = {}
Helpers = {}

SHIP_EASE = 6 -- rate drift from the server's track is taken up, per second
SHIP_LEAD = 0.4 -- seconds a row is carried on for, before it's stale
HELM_REACH = 2.5 -- feet to the helm's middle, to take it (as on the server)
HELM = 14
-- a helper whose rows stop coming has stopped
HELPER_STILL = 0.3

function Ships.init()
	if Ships.list ~= nil then
		for id, s in pairs(Ships.list) do
			Ships.kill(s)
		end
	end
	Ships.list = {}
end

function Ships.kill(s)
	if s.ent ~= nil then
		s.ent:kill()
		s.ent = nil
	end
	if s.models ~= nil then
		for i = 1, #s.models do
			s.models[i].ent:kill()
		end
	end
	s.models = {}
end

function Ships.get(id)
	if id == nil then
		return nil
	end
	return Ships.list[id]
end

-- A snapshot entry or `ship` event: {id, x, y, z, heading, v, pilot,
-- blocks: {{x, y, z, block}}}.
function Ships.set(p)
	local s = Ships.list[p.id]
	if s == nil then
		s = {}
		s.id = p.id
		s.x = p.x
		s.y = p.y
		s.z = p.z
		s.h = p.heading
		s.px = s.x
		s.py = s.y
		s.pz = s.z
		s.ph = s.h
		Ships.list[p.id] = s
	end
	s.pilot = p.pilot
	s.blocks = {}
	s.cells = {}
	local list = p.blocks or {}
	for i = 1, #list do
		local b = list[i]
		local k = Blocks.key(b[1], b[2], b[3])
		s.blocks[k] = b[4]
		local c = { b[1], b[2], b[3] }
		s.cells[k] = c
	end
	s.dirty = true
	local v = p.v or { 0, 0, 0, 0 }
	local row = { p.id, p.x, p.y, p.z, p.heading, v[1], v[2], v[3], v[4] }
	Ships.put(row)
end

function Ships.sync(list)
	Ships.init()
	for i = 1, #list do
		Ships.set(list[i])
	end
end

-- A row {id, x, y, z, heading, vx, vy, vz, spin}: the server's track.
function Ships.put(row)
	local s = Ships.list[row[1]]
	if s == nil then
		return
	end
	s.sx = row[2]
	s.sy = row[3]
	s.sz = row[4]
	s.sh = row[5]
	s.vx = row[6] or 0
	s.vy = row[7] or 0
	s.vz = row[8] or 0
	s.spin = row[9] or 0
	s.st = U.clock or 0
end

-- `ship_block` {ship, position, block}.
function Ships.block(p)
	local s = Ships.list[p.ship]
	if s == nil then
		return
	end
	local pos = p.position
	local k = Blocks.key(pos[1], pos[2], pos[3])
	if p.block == 0 then
		s.blocks[k] = nil
		s.cells[k] = nil
	else
		s.blocks[k] = p.block
		local c = { pos[1], pos[2], pos[3] }
		s.cells[k] = c
	end
	s.dirty = true
end

function Ships.remove(id)
	local s = Ships.list[id]
	if s ~= nil then
		Ships.kill(s)
		Ships.list[id] = nil
	end
end

-- Move every ship along its track, remembering where it was last frame
-- (riders are carried by the difference), and remake any whose blocks
-- changed.
function Ships.update(dt)
	local now = U.clock or 0
	local k = U.rate(SHIP_EASE, dt)
	for id, s in pairs(Ships.list) do
		s.px = s.x
		s.py = s.y
		s.pz = s.z
		s.ph = s.h
		local age = now - s.st
		local fresh = age < SHIP_LEAD
		if age > SHIP_LEAD then
			age = SHIP_LEAD
		end
		-- where the track says it is now
		local tx = s.sx + s.vx * age
		local ty = s.sy + s.vy * age
		local tz = s.sz + s.vz * age
		local th = s.sh + s.spin * age
		if fresh then
			s.x = s.x + s.vx * dt
			s.y = s.y + s.vy * dt
			s.z = s.z + s.vz * dt
			s.h = s.h + s.spin * dt
		end
		s.x = s.x + (tx - s.x) * k
		s.y = s.y + (ty - s.y) * k
		s.z = s.z + (tz - s.z) * k
		s.h = s.h + U.angle_diff(s.h, th) * k
		if s.dirty then
			Ships.build(s)
		end
		local e = s.ent
		e.x = s.x
		e.y = s.y
		e.z = s.z
		e.rz = s.h
		for i = 1, #s.models do
			local m = s.models[i]
			local c = m.c
			local mx, my, mz = Ships.to_world(s, c[1], c[2], c[3])
			local me = m.ent
			me.x = mx
			me.y = my
			me.z = mz
			me.rz = s.h
		end
	end
end

-- (Re)make the ship's entity with a tile for each of its blocks drawn as
-- one. The entity itself is scaled to nothing: only its tiles show. Blocks
-- drawn as a model (the pot) get an entity each, moved with the ship.
function Ships.build(s)
	Ships.kill(s)
	local e = make("hull", s.x, s.y, s.z, 0)
	for k, c in pairs(s.cells) do
		local b = s.blocks[k]
		if c ~= nil and Blocks.is_tile(b) then
			local name = BLOCK_NAMES[b] or "stone"
			e:tile(name, c[1], c[2], c[3], 0)
		elseif c ~= nil and Blocks.is_model(b) then
			local m = {}
			m.c = c
			m.ent = make(BLOCK_NAMES[b], 0, 0, -1000, 1)
			table.insert(s.models, m)
		end
	end
	s.ent = e
	s.dirty = false
end

-- -- frames

-- Ship `s`'s local point in the world.
function Ships.to_world(s, lx, ly, lz)
	local c = cos(s.h)
	local n = sin(s.h)
	return s.x + lx * c - ly * n, s.y + lx * n + ly * c, s.z + lz
end

-- A world point in ship `s`'s frame.
function Ships.to_local(s, x, y, z)
	local c = cos(s.h)
	local n = sin(s.h)
	local dx = x - s.x
	local dy = y - s.y
	return dx * c + dy * n, -dx * n + dy * c, z - s.z
end

-- Where a world point that rode on `s` last frame is now, and how much the
-- ship turned.
function Ships.carry(s, x, y, z)
	local c = cos(s.ph)
	local n = sin(s.ph)
	local dx = x - s.px
	local dy = y - s.py
	local lx = dx * c + dy * n
	local ly = -dx * n + dy * c
	local wx, wy, wz = Ships.to_world(s, lx, ly, z - s.pz)
	return wx, wy, wz, U.angle_diff(s.ph, s.h)
end

-- Frame `on`'s (0 or nil the world, else a ship id) point in the world, and
-- how far that frame is turned. Nil for a ship we don't know.
function Ships.frame_pos(on, x, y, z)
	if on == nil or on == 0 then
		return x, y, z, 0
	end
	local s = Ships.list[on]
	if s == nil then
		return nil
	end
	local wx, wy, wz = Ships.to_world(s, x, y, z)
	return wx, wy, wz, s.h
end

function Ships.block_at(s, x, y, z)
	return s.blocks[Blocks.key(x, y, z)] or 0
end

-- Where feet rest on ship `s` at world (x, y) for someone at height z: the
-- top of its highest block at most one above their feet (as Blocks.ground),
-- as a world height; nil if none.
function Ships.ground(s, x, y, z)
	local lx, ly, lz = Ships.to_local(s, x, y, z)
	local cx = Blocks.cell(lx)
	local cy = Blocks.cell(ly)
	local top = flr(lz + 0.01)
	for bz = top, top - 6, -1 do
		if Ships.block_at(s, cx, cy, bz) ~= 0 then
			return s.z + bz + 1
		end
	end
	return nil
end

-- Is world point (x, y, z) inside a block of any ship?
function Ships.solid_at(x, y, z)
	for id, s in pairs(Ships.list) do
		local lx, ly, lz = Ships.to_local(s, x, y, z)
		-- hoisted: calls in an argument list miscompile (SILT-BUGS.md #1)
		local cx = Blocks.cell(lx)
		local cy = Blocks.cell(ly)
		local cz = flr(lz)
		if Ships.block_at(s, cx, cy, cz) ~= 0 then
			return true
		end
	end
	return false
end

-- The first ship block along a ray within max_dist, as Blocks.raycast
-- gives it (cells in the ship's frame) plus `on`, the ship; or nil.
function Ships.raycast(ox, oy, oz, dx, dy, dz, max_dist)
	local best = nil
	for id, s in pairs(Ships.list) do
		local lx, ly, lz = Ships.to_local(s, ox, oy, oz)
		local c = cos(s.h)
		local n = sin(s.h)
		local ldx = dx * c + dy * n
		local ldy = -dx * n + dy * c
		local res = Blocks.raycast_in(s, lx, ly, lz, ldx, ldy, dz, max_dist)
		if res ~= nil and (best == nil or res.dist < best.dist) then
			res.on = s.id
			best = res
		end
	end
	return best
end

-- The ship `user_id` is at the helm of, or nil.
function Ships.piloted_by(user_id)
	if user_id == nil then
		return nil
	end
	for id, s in pairs(Ships.list) do
		if s.pilot == user_id then
			return s
		end
	end
	return nil
end

-- A ship whose helm is within reach of world point (x, y, z), or nil.
function Ships.helm_near(x, y, z)
	for id, s in pairs(Ships.list) do
		for k, c in pairs(s.cells) do
			if c ~= nil and s.blocks[k] == HELM then
				local hx, hy, hz = Ships.to_world(s, c[1], c[2], c[3] + 0.5)
				local dx = hx - x
				local dy = hy - y
				local dz = hz - z
				local r = HELM_REACH + 0.4
				if dx * dx + dy * dy + dz * dz <= r * r then
					return s
				end
			end
		end
	end
	return nil
end

-- -- helpers

function Helpers.init()
	if Helpers.list ~= nil then
		for id, h in pairs(Helpers.list) do
			h.av:remove()
		end
	end
	Helpers.list = {}
end

-- A snapshot entry: {id, name, x, y, z, heading}.
function Helpers.add(p)
	local h = {}
	h.id = p.id
	h.t = U.clock or 0
	h.x = p.x
	h.y = p.y
	h.z = p.z
	-- hoisted: a call in the first argument miscompiles (SILT-BUGS.md #1)
	local key = Helpers.key(p.id)
	local av = Avatar.new(key, p.name, p.x, p.y, p.z, p.id + 2, 0)
	av.heading = p.heading
	av.helper_id = p.id
	h.av = av
	Helpers.list[p.id] = h
end

function Helpers.sync(list)
	Helpers.init()
	for i = 1, #list do
		Helpers.add(list[i])
	end
end

-- Helpers' avatars go by this, so they never clash with a player's id.
function Helpers.key(id)
	return "helper:" .. tostring(id)
end

-- A row {id, x, y, z, heading}: walk on at the speed it's been going.
function Helpers.put(row)
	local h = Helpers.list[row[1]]
	if h == nil then
		return
	end
	local now = U.clock or 0
	local dt = now - h.t
	local v = nil
	if dt > 0.02 and dt < 0.5 then
		local vx = (row[2] - h.x) / dt
		local vy = (row[3] - h.y) / dt
		v = { vx, vy }
	end
	h.x = row[2]
	h.y = row[3]
	h.z = row[4]
	h.t = now
	local at = { row[2], row[3], row[4] }
	h.av:follow(at, v, nil)
end

function Helpers.update(dt)
	local now = U.clock or 0
	for id, h in pairs(Helpers.list) do
		if now - h.t > HELPER_STILL and h.av:driven() then
			h.av:stop()
		end
		h.av:update(dt)
	end
end

function Helpers.avatar(id)
	local h = Helpers.list[id]
	if h == nil then
		return nil
	end
	return h.av
end

-- The helper id behind an avatar id ("helper:3"), or nil.
function Helpers.id_of(key)
	for id, h in pairs(Helpers.list) do
		if h.av.id == key then
			return id
		end
	end
	return nil
end

-- The nearest helper the ray passes through within max_dist, or nil.
function Helpers.under_ray(ox, oy, oz, dx, dy, dz, max_dist)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 0.0001 then
		return nil
	end
	dx = dx / l
	dy = dy / l
	dz = dz / l
	local best = nil
	local best_t = max_dist
	for id, h in pairs(Helpers.list) do
		local av = h.av
		local cx = av.x - ox
		local cy = av.y - oy
		local cz = av.z + 0.8 - oz
		local t = cx * dx + cy * dy + cz * dz
		local miss = cx * cx + cy * cy + cz * cz - t * t
		if t > 0 and t < best_t and miss < 0.36 then
			best = h
			best_t = t
		end
	end
	return best, best_t
end
