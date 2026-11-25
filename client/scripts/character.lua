-- character — how someone looks, put together from parts (the server's
-- Sosh.Character; parts made by tools/gen_character.py, placed with
-- character_rig.lua).
--
--   body            the one entity posed each frame (`pose`): where it
--                   stands, its heading (applied last, `zyx`, so it can lie
--                   down at any angle), its clip and bone overrides. Height
--                   stretches the leg, spine and arm bones (their
--                   translations grow), and it lifts so the feet stay down
--   clothes         skinned models wearing the body's pose (`lot(body, e,
--                   true)`): its clip, overrides and stretch, weight for weight
--   head            rides the body's head bone (`lot(body, head, "head")`),
--                   nodding and tilting with it
--   hair, hat       ride the head, at its crown
--   face            sprites riding the head, each placed once across its
--                   front (x, y in -1..1), scaled, rolled in the face's plane
--   hand            what's held, riding the right hand bone
--
-- Everything but the body is placed once, in the engine's terms, when it's
-- made (Petrichor64's `lot`, guide/lot.md); the engine keeps it there.
--
-- Everything is white and tinted. On the web build only an entity's
-- transform and bones sync after the frame it was made in, so a changed
-- look is rebuilt (`restyle`), never retextured.

Character = {}
Character.__index = Character

-- a face sprite one unit across is this big on the head
FACE_SPRITE = 0.13
-- each sprite a hair in front of the last, so they layer in order
FACE_LAYER = 0.003
CLOTHES = { "bottom", "shoes", "top" }
-- seconds a change of clip blends over
CLIP_FADE = 0.2

HEX_UPPER = "0123456789ABCDEF"
HEX_LOWER = "0123456789abcdef"

function hex_digit(ch)
	for i = 1, 16 do
		if HEX_UPPER:sub(i, i) == ch or HEX_LOWER:sub(i, i) == ch then
			return i - 1
		end
	end
	return 15
end

-- "RRGGBB" as a tint, 0..1 a channel
function tint_of(hex)
	local t = {}
	t[1] = 1
	t[2] = 1
	t[3] = 1
	t[4] = 1
	if hex == nil or #hex ~= 6 then
		return t
	end
	for i = 0, 2 do
		local hc = hex:sub(i * 2 + 1, i * 2 + 1)
		local lc = hex:sub(i * 2 + 2, i * 2 + 2)
		local hi = hex_digit(hc)
		local lo = hex_digit(lc)
		t[i + 1] = (hi * 16 + lo) / 255
	end
	return t
end

-- A part, made white and tinted `hex`.
function tinted(asset, x, y, z, hex)
	local e = make(asset, x, y, z, 1)
	local t = tint_of(hex)
	e.tint = t
	return e
end

-- What a held item looks like: furniture is its own model; anything else
-- is its block's texture on a small cube.
function held(item, x, y, z)
	if Furn ~= nil and Furn.kinds ~= nil and Furn.kinds[item] ~= nil then
		return make(item, x, y, z, 0.22)
	end
	local e = make("cube", x, y, z, 0.2)
	e.tex = item
	return e
end

function Character.new(spec, x, y, z)
	local c = setmetatable({}, Character)
	c.x = x
	c.y = y
	c.z = z
	c.clip = nil
	local s = spec
	if s == nil then
		s = Character.default()
	end
	c:build(s)
	return c
end

function face_part(p, shape, x, y, color)
	local t = {}
	t.part = p
	t.shape = shape
	t.x = x
	t.y = y
	t.scale = 1
	t.rot = 0
	t.color = color
	return t
end

-- What someone looks like before the server says (the server's default).
function Character.default()
	local face = {}
	face[1] = face_part("eye", 0, -0.32, 0.12, "302820")
	face[2] = face_part("eye", 0, 0.32, 0.12, "302820")
	face[3] = face_part("brow", 0, -0.32, 0.42, "4A3020")
	face[4] = face_part("brow", 0, 0.32, 0.42, "4A3020")
	face[5] = face_part("mouth", 0, 0, -0.45, "A04040")
	local s = {}
	s.height = 1
	s.skin = "E8B796"
	s.head = "round"
	s.hair = "short"
	s.hair_color = "4A3020"
	s.face = face
	s.top = "tee"
	s.top_color = "4F7FC0"
	s.bottom = "pants"
	s.bottom_color = "40404A"
	s.shoes = "shoes"
	s.shoes_color = "6A4A30"
	s.hat = "none"
	s.hat_color = "C04040"
	return s
end

-- `e` rides `parent` (its bone `how`, its pose if `how` is true, or the
-- entity itself if nil) at (lx, ly, lz) in the parent's terms.
function ride(parent, e, how, lx, ly, lz)
	lot(parent, e, how)
	e.x = lx
	e.y = ly
	e.z = lz
end

function Character:build(spec)
	self.spec = spec
	local x = self.x
	local y = self.y
	local z = self.z
	self.k = U.clamp(spec.height or 1, 0.85, 1.2)
	self.lift = (self.k - 1) * RIG.leg_drop

	self.body = tinted("body", x, y, z, spec.skin)
	-- heading last: a turned body tips about its own axes (lying, carried)
	self.body.zyx = true
	self.parts = {}
	for i = 1, #CLOTHES do
		local slot = CLOTHES[i]
		local name = spec[slot]
		if name ~= nil and name ~= "none" then
			local color = spec[slot .. "_color"]
			local e = tinted("cl_" .. name, x, y, z, color)
			ride(self.body, e, true, 0, 0, 0)
			table.insert(self.parts, e)
		end
	end

	self.head_name = spec.head or "round"
	if RIG.faces[self.head_name] == nil then
		self.head_name = "round"
	end
	local f = RIG.faces[self.head_name]
	local head = tinted("head_" .. self.head_name, x, y, z, spec.skin)
	ride(self.body, head, "head", 0, 0, 0)
	table.insert(self.parts, head)
	-- hair and hats are modelled for the round head's crown: moved to this one's
	if spec.hair ~= nil and spec.hair ~= "none" then
		local hair = tinted("hair_" .. spec.hair, x, y, z, spec.hair_color)
		ride(head, hair, nil, 0, 0, f[5])
		table.insert(self.parts, hair)
	end
	if spec.hat ~= nil and spec.hat ~= "none" then
		local hat = tinted("hat_" .. spec.hat, x, y, z, spec.hat_color)
		ride(head, hat, nil, 0, 0, f[5])
		table.insert(self.parts, hat)
	end

	-- the face: across the front of the head, each a hair before the last
	local face = spec.face or {}
	local layer = 0
	for i = 1, #face do
		local p = face[i]
		local n = RIG.parts[p.part]
		if n ~= nil then
			local raw = flr(p.shape or 0)
			local shape = U.clamp(raw, 0, n - 1)
			local e = tinted("fp_" .. p.part .. shape, x, y, z, p.color)
			e.scale = FACE_SPRITE * (p.scale or 1)
			layer = layer + 1
			local lx = f[1] + FACE_LAYER * layer
			local ly = (p.x or 0) * f[3]
			local lz = f[2] + (p.y or 0) * f[4]
			ride(head, e, nil, lx, ly, lz)
			-- a quad facing +x: rx rolls it in the face's plane
			e.rx = p.rot or 0
			table.insert(self.parts, e)
		end
	end

	if spec.hand ~= nil then
		local e = held(spec.hand, x, y, z)
		ride(self.body, e, "hand.r", 0, 0, -0.05)
		table.insert(self.parts, e)
	end
	self.clip = nil
end

-- Killing the body doesn't take what rides it, so each goes.
function Character:kill()
	for i = 1, #self.parts do
		self.parts[i]:kill()
	end
	if self.body ~= nil then
		self.body:kill()
	end
	self.parts = {}
	self.body = nil
end

-- A new look: everything made again where it stands.
function Character:restyle(spec)
	self:kill()
	self:build(spec)
end

-- Pose it: feet at (x, y, z), facing `facing`, playing `clip`, with bone
-- rotations `turns` ({bone = {rx, ry, rz}}) on top of the clip. `flat`
-- ({rx, ry}, from Avatar.lie) tips it over (on its back), about its own
-- axes since the heading comes last. Only the body is touched: the rest rides it.
function Character:pose(x, y, z, facing, clip, turns, flat)
	self.x = x
	self.y = y
	self.z = z
	local e = self.body
	if e == nil then
		return
	end
	local k = self.k
	e.x = x
	e.y = y
	e.z = z + self.lift + DRAW_DZ
	e.rz = facing
	e.rx = 0
	e.ry = 0
	if flat ~= nil then
		e.rx = flat.rx
		e.ry = flat.ry
	end
	if clip ~= self.clip then
		-- blended, so standing up or sitting down doesn't snap
		e:anim(clip, true, 1, CLIP_FADE)
		self.clip = clip
	end
	-- stretched bones, turned or not
	for name, t in pairs(RIG.stretch) do
		local rot = turns[name] or ZERO3
		local pos = {}
		pos[1] = t[1] * (k - 1)
		pos[2] = t[2] * (k - 1)
		pos[3] = t[3] * (k - 1)
		e:bone(name, rot, pos)
	end
	for name, rot in pairs(turns) do
		if RIG.stretch[name] == nil then
			e:bone(name, rot)
		end
	end
end

ZERO3 = { 0, 0, 0 }
