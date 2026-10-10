-- world — sky and spawn. The ground itself is server data (blocks.lua).

-- Spawn height: the plaza floor's top, before any chunk has arrived.
GROUND_Z = 0

function world_build()
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
