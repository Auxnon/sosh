-- avatar — a player in the world, local or remote.
--
-- The rigged player model (assets/player.glb, converted from the old web
-- client's by tools/gen_assets.py) plays its clips: idle, sit and carry are
-- still poses. Walking and emotes bend its bones on top of the clip
-- (`ent:bone`). The face is its own small model, face0-7, kept on the head
-- bone; on the web build only an entity's transform syncs after the frame it
-- was made in, so changing the face swaps that entity rather than
-- retexturing it.
--
-- Avatars move over the block terrain (blocks.lua): one block is a step, two
-- is a wall, and they fall off edges. Either they walk to a point (a click,
-- `walk_to`) or they're driven at a velocity (the keys, `drive`), sliding
-- along walls. Remote avatars follow the owner's `move` messages
-- (`follow`): the same motion, carried on between messages, and any drift
-- from where the owner says they are eased away over a few frames. Whatever
-- they carry (carry.lua) rides over their head, arms raised to it.

Avatar = {}
Avatar.__index = Avatar

-- Movement runs on real time (U.dt), not frames, so a slow machine walks
-- as fast as a quick one and the velocities on the wire mean what they say.
AV_SPEED = 4.2 -- tiles a second
AV_TURN = 11 -- rate the remaining turn is taken at, per second
AV_GRAVITY = 72 -- tiles a second, per second
AV_CORRECT = 9 -- rate the drift from the owner's position is fixed at, per second
AV_SNAP = 4 -- tiles adrift before jumping there instead
AV_HEIGHT = 1.45 -- the player model, feet to the top of the head
FACE_COUNT = 8
ANIMS = { "idle", "sit" }
AV_HOLD_ARMS = 2.85 -- arms swung forward and up to what's carried
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
	a.tx = nil -- walking to (tx, ty) when set
	a.ty = nil
	a.dvx = 0 -- else driven at this, tiles a second
	a.dvy = 0
	a.vx = 0 -- how fast it actually moved last frame, tiles a second
	a.vy = 0
	a.ex = 0 -- drift still to correct
	a.ey = 0
	a.heading = 0
	a.face = face % FACE_COUNT
	a.anim = anim % #ANIMS
	a.t = rnd() * 100
	a.walk = 0
	a.emote = nil
	a.emote_t = 0
	a.bubbles = {}
	a.hold = nil -- {x, y, z, heading}: where a carried thing goes
	a.clip = nil -- the clip the model is playing
	a.hex = U.hex_for(id)
	a:spawn()
	return a
end

function Avatar:spawn()
	self.body = make("player", self.x, self.y, self.z, 1)
	self.head = make("face" .. self.face, self.x, self.y, self.z, 1)
	self:pose()
end

function Avatar:remove()
	self.body:kill()
	self.head:kill()
end

function Avatar:set_face(face)
	face = face % FACE_COUNT
	if face == self.face then
		return
	end
	self.face = face
	self.head:kill()
	self.head = make("face" .. face, self.x, self.y, self.z, 1)
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
	self.dvx = 0
	self.dvy = 0
end

-- Move at (vx, vy) tiles a second until told otherwise.
function Avatar:drive(vx, vy)
	self.tx = nil
	self.ty = nil
	self.dvx = vx
	self.dvy = vy
end

function Avatar:stop()
	self:drive(0, 0)
end

function Avatar:driven()
	return self.tx == nil and (self.dvx ~= 0 or self.dvy ~= 0)
end

-- A remote player's `move`: they're at `at`, moving at `v` tiles a second,
-- and stopping at `to` if it isn't nil.
function Avatar:follow(at, v, to)
	local ex = at[1] - self.x
	local ey = at[2] - self.y
	if ex * ex + ey * ey > AV_SNAP * AV_SNAP then
		self:teleport(at[1], at[2], at[3])
	else
		self.ex = ex
		self.ey = ey
	end
	if to ~= nil then
		self:walk_to(to[1], to[2])
	elseif v ~= nil then
		self:drive(v[1], v[2])
	else
		self:stop()
	end
end

function Avatar:teleport(x, y, z)
	self.x = x
	self.y = y
	self.z = z
	self.vz = 0
	self.ex = 0
	self.ey = 0
	self:stop()
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

-- Move by (wx, wy) if the way is clear. Driven avatars slide along a wall
-- on whichever axis is free; one walking to a point just stops there.
-- Returns true if it moved.
function Avatar:step(wx, wy, dt)
	local nx = self.x + wx
	local ny = self.y + wy
	if not Blocks.walkable(nx, ny, self.z) then
		if self.tx ~= nil then
			return false
		end
		if wx ~= 0 and Blocks.walkable(nx, self.y, self.z) then
			ny = self.y
		elseif wy ~= 0 and Blocks.walkable(self.x, ny, self.z) then
			nx = self.x
		else
			return false
		end
	end
	local want = U.atan2(ny - self.y, nx - self.x)
	self.heading = self.heading + U.angle_diff(self.heading, want) * U.rate(AV_TURN, dt)
	self.x = nx
	self.y = ny
	return true
end

function Avatar:update(dt)
	self.t = self.t + 1

	local px = self.x
	local py = self.y
	local wx = self.dvx * dt
	local wy = self.dvy * dt
	if self.tx ~= nil then
		local dx = self.tx - self.x
		local dy = self.ty - self.y
		local dist = sqrt(dx * dx + dy * dy)
		if dist > 0.02 then
			local step = AV_SPEED * dt
			if step > dist then
				step = dist
			end
			wx = dx / dist * step
			wy = dy / dist * step
		else
			self.tx = nil
			self.ty = nil
			wx = 0
			wy = 0
		end
	end
	local stepping = false
	if (wx ~= 0 or wy ~= 0) and self.anim ~= 1 then
		stepping = self:step(wx, wy, dt)
		if not stepping then
			-- walled in: give up and stand
			self:stop()
		end
	end
	if dt > 0 then
		self.vx = (self.x - px) / dt
		self.vy = (self.y - py) / dt
	end

	-- ease off any drift from where the owner says we are
	if self.ex ~= 0 or self.ey ~= 0 then
		local k = U.rate(AV_CORRECT, dt)
		local cx = self.ex * k
		local cy = self.ey * k
		self.x = self.x + cx
		self.y = self.y + cy
		self.ex = self.ex - cx
		self.ey = self.ey - cy
		if math.abs(self.ex) + math.abs(self.ey) < 0.001 then
			self.ex = 0
			self.ey = 0
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
			self.vz = self.vz - AV_GRAVITY * dt
			self.z = self.z + self.vz * dt
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

-- Pose the model from position, heading, animation, emote and time: the
-- clip, then bones bent on top of it, then the face on the head.
--
-- The bones turn in their own frames, and every limb's local z points
-- forward. Arms swing forward and back at the collarbone (shoulder.l/r,
-- about local y: + takes the left arm back and the right forward), whose
-- side axis runs through the shoulder joint, and lift out sideways at the
-- upper arm (arm.l/r, about local z: + the left out, - the right); lifting
-- at the collarbone would pivot from the neck. Legs swing at the hips
-- (waist.l/r) as the arms do at the collarbones.
function Avatar:pose()
	local h = self.heading
	local t = self.t
	local holding = Carry.of(self.id) ~= nil

	local clip = "idle"
	local bob = 0
	local swing = 0
	if self.anim == 1 then
		clip = "sit"
	else
		bob = math.abs(sin(t * 0.24)) * 0.06 * self.walk + sin(t * 0.05) * 0.012
		swing = sin(t * 0.24) * 0.7 * self.walk
	end
	-- arms: forward swing and sideways lift, left and right
	local fl = swing
	local fr = swing
	local ll = 0
	local lr = 0
	local twist = 0
	if holding then
		fl = -AV_HOLD_ARMS
		fr = AV_HOLD_ARMS
	end

	local e = self.emote
	if e ~= nil and not holding then
		-- 0 -> 1 over the emote, for one-shot shapes
		local p = 1 - self.emote_t / EMOTE_FRAMES
		if e == "wave" then
			lr = -2.3 + sin(t * 0.4) * 0.35
			fr = 0
		elseif e == "dance" then
			twist = sin(t * 0.25) * 0.6
			bob = bob + math.abs(sin(t * 0.25)) * 0.12
			ll = 1.2 + sin(t * 0.25) * 0.8
			lr = -1.2 + sin(t * 0.25) * 0.8
		elseif e == "jump" then
			-- two hops
			bob = bob + math.abs(sin(p * math.pi * 2)) * 0.9
			ll = 0.6
			lr = -0.6
		elseif e == "cheer" then
			bob = bob + math.abs(sin(t * 0.3)) * 0.1
			ll = 2.4 + sin(t * 0.3) * 0.2
			lr = -2.4 + sin(t * 0.3) * 0.2
			fl = 0
			fr = 0
		end
	end

	local body = self.body
	if clip ~= self.clip then
		self.clip = clip
		body:anim(clip)
	end
	local facing = h + twist
	body.x = self.x
	body.y = self.y
	body.z = self.z + bob
	body.rz = facing
	body:bone("shoulder.l", { 0, fl, 0 })
	body:bone("shoulder.r", { 0, fr, 0 })
	body:bone("arm.l", { 0, 0, ll })
	body:bone("arm.r", { 0, 0, lr })
	body:bone("waist.l", { 0, -swing, 0 })
	body:bone("waist.r", { 0, -swing, 0 })

	-- the face model's origin is the head bone's
	local head = self.head
	local hb = body:bone("head")
	if hb ~= nil then
		head.x = hb.x
		head.y = hb.y
		head.z = hb.z
	end
	head.rz = facing

	local hold = { self.x, self.y, self.z + bob + CARRY_Z, h }
	self.hold = hold
end

-- Point above the head where the name tag sits, as {x, y, z}; above what
-- they carry, if anything.
function Avatar:top()
	local z = self.body.z + AV_HEIGHT + 0.15
	local held = Carry.height(self.id)
	if held > 0 and self.hold ~= nil then
		z = self.hold[3] + held + 0.15
	end
	local p = { self.x, self.y, z }
	return p
end
