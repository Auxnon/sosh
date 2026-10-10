-- world — the plaza everyone stands in.
--
-- Z-up: x,y are the ground plane. Ground tiles sit one below GROUND_Z so their
-- top face is the floor avatars stand on.

GROUND_Z = 0
WORLD_R = 18
POND_X = 7
POND_Y = -6
POND_R = 3.2

function world_tile_at(x, y)
	local d = sqrt(x * x + y * y)
	local px = x - POND_X
	local py = y - POND_Y
	if sqrt(px * px + py * py) < POND_R then
		return "water"
	end
	if d > WORLD_R - 1.5 then
		return "stone"
	end
	if x == 0 or y == 0 or (d > 4.5 and d < 6) then
		return "path"
	end
	return "grass"
end

-- Walkable means inside the plaza and not in the pond.
function world_walkable(x, y)
	local px = x - POND_X
	local py = y - POND_Y
	if sqrt(px * px + py * py) < POND_R - 0.3 then
		return false
	end
	return sqrt(x * x + y * y) < WORLD_R - 1.5
end

-- Pull a point back onto walkable ground along the line from the origin.
-- Returns {x, y}.
function world_clamp(x, y)
	local d = sqrt(x * x + y * y)
	local lim = WORLD_R - 1.6
	if d > lim then
		x = x / d * lim
		y = y / d * lim
	end
	local p = { x, y }
	return p
end

function world_build()
	local r = WORLD_R
	for x = -r, r do
		for y = -r, r do
			if x * x + y * y <= r * r then
				-- hoisted: a call argument followed by locals miscompiles in silt
				local kind = world_tile_at(x, y)
				tile(kind, x, y, GROUND_Z - 1, 0)
			end
		end
	end
	world_sky()
end

function world_sky()
	-- vertical gradient, dusk blue to pale at the horizon
	local h = sky.h
	local steps = 24
	for i = 0, steps - 1 do
		local t = i / (steps - 1)
		local r = flr(U.lerp(70, 196, t))
		local g = flr(U.lerp(110, 216, t))
		local b = flr(U.lerp(170, 232, t))
		local col = { r, g, b }
		local y0 = flr(i * h / steps)
		local y1 = flr((i + 1) * h / steps) + 1
		sky:rect(0, y0, sky.w, y1 - y0, col)
	end
end
