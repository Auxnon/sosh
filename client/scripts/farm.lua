-- farm — the server's living world (Sosh.Sim): carrots and cows.
--
-- Carrots grow on the server's clock: a `crop` event carries each new stage
-- (0-3, 3 is ripe; nil means it's gone). A crop sits in the air cell above
-- its soil and isn't solid. On the web only transforms sync after the frame
-- an entity was made in, so a stage change swaps the entity.
--
-- Cows are simulated on the server and arrive as positions about ten times a
-- second. Each one eases toward its latest server position, and the local
-- player shoves it straight away (the server agrees a moment later).

Farm = {}
Herd = {}

CROP_STAGES = 4
CROP_RIPE = 3
COW_EASE = 0.25 -- fraction of the way to the server position per frame
COW_PUSH = 0.9 -- cow radius + player radius, as on the server
MOO_FRAMES = 90

function Farm.init()
	if Farm.crops ~= nil then
		for k, c in pairs(Farm.crops) do
			c.ent:kill()
		end
	end
	Farm.crops = {}
	Farm.carrots = 0
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
	for id, c in pairs(Herd.cows) do
		c.x = U.lerp(c.x, c.sx, COW_EASE)
		c.y = U.lerp(c.y, c.sy, COW_EASE)
		c.z = U.lerp(c.z, c.sz, COW_EASE)
		c.h = c.h + U.angle_diff(c.h, c.sh) * COW_EASE
		if me ~= nil then
			Herd.shove(c, me)
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

-- "moo!" over any cow that was just shoved.
function Herd.overlay()
	for id, c in pairs(Herd.cows) do
		if c.moo > 0 then
			local p = UI.project(c.x, c.y, c.z + 1.4)
			if p ~= nil then
				local text = "moo!"
				local w = UI.text_w(text) + PAD * 2
				local x = p[1] - flr(w / 2)
				local y = p[2] - LH - PAD
				gui:rrect(x, y, w, LH + PAD, 4, C_BUBBLE)
				gui:rect(p[1] - 1, y + LH + PAD, 3, 2, C_BUBBLE)
				UI.text(text, x + PAD, y + 2, C_BUBBLE_TEXT)
			end
		end
	end
end
