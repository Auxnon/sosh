-- character — how someone looks, put together from parts (the server's
-- Sosh.Character; parts made by tools/gen_character.py, placed with
-- character_rig.lua).
--
--   body + clothes  skinned on the same rig: they play the same clip and get
--                   the same bone overrides every frame, so the clothes move
--                   with the body, weight for weight. Height stretches the
--                   leg, spine and arm bones (their translations grow), and
--                   the whole lifts so the feet stay on the ground
--   head, hair, hat rigid, kept on the head bone
--   face            sprites, each its own entity on the front of the head:
--                   placed across it (x, y in -1..1), scaled, turned in the
--                   face's plane, tinted
--   hand            what's held, on the right hand bone
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

function Character:build(spec)
	self.spec = spec
	local x = self.x
	local y = self.y
	local z = self.z
	self.k = U.clamp(spec.height or 1, 0.85, 1.2)
	self.lift = (self.k - 1) * RIG.leg_drop

	self.skinned = {}
	self.body = tinted("body", x, y, z, spec.skin)
	table.insert(self.skinned, self.body)
	for i = 1, #CLOTHES do
		local slot = CLOTHES[i]
		local name = spec[slot]
		if name ~= nil and name ~= "none" then
			local color = spec[slot .. "_color"]
			local e = tinted("cl_" .. name, x, y, z, color)
			table.insert(self.skinned, e)
		end
	end

	self.rigid = {}
	self.head_name = spec.head or "round"
	if RIG.faces[self.head_name] == nil then
		self.head_name = "round"
	end
	local head = tinted("head_" .. self.head_name, x, y, z, spec.skin)
	table.insert(self.rigid, head)
	if spec.hair ~= nil and spec.hair ~= "none" then
		local hair = tinted("hair_" .. spec.hair, x, y, z, spec.hair_color)
		table.insert(self.rigid, hair)
	end
	if spec.hat ~= nil and spec.hat ~= "none" then
		local hat = tinted("hat_" .. spec.hat, x, y, z, spec.hat_color)
		table.insert(self.rigid, hat)
	end

	self.sprites = {}
	local face = spec.face or {}
	for i = 1, #face do
		local p = face[i]
		local n = RIG.parts[p.part]
		if n ~= nil then
			local raw = flr(p.shape or 0)
			local shape = U.clamp(raw, 0, n - 1)
			local e = tinted("fp_" .. p.part .. shape, x, y, z, p.color)
			e.scale = FACE_SPRITE * (p.scale or 1)
			local s = {}
			s.e = e
			s.p = p
			table.insert(self.sprites, s)
		end
	end

	self.held = nil
	if spec.hand ~= nil then
		self.held = held(spec.hand, x, y, z)
	end
	self.clip = nil
end

function Character:kill()
	for i = 1, #self.skinned do
		self.skinned[i]:kill()
	end
	for i = 1, #self.rigid do
		self.rigid[i]:kill()
	end
	for i = 1, #self.sprites do
		self.sprites[i].e:kill()
	end
	if self.held ~= nil then
		self.held:kill()
	end
	self.skinned = {}
	self.rigid = {}
	self.sprites = {}
	self.held = nil
end

-- A new look: everything made again where it stands.
function Character:restyle(spec)
	self:kill()
	self:build(spec)
end

-- Pose it: feet at (x, y, z), facing `facing`, playing `clip`, with bone
-- rotations `turns` ({bone = {rx, ry, rz}}) on top of the clip.
function Character:pose(x, y, z, facing, clip, turns)
	self.x = x
	self.y = y
	self.z = z
	local k = self.k
	local zz = z + self.lift
	local restart = clip ~= self.clip
	self.clip = clip

	for i = 1, #self.skinned do
		local e = self.skinned[i]
		e.x = x
		e.y = y
		e.z = zz
		e.rz = facing
		if restart then
			e:anim(clip, true)
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

	-- the rigid pieces ride the head bone
	local hb = self.body:bone("head")
	local hx = x
	local hy = y
	local hz = zz + RIG.head_z * k
	if hb ~= nil then
		hx = hb.x
		hy = hb.y
		hz = hb.z
	end
	-- the head itself, then hair and hats at its crown
	local f = RIG.faces[self.head_name]
	for i = 1, #self.rigid do
		local e = self.rigid[i]
		e.x = hx
		e.y = hy
		e.z = hz
		if i > 1 then
			e.z = hz + f[5]
		end
		e.rz = facing
	end

	-- the face: across the front of the head, turned with it
	local c = cos(facing)
	local s = sin(facing)
	for i = 1, #self.sprites do
		local sp = self.sprites[i]
		local p = sp.p
		local lx = f[1] + FACE_LAYER * i
		local ly = (p.x or 0) * f[3]
		local lz = f[2] + (p.y or 0) * f[4]
		local e = sp.e
		e.x = hx + lx * c - ly * s
		e.y = hy + lx * s + ly * c
		e.z = hz + lz
		e.rz = facing
		e.rx = p.rot or 0
	end

	if self.held ~= nil then
		local hand = self.body:bone("hand.r")
		if hand ~= nil then
			self.held.x = hand.x
			self.held.y = hand.y
			self.held.z = hand.z - 0.05
			self.held.rz = facing
		end
	end
end

ZERO3 = { 0, 0, 0 }
