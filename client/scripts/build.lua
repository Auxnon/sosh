-- build — the build tool's lines.
--
-- Pressing on the world with the build tool (a block in hand, in the world,
-- not on a ship) anchors a line at the cell it would place in; dragging
-- pulls the line's other end after the pointer, and letting go places a
-- block in each of its cells. A line only goes the ways a rook or a bishop
-- does: straight along x, y or up, or diagonally in a plane of two of them
-- (a stair, if one of them is up), never a half step or any other angle.
-- The end is wherever on those lines the pointer's ray passes closest, so a
-- line can be drawn up into the air. It stops short at REACH and at what
-- the bag holds.
--
-- While it's drawn, a straight line shows as one scaffold frame around the
-- whole of it (12 poles, nothing between its cells: a mesh made for its
-- length, `mod`); a diagonal shows a scaffold cell per block. A tap (no
-- drag) places one block as ever (tools.lua).

Build = {}
Build.line = nil
Build.frames = {} -- meshes made, by name
Build.stair = {} -- scaffold cells shown for a diagonal
BUILD_LINE_MAX = 16 -- blocks in one line
BUILD_POLE = 1 / 16 -- the scaffold's poles, as thick as scaffold.glb's
BUILD_BISHOP = 1.1 -- a diagonal has to fit this much better to win over a straight line
BUILD_KEEP = 1.2 -- and the way the line goes now this much worse to lose
-- the ways a line can go: a rook's (1 to 3), then a bishop's
BUILD_DIRS = {
	{ 1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, 0, 1 },
	{ 1, 1, 0 },
	{ 1, -1, 0 },
	{ 1, 0, 1 },
	{ 1, 0, -1 },
	{ 0, 1, 1 },
	{ 0, 1, -1 },
}

-- Is what's in hand a block (not furniture, which goes down one at a time)?
function Build.block_in_hand()
	local item = APP.build_item
	if item == nil or Bag.count(item) == 0 then
		return false
	end
	local info = Furn.item(item)
	return info == nil or info.furniture == nil
end

-- Each frame with the build tool, after the cursor's been shown: start a
-- line on a press, follow the pointer while it's held, and place the line
-- when a drag lets go. True while a line is being drawn (the drag is ours,
-- not the camera's).
function Build.pointer(me, hit, over_hud)
	local m = UI.mouse
	if UI.clicked then
		Build.cancel()
		if not over_hud and hit ~= nil and hit.on == nil and hit.before ~= nil and Build.block_in_hand() then
			Build.begin(hit.before)
		end
	end
	local L = Build.line
	if L == nil then
		return false
	end
	if m.m1 then
		if UI.dragging then
			Build.follow(me, m)
		end
		Build.show()
		show_cursor(nil)
		return UI.dragging
	end
	-- let go: a drag places the line; a tap is tools.lua's, one block
	if UI.dragging then
		Build.place(L)
	end
	Build.cancel()
	return false
end

function Build.begin(cell)
	local L = {}
	local sx = cell[1]
	local sy = cell[2]
	local sz = cell[3]
	local start = { sx, sy, sz }
	L.start = start
	local cells = {}
	table.insert(cells, start)
	L.cells = cells
	L.dir = 0 -- which of BUILD_DIRS, 0 for none yet
	L.k = 0 -- how many steps along it (either way)
	Build.line = L
end

function Build.cancel()
	Build.line = nil
	Build.hide()
end

-- The pointer's ray against each way the line could go from its start: the
-- whole number of steps along it nearest the ray, and how far off the ray
-- that point is (as an angle, near enough: over its distance down the
-- ray). The best fit wins; a diagonal needs to be clearly better, and the
-- way it goes now clearly worse, so it doesn't flicker between them.
function Build.follow(me, m)
	local L = Build.line
	local s = L.start
	local cx = s[1]
	local cy = s[2]
	local cz = s[3] + 0.5
	local best = 0
	local best_k = 0
	local best_err = 0
	local keep_err = nil
	local keep_k = 0
	for i = 1, #BUILD_DIRS do
		local d = BUILD_DIRS[i]
		local k, err = Build.fit(cx, cy, cz, d, m)
		if k ~= nil then
			if i > 3 then
				err = err * BUILD_BISHOP
			end
			if best == 0 or err < best_err then
				best = i
				best_k = k
				best_err = err
			end
			if i == L.dir then
				keep_err = err
				keep_k = k
			end
		end
	end
	if keep_err ~= nil and keep_err <= best_err * BUILD_KEEP then
		best = L.dir
		best_k = keep_k
	end
	if best == 0 then
		return
	end
	L.dir = best
	L.k = best_k
	L.cells = Build.cells_of(me, s, BUILD_DIRS[best], best_k)
end

-- Along d from (cx, cy, cz): the steps k nearest the pointer's ray, and how
-- far off the ray that cell's middle is over how far down it; nil if the
-- ray runs along d.
function Build.fit(cx, cy, cz, d, m)
	local vx = m.vx
	local vy = m.vy
	local vz = m.vz
	local dx = d[1]
	local dy = d[2]
	local dz = d[3]
	local wx = CAM.x - cx
	local wy = CAM.y - cy
	local wz = CAM.z - cz
	local a = vx * vx + vy * vy + vz * vz
	local b = vx * dx + vy * dy + vz * dz
	local c = dx * dx + dy * dy + dz * dz
	local dd = vx * wx + vy * wy + vz * wz
	local e = dx * wx + dy * wy + dz * wz
	local den = a * c - b * b
	if den < 0.000001 * a * c then
		return nil
	end
	local t = (a * e - b * dd) / den
	local k = flr(t + 0.5)
	if k > BUILD_LINE_MAX - 1 then
		k = BUILD_LINE_MAX - 1
	elseif k < 1 - BUILD_LINE_MAX then
		k = 1 - BUILD_LINE_MAX
	end
	-- that cell's middle against the ray
	local px = cx + dx * k - CAM.x
	local py = cy + dy * k - CAM.y
	local pz = cz + dz * k - CAM.z
	local along = (px * vx + py * vy + pz * vz) / a
	if along < 0.000001 then
		return k, 1000
	end
	local ox = px - vx * along
	local oy = py - vy * along
	local oz = pz - vz * along
	local off = sqrt(ox * ox + oy * oy + oz * oz)
	local far = along * sqrt(a)
	return k, off / far
end

-- The line's cells from `s`, k steps along d: from the start out, as far as
-- we reach and the bag holds.
function Build.cells_of(me, s, d, k)
	local n = math.abs(k)
	local step = 1
	if k < 0 then
		step = -1
	end
	local have = Bag.count(APP.build_item)
	local out = {}
	for i = 0, n do
		if #out >= have then
			break
		end
		local x = s[1] + d[1] * i * step
		local y = s[2] + d[2] * i * step
		local z = s[3] + d[3] * i * step
		local c = { x, y, z }
		if not in_reach(me, c, nil) then
			break
		end
		table.insert(out, c)
	end
	if #out == 0 then
		table.insert(out, s)
	end
	return out
end

-- -- what's shown while drawing

function Build.show()
	local L = Build.line
	local cells = L.cells
	if L.dir == 0 or L.dir <= 3 or #cells == 1 then
		Build.show_stair(nil)
		Build.show_frame(cells)
	else
		Build.show_frame(nil)
		Build.show_stair(cells)
	end
end

function Build.hide()
	Build.show_frame(nil)
	Build.show_stair(nil)
end

-- One scaffold frame around a straight line of cells (or a single one): a
-- box of 12 poles, its mesh made once for each length and way.
function Build.show_frame(cells)
	if cells == nil then
		if Build.frame ~= nil then
			Build.frame.z = -1000
		end
		return
	end
	local minx = cells[1][1]
	local miny = cells[1][2]
	local minz = cells[1][3]
	local maxx = minx
	local maxy = miny
	local maxz = minz
	for i = 2, #cells do
		local c = cells[i]
		minx = math.min(minx, c[1])
		miny = math.min(miny, c[2])
		minz = math.min(minz, c[3])
		maxx = math.max(maxx, c[1])
		maxy = math.max(maxy, c[2])
		maxz = math.max(maxz, c[3])
	end
	local lx = maxx - minx + 1
	local ly = maxy - miny + 1
	local lz = maxz - minz + 1
	local name = Build.frame_mesh(lx, ly, lz)
	if Build.frame == nil then
		Build.frame = make(name, 0, 0, -1000, 1)
		Build.frame_name = name
	end
	local e = Build.frame
	if Build.frame_name ~= name then
		e.asset = name
		Build.frame_name = name
	end
	-- the mesh starts at the frame's corner: a block spans its cell's x and
	-- y +-0.5, and outlines sit where blocks are drawn, a hair up (OUTLINE_DZ)
	e.x = minx - 0.5
	e.y = miny - 0.5
	e.z = minz + OUTLINE_DZ
end

-- The mesh of a frame lx by ly by lz cells: poles along its 12 edges, set
-- in by half a pole as scaffold.glb's are.
function Build.frame_mesh(lx, ly, lz)
	local name = "build_frame_" .. tostring(lx) .. "_" .. tostring(ly) .. "_" .. tostring(lz)
	if Build.frames[name] then
		return name
	end
	local h = BUILD_POLE / 2
	local xs = { h, lx - h }
	local ys = { h, ly - h }
	local zs = { h, lz - h }
	local l = {}
	for i = 1, 2 do
		for j = 1, 2 do
			-- along x, y and z, at each pair of the other two's sides
			local a1 = { 0, ys[i], zs[j] }
			local a2 = { lx, ys[i], zs[j] }
			table.insert(l, a1)
			table.insert(l, a2)
			local b1 = { xs[i], 0, zs[j] }
			local b2 = { xs[i], ly, zs[j] }
			table.insert(l, b1)
			table.insert(l, b2)
			local c1 = { xs[i], ys[j], 0 }
			local c2 = { xs[i], ys[j], lz }
			table.insert(l, c1)
			table.insert(l, c2)
		end
	end
	local data = {}
	data.l = l
	data.lw = BUILD_POLE
	data.t = "scaffold"
	mod(name, data)
	Build.frames[name] = true
	return name
end

-- A scaffold cell for each block of a diagonal.
function Build.show_stair(cells)
	local n = 0
	if cells ~= nil then
		n = #cells
	end
	while #Build.stair < n do
		local ent = make("scaffold", 0, 0, -1000, 1)
		table.insert(Build.stair, ent)
	end
	for i = 1, #Build.stair do
		local g = Build.stair[i]
		if i <= n then
			local c = cells[i]
			g.x = c[1]
			g.y = c[2]
			g.z = c[3] + DRAW_DZ + 0.0001
		else
			g.z = -1000
		end
	end
end

-- -- placing

-- A block in each of the line's cells that's empty, in order from where it
-- started. What goes wrong is said once, not for every block.
function Build.place(L)
	local item = APP.build_item
	Build.sent = 0
	Build.failed = nil
	for i = 1, #L.cells do
		local c = L.cells[i]
		if Blocks.get(c[1], c[2], c[3]) == 0 then
			local payload = cell_payload(c, nil)
			payload.item = item
			payload.rot = APP.rot
			Build.sent = Build.sent + 1
			PHX:push(ACTIONS, "place_action", payload, Build.placed)
		end
	end
end

function Build.placed(status, response)
	Build.sent = Build.sent - 1
	if status == "ok" then
		if response ~= nil and response.bag ~= nil then
			Bag.set(response.bag)
		end
	elseif Build.failed == nil and response ~= nil and response.reason ~= nil then
		Build.failed = response.reason
		add_chat(nil, "can't place that: " .. say_reason(response.reason), C_BAD)
	end
	if Build.sent <= 0 and APP.build_item ~= nil and Bag.count(APP.build_item) == 0 then
		APP.build_item = Bag.placeable()[1]
	end
end
