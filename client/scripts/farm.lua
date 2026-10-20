-- farm — the server's living world (Sosh.Sim): carrots and cows.
--
-- Carrots grow on the server's clock: a `crop` event carries each new stage
-- (0-3, 3 is ripe; nil means it's gone). A crop sits in the air cell above
-- its soil and isn't solid. On the web only transforms sync after the frame
-- an entity was made in, so a stage change swaps the entity.
--
-- Cows are simulated on the server and arrive as positions about ten times a
-- second. Each one eases toward its latest server position, and the local
-- player shoves it straight away (the server agrees a moment later). A
-- carried cow rides over its holder (carry.lua) instead.

Farm = {}
Herd = {}

CROP_STAGES = 4
CROP_RIPE = 3
COW_EASE = 15 -- rate a cow closes on its server position, per second
COW_PUSH = 0.9 -- cow radius + player radius, as on the server
MOO_FRAMES = 90

function Farm.init()
	if Farm.crops ~= nil then
		for k, c in pairs(Farm.crops) do
			c.ent:kill()
		end
	end
	Farm.crops = {}
end

-- The crop in cell (x, y, z), or nil.
function Farm.get(x, y, z)
	return Farm.crops[Blocks.key(x, y, z)]
end

-- stage nil removes it
function Farm.set(pos, stage)
	local x = pos[1]
	local y = pos[2]
	local z = pos[3]
	local k = Blocks.key(x, y, z)
	local c = Farm.crops[k]
	if c ~= nil then
		if c.stage == stage then
			return
		end
		c.ent:kill()
		Farm.crops[k] = nil
	end
	if stage == nil then
		return
	end
	local s = U.clamp(stage, 0, CROP_STAGES - 1)
	-- hoisted: as `crop.ent = make("carrot" .. tostring(s), ...)` silt calls
	-- the wrong value (petrichor64 SILT-BUGS.md #7)
	local model = "carrot" .. tostring(s)
	local ent = make(model, x, y, z, 1)
	local crop = {}
	crop.stage = s
	crop.ent = ent
	Farm.crops[k] = crop
end

-- Replace everything with the server's list.
function Farm.sync(list)
	Farm.init()
	for i = 1, #list do
		local c = list[i]
		Farm.set(c.position, c.stage)
	end
end

function Herd.init()
	if Herd.cows ~= nil then
		for id, c in pairs(Herd.cows) do
			c.ent:kill()
		end
	end
	Herd.cows = {}
end

-- One row from the server: {id, x, y, z, heading}.
function Herd.put(row)
	local id = row[1]
	local c = Herd.cows[id]
	if c == nil then
		c = {}
		c.id = id
		c.x = row[2]
		c.y = row[3]
		c.z = row[4]
		c.h = row[5]
		c.moo = 0
		c.ent = make("cow", c.x, c.y, c.z, 1)
		Herd.cows[id] = c
	end
	c.sx = row[2]
	c.sy = row[3]
	c.sz = row[4]
	c.sh = row[5]
end

function Herd.sync(rows)
	Herd.init()
	for i = 1, #rows do
		Herd.put(rows[i])
	end
end

function Herd.moo(ids)
	for i = 1, #ids do
		local c = Herd.cows[ids[i]]
		if c ~= nil then
			c.moo = MOO_FRAMES
		end
	end
end

function Herd.update(me)
	local k = U.rate(COW_EASE, U.dt)
	for id, c in pairs(Herd.cows) do
		local held = Carry.cow_spot(id)
		if held ~= nil then
			-- set down later, it eases from up here to where it lands
			c.x = held[1]
			c.y = held[2]
			c.z = held[3]
			c.h = held[4]
			c.sx = c.x
			c.sy = c.y
			c.sz = c.z
		else
			c.x = U.lerp(c.x, c.sx, k)
			c.y = U.lerp(c.y, c.sy, k)
			c.z = U.lerp(c.z, c.sz, k)
			c.h = c.h + U.angle_diff(c.h, c.sh) * k
			if me ~= nil then
				Herd.shove(c, me)
			end
		end
		if c.moo > 0 then
			c.moo = c.moo - 1
		end
		local e = c.ent
		e.x = c.x
		e.y = c.y
		e.z = c.z
		e.rz = c.h
	end
end

-- Predict the server's push so walking into a cow feels immediate; only
-- where the cow can stand, as the server would refuse the rest.
function Herd.shove(c, me)
	if math.abs(me.z - c.z) > 1.5 then
		return
	end
	local ox = c.x - me.x
	local oy = c.y - me.y
	local d = sqrt(ox * ox + oy * oy)
	if d >= COW_PUSH or d < 0.0001 then
		return
	end
	local push = COW_PUSH - d
	local nx = c.x + ox / d * push
	local ny = c.y + oy / d * push
	if Blocks.walkable(nx, ny, c.z) then
		c.x = nx
		c.y = ny
		-- and don't ease back into the player before the server catches up
		c.sx = U.lerp(c.sx, nx, 0.5)
		c.sy = U.lerp(c.sy, ny, 0.5)
	end
end

-- The nearest cow the ray from (ox, oy, oz) along (dx, dy, dz) passes
-- through, within max_dist: cow, distance along the ray. nil if none.
function Herd.under_ray(ox, oy, oz, dx, dy, dz, max_dist)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 0.0001 then
		return nil
	end
	dx = dx / l
	dy = dy / l
	dz = dz / l
	local best = nil
	local best_t = max_dist
	for id, c in pairs(Herd.cows) do
		-- a sphere around the body
		local cx = c.x - ox
		local cy = c.y - oy
		local cz = c.z + 0.6 - oz
		local t = cx * dx + cy * dy + cz * dz
		local miss = cx * cx + cy * cy + cz * cz - t * t
		if t > 0 and t < best_t and miss < 0.36 then
			best = c
			best_t = t
		end
	end
	return best, best_t
end

-- Where a cow's "moo!" goes on screen (UI.project), or nil if it isn't
-- mooing or is behind the camera.
function Herd.moo_point(c)
	if c.moo <= 0 then
		return nil
	end
	return UI.project(c.x, c.y, c.z + 1.4)
end

-- "moo!" over a cow that was just shoved, at its moo_point `p`.
function Herd.moo_bubble(p)
	local text = "moo!"
	local w = UI.text_w(text) + PAD * 2
	local x = p[1] - flr(w / 2)
	local y = p[2] - LH - PAD
	gui:rrect(x, y, w, LH + PAD, 4, C_BUBBLE)
	gui:rect(p[1] - 1, y + LH + PAD, 3, 2, C_BUBBLE)
	UI.text(text, x + PAD, y + 2, C_BUBBLE_TEXT)
end
