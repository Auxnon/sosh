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
--
-- Airships (ships.lua) are ground too. Standing on one, an avatar is `on`
-- it and rides along: every frame it's first carried by however the ship
-- moved and turned, then walks as usual, so ship and rider never part and
-- nothing jitters. Walking off the edge, it falls. Remote players aboard
-- report where on the ship they stand, so they're placed by the same
-- (eased) pose as the ship itself.
--
-- Momentum: (x, y) is the path, what goes on the wire and what everyone
-- carries us along. It ramps up to speed and loses most of it on a sharp
-- turn, so the path itself is a little heavy. The model is drawn somewhere
-- else, (bx, by): a free body with its own velocity chasing the path at a
-- runner's grip. Running, a turn of more than a right angle makes it plant
-- its feet and skid to a stop against the way it was going, kicking up
-- dust (Dust, below), then pick up speed again until it's back on the path.
-- Only the body is drawn; the path never leaves the walkable cells, and the
-- body is kept off walls and on a short leash to the path.

Avatar = {}
Avatar.__index = Avatar

-- Movement runs on real time (U.dt), not frames, so a slow machine walks
-- as fast as a quick one and the velocities on the wire mean what they say.
AV_SPEED = 4.2 -- tiles a second
AV_TURN = 11 -- rate the remaining turn is taken at, per second
AV_GRAVITY = 72 -- tiles a second, per second
AV_CORRECT = 9 -- rate the drift from the owner's position is fixed at, per second
AV_SNAP = 4 -- tiles adrift before jumping there instead
AV_ACCEL = 20 -- the path's speed up, tiles a second, per second
AV_TURN_KEEP = 0.3 -- of its speed the path keeps through a turn past a right angle
AV_GRIP = 15 -- the body's speed up and steering, tiles a second, per second
AV_BRAKE = 22 -- the body's braking in a skid
AV_PULL = 5 -- how hard the body chases where the path is, per second
AV_SKID_SPEED = 2.6 -- tiles a second: slower than this, it just turns
AV_SKID_TURN = -0.2 -- cos of the turn that makes it skid (about 100 degrees)
AV_SKID_END = 0.7 -- skidding until it's this slow
AV_LEASH = 1.5 -- tiles the body may trail the path
AV_ARRIVE = 9 -- the path's braking into the point it walks to, per second
AV_SETTLE = 24 -- the body's braking once the path has stopped
AV_BACKSTEP = 2.5 -- tiles a second: settling back slower than this, it steps back without turning round
AV_HEIGHT = 1.45 -- the player model, feet to the top of the head
FACE_COUNT = 8
ANIMS = { "idle", "sit" }
AV_HOLD_ARMS = 2.85 -- arms swung forward and up to what's carried
EMOTES = { "wave", "dance", "jump", "cheer" }
EMOTE_FRAMES = 150
EMOTE_SAY = { wave = "*waves*", dance = "*dances*", jump = "*jumps*", cheer = "*cheers*" }
BUBBLE_FRAMES = 480
BUBBLE_MAX = 3

function Avatar.new(id, name, x, y, z, face, anim, character)
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
	a.speed = 0 -- along the path, tiles a second
	a.ivx = 0 -- the velocity it's heading for (what `move` sends)
	a.ivy = 0
	a.bx = x -- where the body is drawn, and how it's moving
	a.by = y
	a.bvx = 0
	a.bvy = 0
	a.skid = false
	a.dust_t = 0
	a.heading = 0
	a.face = face % FACE_COUNT
	a.anim = anim % #ANIMS
	a.t = rnd() * 100
	a.walk = 0
	a.emote = nil
	a.emote_t = 0
	a.bubbles = {}
	a.hold = nil -- {x, y, z, heading}: where a carried thing goes
	a.on = nil -- the ship id it stands on, if any
	a.ton = nil -- the ship (tx, ty) is on, if they're in its frame
	-- where on ship `on` to stand once we know where that ship is
	a.wait = nil
	a.clip = nil -- the clip the model is playing
	a.hex = U.hex_for(id)
	a.character = character
	a:spawn()
	return a
end

function Avatar:spawn()
	self.char = Character.new(self.character, self.x, self.y, self.z)
	self:pose()
end

function Avatar:remove()
	self.char:kill()
end

-- The old face index: kept on the wire, but looks are characters now.
function Avatar:set_face(face)
	self.face = face % FACE_COUNT
end

-- A new look (character.lua): rebuilt where it stands.
function Avatar:set_character(spec)
	if spec == nil then
		return
	end
	self.character = spec
	self.char:restyle(spec)
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

-- Walk to (x, y): in the world, or on ship `on`, in its frame.
function Avatar:walk_to(x, y, on)
	self.tx = x
	self.ty = y
	self.ton = on
	self.dvx = 0
	self.dvy = 0
end

-- Move at (vx, vy) tiles a second until told otherwise.
function Avatar:drive(vx, vy)
	self.tx = nil
	self.ty = nil
	self.ton = nil
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
-- and stopping at `to` if it isn't nil. On ship `on`, all three are in its
-- frame.
function Avatar:follow(at, v, to, on)
	local x = at[1]
	local y = at[2]
	local z = at[3]
	local vx = 0
	local vy = 0
	if v ~= nil then
		vx = v[1]
		vy = v[2]
	end
	local s = Ships.get(on)
	if on ~= nil and s == nil then
		-- a ship we don't know yet: stand there once it shows up
		self.on = on
		self.wait = at
		self:stop()
		return
	end
	if s ~= nil then
		local wx, wy, wz = Ships.to_world(s, at[1], at[2], at[3])
		x = wx
		y = wy
		z = wz
		local c = cos(s.h)
		local n = sin(s.h)
		local wvx = vx * c - vy * n
		vy = vx * n + vy * c
		vx = wvx
	end
	self.on = on
	self.wait = nil
	local ex = x - self.x
	local ey = y - self.y
	if ex * ex + ey * ey > AV_SNAP * AV_SNAP or math.abs(z - self.z) > AV_SNAP then
		self:teleport(x, y, z)
		self.on = on
	else
		self.ex = ex
		self.ey = ey
	end
	if to ~= nil then
		self:walk_to(to[1], to[2], on)
	elseif v ~= nil then
		self:drive(vx, vy)
	else
		self:stop()
	end
end

function Avatar:teleport(x, y, z)
	self.x = x
	self.y = y
	self.z = z
	self.vz = 0
	self.on = nil
	self.wait = nil
	self.ex = 0
	self.ey = 0
	self:settle()
	self:stop()
end

-- The body back on the path, at rest.
function Avatar:settle()
	self.bx = self.x
	self.by = self.y
	self.bvx = 0
	self.bvy = 0
	self.speed = 0
	self.ivx = 0
	self.ivy = 0
	self.skid = false
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

-- Where a foot can find purchase off the middle: so a sliver of a gap
-- between a ship and the shore, or a deck's edge, doesn't stop anyone.
AV_TOES = { { 0.3, 0 }, { -0.3, 0 }, { 0, 0.3 }, { 0, -0.3 } }

-- Where feet rest at (x, y) for someone at height z: on the world's blocks
-- or a ship's, whichever is higher (one block up is a step, as
-- Blocks.ground); and the ship's id if it's a ship. Over nothing, what's
-- under their toes, if anything. nil if nothing's below.
function Avatar.footing(x, y, z)
	local g, on = Avatar.footing_at(x, y, z)
	if g ~= nil then
		return g, on
	end
	for i = 1, #AV_TOES do
		local t = AV_TOES[i]
		local tg, ton = Avatar.footing_at(x + t[1], y + t[2], z)
		if tg ~= nil and (g == nil or tg > g) then
			g = tg
			on = ton
		end
	end
	return g, on
end

-- Avatar.footing, right under (x, y).
function Avatar.footing_at(x, y, z)
	local g = Blocks.ground(x, y, z)
	local on = nil
	for id, s in pairs(Ships.list) do
		local sg = Ships.ground(s, x, y, z)
		if sg ~= nil and (g == nil or sg > g) then
			g = sg
			on = id
		end
	end
	return g, on
end

-- Can someone at height z walk into (x, y)? Ground underfoot and two clear
-- cells of headroom, in the world and on every ship.
function Avatar.walkable(x, y, z)
	local g = Avatar.footing(x, y, z)
	if g == nil then
		return false
	end
	local cx = Blocks.cell(x)
	local cy = Blocks.cell(y)
	local gz = flr(g + 0.01)
	if Blocks.get(cx, cy, gz) ~= 0 or Blocks.get(cx, cy, gz + 1) ~= 0 then
		return false
	end
	local knee = g + 0.5
	local head = g + 1.5
	return not Ships.solid_at(x, y, knee) and not Ships.solid_at(x, y, head)
end

-- Move by (wx, wy) if the way is clear. Driven avatars slide along a wall
-- on whichever axis is free; one walking to a point just stops there.
-- Returns true if it moved.
function Avatar:step(wx, wy, dt)
	local nx = self.x + wx
	local ny = self.y + wy
	if not Avatar.walkable(nx, ny, self.z) then
		if self.tx ~= nil then
			return false
		end
		if wx ~= 0 and Avatar.walkable(nx, self.y, self.z) then
			ny = self.y
		elseif wy ~= 0 and Avatar.walkable(self.x, ny, self.z) then
			nx = self.x
		else
			return false
		end
	end
	self.x = nx
	self.y = ny
	return true
end

-- Carried by the ship we stand on, however it moved since last frame. A
-- ship we're waiting to learn about holds us where we are.
function Avatar:ride()
	if self.on == nil then
		return true
	end
	local s = Ships.get(self.on)
	if s == nil then
		if self.wait ~= nil then
			return false
		end
		self.on = nil
		return true
	end
	if self.wait ~= nil then
		local w = self.wait
		local wx, wy, wz = Ships.to_world(s, w[1], w[2], w[3])
		self.x = wx
		self.y = wy
		self.z = wz
		self.wait = nil
		self.vz = 0
		self:settle()
		return true
	end
	local x, y, z, turned = Ships.carry(s, self.x, self.y, self.z)
	self.x = x
	self.y = y
	self.z = z
	self.heading = self.heading + turned
	local bx, by = Ships.carry(s, self.bx, self.by, self.z)
	self.bx = bx
	self.by = by
	local c = cos(turned)
	local n = sin(turned)
	local bvx = self.bvx * c - self.bvy * n
	self.bvy = self.bvx * n + self.bvy * c
	self.bvx = bvx
	return true
end

function Avatar:update(dt)
	self.t = self.t + 1

	if not self:ride() then
		self:age_bubbles()
		self:pose()
		return
	end

	local px = self.x
	local py = self.y
	local full = sqrt(self.dvx * self.dvx + self.dvy * self.dvy)
	local ux = 0 -- the way the path goes, a unit vector
	local uy = 0
	if full > 0 then
		ux = self.dvx / full
		uy = self.dvy / full
	end
	local left = nil -- to the point we walk to
	if self.tx ~= nil then
		-- the point to walk to, in the world now
		local gx = self.tx
		local gy = self.ty
		local ts = Ships.get(self.ton)
		if ts ~= nil then
			local wx, wy, wz = Ships.to_world(ts, self.tx, self.ty, 0)
			gx = wx
			gy = wy
		end
		local dx = gx - self.x
		local dy = gy - self.y
		local dist = sqrt(dx * dx + dy * dy)
		full = 0
		if dist > 0.02 then
			full = AV_SPEED
			ux = dx / dist
			uy = dy / dist
			left = dist
		else
			self.tx = nil
			self.ty = nil
			self.ton = nil
		end
	end
	self.speed = self:path_speed(ux, uy, full, dt, left)
	self.ivx = ux * full
	self.ivy = uy * full
	local step = self.speed * dt
	if left ~= nil and step > left then
		step = left
	end
	local wx = ux * step
	local wy = uy * step
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
	-- stopped (walled in, or there): lose the speed. A frame in which no
	-- time passed (dt 0: the web build's clock doesn't always move between
	-- frames) took no step either, but that's no reason to stop.
	if not stepping and dt > 0 then
		self.speed = 0
		self.ivx = 0
		self.ivy = 0
	end
	self:chase(dt)

	-- blocks, the world's or a ship's: step up onto a single block, fall
	-- otherwise; standing on a ship, we're on it
	local g, on = Avatar.footing(self.x, self.y, self.z)
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
		if self.z == g then
			self.on = on
		else
			self.on = nil
		end
	else
		self.on = nil
	end

	if self.emote_t > 0 then
		self.emote_t = self.emote_t - 1
		if self.emote_t == 0 then
			self.emote = nil
		end
	end

	self:age_bubbles()
	self:pose()
end

-- The path's speed this frame, going (ux, uy) at up to `full`: it speeds up
-- at AV_ACCEL, and a turn of more than a right angle from the way it was
-- going keeps only a little of what it had. Walking to a point `left` tiles
-- away, it slows into it (at AV_ARRIVE), so the body comes to rest there
-- rather than running past and turning back.
function Avatar:path_speed(ux, uy, full, dt, left)
	local sp = self.speed
	if full == 0 then
		return 0
	end
	local v = sqrt(self.vx * self.vx + self.vy * self.vy)
	if v > 0.5 and (self.vx * ux + self.vy * uy) / v < 0 then
		local keep = full * AV_TURN_KEEP
		if sp > keep then
			sp = keep
		end
	end
	sp = sp + AV_ACCEL * dt
	if sp > full then
		sp = full
	end
	if left ~= nil then
		local arrive = sqrt(2 * AV_ARRIVE * left) + 0.6
		if sp > arrive then
			sp = arrive
		end
	end
	return sp
end

-- Move the body after the path: steer its velocity at the path's own plus a
-- pull toward where the path is, at AV_GRIP; or, running into a sharp turn,
-- brake against the way it's going (and kick up dust) until it's slow
-- enough to turn. It faces the way it moves, and walks as fast as it goes.
function Avatar:chase(dt)
	local dx = self.x - self.bx
	local dy = self.y - self.by
	local wx = self.vx + dx * AV_PULL
	local wy = self.vy + dy * AV_PULL
	local want = sqrt(wx * wx + wy * wy)
	local cap = AV_SPEED * 1.3
	if want > cap then
		wx = wx / want * cap
		wy = wy / want * cap
		want = cap
	end
	local bvx = self.bvx
	local bvy = self.bvy
	local sp = sqrt(bvx * bvx + bvy * bvy)
	if not self.skid and sp > AV_SKID_SPEED and want > 0.5 then
		self.skid = (bvx * wx + bvy * wy) / (sp * want) < AV_SKID_TURN
	end
	if self.skid then
		local brake = AV_BRAKE * dt
		if brake >= sp then
			bvx = 0
			bvy = 0
		else
			bvx = bvx - bvx / sp * brake
			bvy = bvy - bvy / sp * brake
		end
		self.dust_t = self.dust_t - dt
		if self.dust_t <= 0 then
			self.dust_t = 0.035
			Dust.kick(self.bx, self.by, self.z, bvx, bvy)
		end
		if sp - brake < AV_SKID_END then
			self.skid = false
		end
	else
		local ax = wx - bvx
		local ay = wy - bvy
		local a = sqrt(ax * ax + ay * ay)
		local grip = AV_GRIP * dt
		if self.ivx == 0 and self.ivy == 0 then
			grip = AV_SETTLE * dt -- the path stopped: dig in
		end
		if a > grip then
			ax = ax / a * grip
			ay = ay / a * grip
		end
		bvx = bvx + ax
		bvy = bvy + ay
	end
	-- off walls (the body slides along them), and never far from the path
	local nx = self.bx + bvx * dt
	local ny = self.by + bvy * dt
	if not Avatar.walkable(nx, ny, self.z) then
		if Avatar.walkable(nx, self.by, self.z) then
			ny = self.by
			bvy = 0
		elseif Avatar.walkable(self.bx, ny, self.z) then
			nx = self.bx
			bvx = 0
		else
			nx = self.bx
			ny = self.by
			bvx = 0
			bvy = 0
		end
	end
	local ox = nx - self.x
	local oy = ny - self.y
	local off = sqrt(ox * ox + oy * oy)
	if off > AV_LEASH * 2 then
		self:settle()
		nx = self.x
		ny = self.y
		bvx = 0
		bvy = 0
	elseif off > AV_LEASH then
		nx = self.x + ox / off * AV_LEASH
		ny = self.y + oy / off * AV_LEASH
	end
	self.bx = nx
	self.by = ny
	self.bvx = bvx
	self.bvy = bvy

	sp = sqrt(bvx * bvx + bvy * bvy)
	self:turn(bvx, bvy, sp, dt)
	local stride = U.clamp(sp / AV_SPEED, 0, 1)
	if self.skid then
		stride = 0
	end
	self.walk = U.lerp(self.walk, stride, 0.2)
end

-- Face the way we're going, weighted by momentum: toward the body's motion
-- leaning into where the path wants to go, turning faster the faster we
-- move. Settling (the path has stopped) and drifting back behind us slowly,
-- we step back rather than spin round to face it, and a skid holds the
-- heading it braked in.
function Avatar:turn(bvx, bvy, sp, dt)
	if self.skid or sp < 0.25 then
		return
	end
	local fx = bvx + self.ivx * 0.5
	local fy = bvy + self.ivy * 0.5
	local settling = self.ivx == 0 and self.ivy == 0
	if settling and sp < AV_BACKSTEP then
		local hx = cos(self.heading)
		local hy = sin(self.heading)
		if bvx * hx + bvy * hy < 0 then
			return
		end
	end
	local face = U.atan2(fy, fx)
	local rate = AV_TURN * U.clamp(sp / AV_SPEED * 1.5, 0.25, 1)
	self.heading = self.heading + U.angle_diff(self.heading, face) * U.rate(rate, dt)
end

function Avatar:age_bubbles()
	local i = #self.bubbles
	while i >= 1 do
		local b = self.bubbles[i]
		b.ttl = b.ttl - 1
		if b.ttl <= 0 then
			table.remove(self.bubbles, i)
		end
		i = i - 1
	end
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
	local holding = Carry.holds(self)

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
	local legl = -swing
	local legr = -swing
	if self.skid and self.anim ~= 1 then
		-- braced: a foot planted out front, arms thrown forward and out
		fl = -1.1
		fr = 1.1
		ll = 0.5
		lr = -0.5
		legl = -0.7
		legr = 0.35
		bob = -0.04
	end
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

	-- the clip, with arms and legs turned on top of it (character.lua
	-- applies them to the body and every piece of clothing alike)
	local turns = {}
	turns["shoulder.l"] = { 0, fl, 0 }
	turns["shoulder.r"] = { 0, fr, 0 }
	turns["arm.l"] = { 0, 0, ll }
	turns["arm.r"] = { 0, 0, lr }
	turns["waist.l"] = { 0, legl, 0 }
	turns["waist.r"] = { 0, legr, 0 }
	self.clip = clip
	self.char:pose(self.bx, self.by, self.z + bob, h + twist, clip, turns)

	local hold = { self.bx, self.by, self.z + bob + CARRY_Z, h }
	self.hold = hold
end

-- Point above the head where the name tag sits, as {x, y, z}; above what
-- they carry, if anything.
function Avatar:top()
	local z = self.z + AV_HEIGHT * self.char.k + self.char.lift + 0.15
	local held = Carry.height(self.id)
	if held > 0 and self.hold ~= nil then
		z = self.hold[3] + held + 0.15
	end
	local p = { self.bx, self.by, z }
	return p
end

-- Dust kicked up by a skid: little puffs (assets/dust.png, a billboard)
-- thrown back the way the body was going, rising and swelling, then gone.
Dust = {}
Dust.list = {}
DUST_MAX = 32
DUST_LIFE = 0.45 -- seconds

function Dust.kick(x, y, z, vx, vy)
	if #Dust.list >= DUST_MAX then
		return
	end
	local d = {}
	d.x = x - vx * 0.06 + (rnd() - 0.5) * 0.4
	d.y = y - vy * 0.06 + (rnd() - 0.5) * 0.4
	d.z = z + 0.1
	-- forward and out a little, off the ground
	d.vx = vx * 0.25 + (rnd() - 0.5) * 1.2
	d.vy = vy * 0.25 + (rnd() - 0.5) * 1.2
	d.vz = 0.6 + rnd() * 0.6
	d.t = 0
	d.k = 0.25 + rnd() * 0.15
	-- hoisted (SILT-BUGS.md #7)
	local ent = make("dust", d.x, d.y, d.z, d.k)
	d.ent = ent
	table.insert(Dust.list, d)
end

function Dust.update(dt)
	local i = #Dust.list
	while i >= 1 do
		local d = Dust.list[i]
		d.t = d.t + dt
		if d.t >= DUST_LIFE then
			d.ent:kill()
			table.remove(Dust.list, i)
		else
			local drag = U.rate(6, dt)
			d.vx = d.vx - d.vx * drag
			d.vy = d.vy - d.vy * drag
			d.x = d.x + d.vx * dt
			d.y = d.y + d.vy * dt
			d.z = d.z + d.vz * dt
			-- swells, then shrinks away
			local p = d.t / DUST_LIFE
			d.ent.x = d.x
			d.ent.y = d.y
			d.ent.z = d.z
			d.ent.scale = d.k * (1 + p * 1.5) * (1 - p * p)
		end
		i = i - 1
	end
end
