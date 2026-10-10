-- avatar — a player in the world, local or remote.
--
-- Built from the generated models in assets/ (tools/gen_assets.py): a tinted
-- body, two tinted arms and a head whose model carries the face. On the web
-- build only an entity's transform syncs after the frame it was made in, so
-- every other property is set right after make(), and changing the face
-- swaps the head entity rather than retexturing it.
--
-- Avatars walk toward a target point; both local input and the network just
-- set the target. Poses are procedural.

Avatar = {}
Avatar.__index = Avatar

AV_SPEED = 0.07 -- tiles per frame
AV_TURN = 0.18 -- fraction of the remaining turn taken per frame
AV_BODY_H = 0.85
AV_SHOULDER = 0.27
FACE_COUNT = 8
ANIMS = { "idle", "sit", "carry" }
BUBBLE_FRAMES = 480
BUBBLE_MAX = 3

function Avatar.new(id, name, x, y, face, anim)
	local a = setmetatable({}, Avatar)
	a.id = id
	a.name = name
	a.x = x
	a.y = y
	a.tx = x
	a.ty = y
	a.heading = 0
	a.face = face % FACE_COUNT
	a.anim = anim % #ANIMS
	a.t = rnd() * 100
	a.walk = 0
	a.bubbles = {}
	a.tint = U.tint_for(id)
	a.hex = U.hex_for(id)
	a:spawn()
	return a
end

function Avatar:spawn()
	local tint = self.tint
	self.body = make("body", self.x, self.y, GROUND_Z, 1)
	self.body.tint = tint
	self.arm_l = make("arm", self.x, self.y, GROUND_Z, 1)
	self.arm_l.tint = tint
	self.arm_r = make("arm", self.x, self.y, GROUND_Z, 1)
	self.arm_r.tint = tint
	self.head = make("head" .. self.face, self.x, self.y, GROUND_Z, 1)
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
	self.head = make("head" .. face, self.x, self.y, GROUND_Z, 1)
	self:pose()
end

function Avatar:set_anim(anim)
	self.anim = anim % #ANIMS
end

function Avatar:anim_name()
	return ANIMS[self.anim + 1]
end

function Avatar:walk_to(x, y)
	self.tx = x
	self.ty = y
end

function Avatar:teleport(x, y)
	self.x = x
	self.y = y
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
		self.x = self.x + dx / dist * step
		self.y = self.y + dy / dist * step
		local want = U.atan2(dy, dx)
		self.heading = self.heading + U.angle_diff(self.heading, want) * AV_TURN
		stepping = true
	end
	if stepping then
		self.walk = U.lerp(self.walk, 1, 0.2)
	else
		self.walk = U.lerp(self.walk, 0, 0.2)
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

-- Place every part from position, heading, animation and time.
function Avatar:pose()
	local h = self.heading
	local fx = cos(h)
	local fy = sin(h)
	-- side vector: the avatar's left
	local sx = -fy
	local sy = fx
	local t = self.t
	local anim = self.anim

	local z = GROUND_Z
	local bob = 0
	local swing = 0
	local arm_pitch = 0
	if anim == 1 then
		-- sit: sink, arms resting forward on the knees
		z = z - 0.32
		arm_pitch = -0.9
	else
		bob = math.abs(sin(t * 0.24)) * 0.06 * self.walk + sin(t * 0.05) * 0.012
		swing = sin(t * 0.24) * 0.7 * self.walk
		if anim == 2 then
			-- carry: arms straight out front
			arm_pitch = -1.45
			swing = swing * 0.15
		end
	end

	local body = self.body
	body.x = self.x
	body.y = self.y
	body.z = z + bob
	body.rz = h

	local head = self.head
	head.x = self.x
	head.y = self.y
	head.z = z + bob * 1.4 + AV_BODY_H
	head.rz = h

	local sz = z + bob + AV_BODY_H - 0.08
	local al = self.arm_l
	al.x = self.x + sx * AV_SHOULDER
	al.y = self.y + sy * AV_SHOULDER
	al.z = sz
	al.rz = h
	al.ry = arm_pitch + swing
	local ar = self.arm_r
	ar.x = self.x - sx * AV_SHOULDER
	ar.y = self.y - sy * AV_SHOULDER
	ar.z = sz
	ar.rz = h
	ar.ry = arm_pitch - swing
end

-- Point above the head where the name tag sits, as {x, y, z}.
function Avatar:top()
	local p = { self.x, self.y, self.head.z + 0.75 }
	return p
end
