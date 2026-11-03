-- marker — where the walk tool will go, and where it was told to.
--
-- `hover` (assets/hover.glb, a dashed ring) sits on the block under the
-- pointer when a click there would walk to it, breathing a little and slowly
-- turning. A click drops `ping` (a ring and dot) on that spot: it pops in,
-- throws a ripple out (`ripple`, the same ring, swelling away), and stays,
-- pulsing, until we get there, give up, or are sent somewhere else; then it
-- shrinks away. Both are in the frame of what they're on, so a spot on a
-- ship's deck rides with it.
--
-- Only transforms sync on the web, so the entities are made once and parked
-- far below (z -1000) when not shown.

Marker = {}

MARKER_PARK = -1000
MARKER_POP = 0.18 -- seconds: the ping popping in
MARKER_RIPPLE = 0.4 -- the ripple swelling out
MARKER_GONE = 0.22 -- the ping shrinking away

function Marker.init()
	Marker.hover_ent = nil
	Marker.ping_ent = nil
	Marker.ripple_ent = nil
	Marker.spot = nil -- {x, y, z, on}: the hovered block
	Marker.ping = nil -- {x, y, z, on, t, gone}: where we were sent
	Marker.hide_hover = false
	Marker.t = 0
end

function Marker.ents()
	if Marker.hover_ent == nil then
		Marker.hover_ent = make("hover", 0, 0, MARKER_PARK, 1)
		Marker.ping_ent = make("ping", 0, 0, MARKER_PARK, 1)
		Marker.ripple_ent = make("ping", 0, 0, MARKER_PARK, 1)
	end
end

-- The block a click would walk onto (of the world, or ship `on`'s), or nil.
function Marker.hover(cell, on)
	if cell == nil then
		Marker.spot = nil
		return
	end
	local s = {}
	s.x = cell[1]
	s.y = cell[2]
	s.z = cell[3]
	s.on = on
	Marker.spot = s
end

-- Told to walk onto that block.
function Marker.sent(cell, on)
	local p = {}
	p.x = cell[1]
	p.y = cell[2]
	p.z = cell[3]
	p.on = on
	p.t = 0
	p.gone = nil
	Marker.ping = p
	-- a tap needn't leave the hover ring behind (a finger doesn't hover):
	-- it's back once the pointer moves
	Marker.hide_hover = true
end

MARKER_LIFT = 0.51 -- over the block's cell: on its top (blocks draw centred on the cell), just clear of it

-- Put entity `e` on top of block (x, y, z) of `on`'s frame at `scale`,
-- turned by `turn`; parked if that frame's gone.
function Marker.place(e, x, y, z, on, scale, turn)
	local wx, wy, wz, rz = Ships.frame_pos(on, x, y, z + MARKER_LIFT)
	if wx == nil or scale <= 0 then
		e.z = MARKER_PARK
		return
	end
	e.x = wx
	e.y = wy
	e.z = wz
	e.rz = rz + turn
	e.scale = scale
end

-- Once a frame, after `me` has moved.
function Marker.update(dt, me)
	Marker.ents()
	Marker.t = Marker.t + dt
	local t = Marker.t
	if UI.move_x ~= 0 or UI.move_y ~= 0 then
		Marker.hide_hover = false
	end

	-- the ping: done once we're there (tx cleared) or walking elsewhere
	local p = Marker.ping
	if p ~= nil and p.gone == nil then
		local going = me ~= nil and me.tx == p.x and me.ty == p.y
		if not going and p.t > MARKER_POP then
			p.gone = 0
		end
	end
	local pe = Marker.ping_ent
	local re = Marker.ripple_ent
	if p == nil then
		pe.z = MARKER_PARK
		re.z = MARKER_PARK
	else
		p.t = p.t + dt
		local k = 1
		if p.t < MARKER_POP then
			-- pops: overshoots a little (ease out, back), then settles
			local b = p.t / MARKER_POP - 1
			k = 1 + 2.7 * b * b * b + 1.7 * b * b
		else
			k = 1 - sin((p.t - MARKER_POP) * 6) * 0.08
		end
		if p.gone ~= nil then
			p.gone = p.gone + dt
			local a = p.gone / MARKER_GONE
			if a >= 1 then
				Marker.ping = nil
				k = 0
			else
				k = k * (1 - a) * (1 + a * 0.3)
			end
		end
		Marker.place(pe, p.x, p.y, p.z, p.on, k, 0)
		if p.t < MARKER_RIPPLE then
			local a = p.t / MARKER_RIPPLE
			-- swells out, thinning to nothing at the end
			local rk = (0.6 + a * 1.4) * (1 - a * a)
			Marker.place(re, p.x, p.y, p.z, p.on, rk, 0)
		else
			re.z = MARKER_PARK
		end
	end

	-- the hover ring, unless it's where we're already going
	local s = Marker.spot
	local he = Marker.hover_ent
	local same = s ~= nil and p ~= nil and p.gone == nil and s.x == p.x and s.y == p.y and s.on == p.on
	if s == nil or same or Marker.hide_hover or (UI.dragging and UI.mouse.m1) then
		he.z = MARKER_PARK
	else
		local k = 0.92 + sin(t * 4) * 0.05
		Marker.place(he, s.x, s.y, s.z, s.on, k, t * 0.8)
	end
end
