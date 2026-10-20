-- world — sky, spawn, and what lies far below the islands. The islands
-- themselves are server data (blocks.lua).

-- Spawn height: the plaza floor's top, before any chunk has arrived.
GROUND_Z = 0
-- the sea, or the wild land, far under every island
BELOW_Z = -44

function world_build()
	world_sky()
	world_ground()
end

-- Grass and dirt mesh together as smooth ground: marching cubes over the
-- tiles, so steps and edges turn into 45° slopes. Only the look changes;
-- heights, rays and the server still see whole blocks. (Needs an engine with
-- tileset(), from petrichor64's feat/tilesets.)
function world_ground()
	if tileset ~= nil then
		tileset("ground", { "grass", "dirt" }, { look = "smooth" })
	end
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

-- What lies far below this universe's islands: "sea" or "land" (the join
-- reply's `kind`).
function world_below(kind)
	if BELOW ~= nil then
		BELOW:kill()
		BELOW = nil
	end
	local model = "sea"
	if kind == "land" then
		model = "land"
	end
	BELOW = make(model, 0, 0, BELOW_Z, 1)
end
