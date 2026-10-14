-- util — small helpers silt's stdlib doesn't have.
--
-- silt quirks this codebase works around (see petrichor64/SILT-BUGS.md):
--  * a table constructor containing a local, assigned to a field or index
--    inside a loop, miscompiles: build it into a `local` first, then assign.
--    A function/method call inside a constructor miscompiles too: hoist it.
--  * script load order isn't guaranteed: top level only defines things;
--    nothing runs until main().
--  * no os/clock on the web build (clock() panics there): the engine's now()
--    is the clock (U.tick), and older engines without it count frames, at
--    roughly FPS frames a second. Movement uses it; timers still count frames.

U = {}

FPS = 60

function U.clamp(v, lo, hi)
	if v < lo then
		return lo
	end
	if v > hi then
		return hi
	end
	return v
end

-- Advance the clock once a frame: U.dt is the seconds since the last frame,
-- capped so a stall (a hidden tab, a hitch) doesn't teleport anyone.
function U.tick()
	local t = 0
	if now ~= nil then
		t = now()
	else
		U.frames = (U.frames or 0) + 1
		t = U.frames / FPS
	end
	if U.clock == nil then
		U.dt = 1 / FPS
	else
		U.dt = U.clamp(t - U.clock, 0, 0.1)
	end
	U.clock = t
end

-- How much of the way to close in one frame, approaching at `rate` a second.
function U.rate(rate, dt)
	return U.clamp(rate * dt, 0, 1)
end

-- To the nearest 1/per: keeps numbers short on the wire.
function U.round(v, per)
	return flr(v * per + 0.5) / per
end

function U.lerp(a, b, t)
	return a + (b - a) * t
end

-- atan on [-1, 1]; max error ~0.0015 rad, plenty for facing a direction.
function U.atan_unit(z)
	return z * (0.9998660 + z * z * (-0.3302995 + z * z * (0.1801410 + z * z * (-0.0851330 + z * z * 0.0208351))))
end

function U.atan2(y, x)
	if x == 0 and y == 0 then
		return 0
	end
	local ax = math.abs(x)
	local ay = math.abs(y)
	local a = 0
	if ax >= ay then
		a = U.atan_unit(y / x)
		if x < 0 then
			if y >= 0 then
				a = a + math.pi
			else
				a = a - math.pi
			end
		end
	else
		a = -U.atan_unit(x / y)
		if y > 0 then
			a = a + math.pi / 2
		else
			a = a - math.pi / 2
		end
	end
	return a
end

-- Shortest signed difference between two angles, in (-pi, pi].
function U.angle_diff(from, to)
	local d = to - from
	while d > math.pi do
		d = d - math.pi * 2
	end
	while d < -math.pi do
		d = d + math.pi * 2
	end
	return d
end

function U.trim(s)
	local a = 1
	local b = #s
	while a <= b and s:sub(a, a) == " " do
		a = a + 1
	end
	while b >= a and s:sub(b, b) == " " do
		b = b - 1
	end
	return s:sub(a, b)
end

-- Word-wrap into lines of at most `width` characters. Words longer than a
-- line are hard-split.
function U.wrap(text, width)
	local lines = {}
	local line = ""
	local word = ""
	local i = 1
	local n = #text
	while i <= n + 1 do
		local c = " "
		if i <= n then
			c = text:sub(i, i)
		end
		if c == " " then
			while #word > width do
				if #line > 0 then
					table.insert(lines, line)
					line = ""
				end
				table.insert(lines, word:sub(1, width))
				word = word:sub(width + 1)
			end
			if #word > 0 then
				if #line == 0 then
					line = word
				elseif #line + 1 + #word <= width then
					line = line .. " " .. word
				else
					table.insert(lines, line)
					line = word
				end
			end
			word = ""
		else
			word = word .. c
		end
		i = i + 1
	end
	if #line > 0 then
		table.insert(lines, line)
	end
	return lines
end

-- Stable colour for an id: every client derives the same one, so it never
-- needs to go over the wire.
PALETTE = {
	{ 0.91, 0.42, 0.42 },
	{ 0.95, 0.66, 0.30 },
	{ 0.93, 0.85, 0.36 },
	{ 0.48, 0.80, 0.45 },
	{ 0.36, 0.76, 0.80 },
	{ 0.42, 0.56, 0.92 },
	{ 0.66, 0.48, 0.90 },
	{ 0.90, 0.50, 0.75 },
}

function U.color_index(id)
	local h = 7
	for i = 1, #id do
		h = (h * 31 + id:byte(i)) % 1000003
	end
	return (h % #PALETTE) + 1
end

-- Hex string ("rgb") for gui drawing.
HEX = "0123456789ABCDEF"

function U.hex_for(id)
	local c = PALETTE[U.color_index(id)]
	local out = ""
	for i = 1, 3 do
		local v = flr(c[i] * 15 + 0.5) + 1
		out = out .. HEX:sub(v, v)
	end
	return out
end
