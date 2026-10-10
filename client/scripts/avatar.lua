-- avatar — a player in the world, local or remote.
--
-- Built from the generated models in assets/ (tools/gen_assets.py): a tinted
-- body, two tinted arms and a head whose model carries the face. On the web
-- build only an entity's transform syncs after the frame it was made in, so
-- every other property is set right after make(), and changing the face
-- swaps the head entity rather than retexturing it.
--
-- Avatars walk toward a target point over the block terrain (blocks.lua):
-- one block is a step, two is a wall, and they fall off edges. Local input
-- and the network both just set the target. Poses and emotes are procedural
-- placeholders until the rigged player model is in.

Avatar = {}
Avatar.__index = Avatar

AV_SPEED = 0.07 -- tiles per frame
AV_TURN = 0.18 -- fraction of the remaining turn taken per frame
AV_GRAVITY = 0.02
AV_BODY_H = 0.85
AV_SHOULDER = 0.27
FACE_COUNT = 8
ANIMS = { "idle", "sit", "carry" }
EMOTES = { "wave", "dance", "jump", "cheer" }
EMOTE_FRAMES = 150
EMOTE_SAY = { wave = "*waves*", dance = "*dances*", jump = "*jumps*", cheer = "*cheers*" }
BUBBLE_FRAMES = 480
BUBBLE_MAX = 3

function Avatar.new(id, name, x, y, z, face, anim)
	local a = setmetatable({}, Avatar)
	a.id = id
	a.name = name
	a.x = x
	a.y = y
	a.z = z
	a.vz = 0
	a.tx = x
	a.ty = y
	a.heading = 0
	a.face = face % FACE_COUNT
	a.anim = anim % #ANIMS
	a.t = rnd() * 100
	a.walk = 0
	a.emote = nil
	a.emote_t = 0
	a.bubbles = {}
	a.tint = U.tint_for(id)
	a.hex = U.hex_for(id)
	a:spawn()
	return a
end

function Avatar:spawn()
	local tint = self.tint
	self.body = make("body", self.x, self.y, self.z, 1)
	self.body.tint = tint
	self.arm_l = make("arm", self.x, self.y, self.z, 1)
	self.arm_l.tint = tint
	self.arm_r = make("arm", self.x, self.y, self.z, 1)
	self.arm_r.tint = tint
	self.head = make("head" .. self.face, self.x, self.y, self.z, 1)
	self:pose()
end

function Avatar:remove()
	self.body:kill()
	self.arm_l:kill()
	self.arm_r:kill()
	self.head:kill()
end

function Avatar:set_face(face)
	face = face % FACE_COUNT
	if face == self.face then
		return
	end
	self.face = face
	self.head:kill()
	self.head = make("head" .. face, self.x, self.y, self.z, 1)
	self:pose()
end

function Avatar:set_anim(anim)
	self.anim = anim % #ANIMS
end

function Avatar:anim_name()
	return ANIMS[self.anim + 1]
end

function Avatar:play_emote(name)
	if EMOTE_SAY[name] == nil then
		return
	end
	self.emote = name
	self.emote_t = EMOTE_FRAMES
	if self.anim == 1 then
		self.anim = 0 -- stand up for it
	end
	self:say(EMOTE_SAY[name])
end

function Avatar:walk_to(x, y)
	self.tx = x
	self.ty = y
end

function Avatar:teleport(x, y, z)
	self.x = x
	self.y = y
	self.z = z
	self.vz = 0
	self.tx = x
	self.ty = y
end

function Avatar:moving()
	return self.walk > 0.05
end

function Avatar:say(text)
	local lines = U.wrap(text, 24)
	local b = {}
	b.lines = lines
	b.ttl = BUBBLE_FRAMES
	table.insert(self.bubbles, b)
	while #self.bubbles > BUBBLE_MAX do
		table.remove(self.bubbles, 1)
	end
end

function Avatar:update()
	self.t = self.t + 1

	local dx = self.tx - self.x
	local dy = self.ty - self.y
	local dist = sqrt(dx * dx + dy * dy)
	local stepping = false
	if dist > 0.02 and self.anim ~= 1 then
		local step = AV_SPEED
		if step > dist then
			step = dist
		end
		local nx = self.x + dx / dist * step
		local ny = self.y + dy / dist * step
		if Blocks.walkable(nx, ny, self.z) then
			self.x = nx
			self.y = ny
			local want = U.atan2(dy, dx)
			self.heading = self.heading + U.angle_diff(self.heading, want) * AV_TURN
			stepping = true
		else
			-- blocked: give up on this target
			self.tx = self.x
			self.ty = self.y
		end
	end
	if stepping then
		self.walk = U.lerp(self.walk, 1, 0.2)
	else
		self.walk = U.lerp(self.walk, 0, 0.2)
	end

	-- terrain: step up onto a single block, fall otherwise
	local g = Blocks.ground(self.x, self.y, self.z)
	if g ~= nil then
		if g >= self.z then
			self.z = g
			self.vz = 0
		else
			self.vz = self.vz - AV_GRAVITY
			self.z = self.z + self.vz
			if self.z < g then
				self.z = g
				self.vz = 0
			end
		end
	end

	if self.emote_t > 0 then
		self.emote_t = self.emote_t - 1
		if self.emote_t == 0 then
			self.emote = nil
		end
	end

	local i = #self.bubbles
	while i >= 1 do
		local b = self.bubbles[i]
		b.ttl = b.ttl - 1
		if b.ttl <= 0 then
			table.remove(self.bubbles, i)
		end
		i = i - 1
	end

	self:pose()
end

-- Place every part from position, heading, animation, emote and time.
function Avatar:pose()
	local h = self.heading
	local t = self.t
	local anim = self.anim

	local z = self.z
	local bob = 0
	local swing = 0
	local arm_l = 0
	local arm_r = 0
	local twist = 0
	if anim == 1 then
		-- sit: sink, arms resting forward on the knees
		z = z - 0.32
		arm_l = -0.9
		arm_r = -0.9
	else
		bob = math.abs(sin(t * 0.24)) * 0.06 * self.walk + sin(t * 0.05) * 0.012
		swing = sin(t * 0.24) * 0.7 * self.walk
		if anim == 2 then
			-- carry: arms straight out front
			arm_l = -1.45
			arm_r = -1.45
			swing = swing * 0.15
		end
	end

	local e = self.emote
	if e ~= nil then
		-- 0 -> 1 over the emote, for one-shot shapes
		local p = 1 - self.emote_t / EMOTE_FRAMES
		if e == "wave" then
			arm_r = -2.7 + sin(t * 0.4) * 0.35
		elseif e == "dance" then
			twist = sin(t * 0.25) * 0.6
			bob = bob + math.abs(sin(t * 0.25)) * 0.12
			arm_l = -1.2 + sin(t * 0.25) * 0.8
			arm_r = -1.2 - sin(t * 0.25) * 0.8
		elseif e == "jump" then
			-- two hops
			bob = bob + math.abs(sin(p * math.pi * 2)) * 0.9
			arm_l = -0.6
			arm_r = -0.6
		elseif e == "cheer" then
			bob = bob + math.abs(sin(t * 0.3)) * 0.1
			arm_l = -2.9 + sin(t * 0.3) * 0.2
			arm_r = -2.9 - sin(t * 0.3) * 0.2
		end
	end

	local facing = h + twist
	local fx = cos(facing)
	local fy = sin(facing)
	-- side vector: the avatar's left
	local sx = -fy
	local sy = fx

	local body = self.body
	body.x = self.x
	body.y = self.y
	body.z = z + bob
	body.rz = facing

	local head = self.head
	head.x = self.x
	head.y = self.y
	head.z = z + bob * 1.4 + AV_BODY_H
	head.rz = h

	local shoulder_z = z + bob + AV_BODY_H - 0.08
	local al = self.arm_l
	al.x = self.x + sx * AV_SHOULDER
	al.y = self.y + sy * AV_SHOULDER
	al.z = shoulder_z
	al.rz = facing
	al.ry = arm_l + swing
	local ar = self.arm_r
	ar.x = self.x - sx * AV_SHOULDER
	ar.y = self.y - sy * AV_SHOULDER
	ar.z = shoulder_z
	ar.rz = facing
	ar.ry = arm_r - swing
end

-- Point above the head where the name tag sits, as {x, y, z}.
function Avatar:top()
	local p = { self.x, self.y, self.head.z + 0.75 }
	return p
end
