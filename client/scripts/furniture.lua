-- furniture — what's been built, what's being built, and where the next
-- thing would go.
--
-- The universe (Sosh.Sim) owns all of it. A piece of furniture fills its
-- footprint with FURNITURE cells in the block world (solid, not drawn as
-- tiles) and is drawn here as its model. A blueprint being built fills its
-- footprint with SCAFFOLD cells, drawn as scaffolding, until the
-- ingredients put into it (`deposit_action`) meet its recipe; then it turns
-- into the furniture.
--
-- Footprints run from the origin cell along +x (width), +y (depth) and +z,
-- turned `rot` quarter turns counter-clockwise about the origin cell, as on
-- the server; models are drawn the same way, so rz = rot * 90 degrees.
--
-- Furniture and blueprints can stand on an airship (`on`, its id): their
-- cells are in its frame, and their entities follow it every frame.
--
-- Lifted furniture rides over whoever carries it: one carrier's head, or
-- the middle of two, lying along the line between them.
--
-- On the web only transforms sync after the frame an entity was made in, so
-- entities are moved and parked (z = -1000), never retextured.

Furn = {}

SITE_LABEL_DIST = 12
GHOST_MAX = 4

function Furn.init()
	if Furn.pieces ~= nil then
		for id, f in pairs(Furn.pieces) do
			f.ent:kill()
		end
	end
	if Furn.sites ~= nil then
		for id, s in pairs(Furn.sites) do
			Furn.kill_site(s)
		end
	end
	-- furniture by id: {id, kind, origin, rot, lifted, carriers, helpers, slots, ent}
	Furn.pieces = {}
	-- blueprints by id: {id, kind, origin, rot, have, need, ents}
	Furn.sites = {}
	-- cell key -> furniture id / site id
	Furn.cells = {}
	Furn.site_cells = {}
	-- helper id -> furniture id they hold
	Furn.helper_holds = {}
	if Furn.kinds == nil then
		Furn.kinds = {}
		Furn.order = {}
		Furn.items = {}
	end
	if Furn.ghosts == nil then
		Furn.ghosts = {}
	end
end

-- What there is (the join reply's `catalog`): furniture kinds, buildable
-- ones in order for the craft tool, and items.
function Furn.set_catalog(c)
	if c == nil then
		return
	end
	Furn.kinds = {}
	Furn.order = {}
	for i = 1, #c.kinds do
		local k = c.kinds[i]
		Furn.kinds[k.name] = k
		if #k.recipe > 0 then
			table.insert(Furn.order, k.name)
		end
	end
	Furn.items = {}
	for i = 1, #c.items do
		local it = c.items[i]
		Furn.items[it.name] = it
	end
end

function Furn.kind(name)
	return Furn.kinds[name]
end

-- The cells of something `size` ({w, d, h}) at `origin`, turned `rot`.
function Furn.cells_of(origin, size, rot)
	local out = {}
	local r = rot % 4
	for k = 0, size[3] - 1 do
		for j = 0, size[2] - 1 do
			for i = 0, size[1] - 1 do
				local dx = i
				local dy = j
				if r == 1 then
					dx = -j
					dy = i
				elseif r == 2 then
					dx = -i
					dy = -j
				elseif r == 3 then
					dx = j
					dy = -i
				end
				local c = { origin[1] + dx, origin[2] + dy, origin[3] + k }
				table.insert(out, c)
			end
		end
	end
	return out
end

function Furn.rz(rot)
	return (rot % 4) * math.pi / 2
end

-- A cell's key in the world (`on` nil), or on ship `on`.
function Furn.key(on, x, y, z)
	local k = Blocks.key(x, y, z)
	if on == nil then
		return k
	end
	return "s" .. tostring(on) .. ":" .. k
end

-- The furniture id in a cell of the world or of ship `on`, or nil.
function Furn.at(on, x, y, z)
	return Furn.cells[Furn.key(on, x, y, z)]
end

function Furn.site_at(on, x, y, z)
	return Furn.site_cells[Furn.key(on, x, y, z)]
end

-- A frame from the wire: 0 is the world (nil here).
function Furn.frame(on)
	if on == nil or on == 0 then
		return nil
	end
	return on
end

-- Put entity `e` at cell `c` of frame `on`, turned `rot` quarter turns in
-- it; parked out of sight if that ship isn't here.
function Furn.put(e, on, c, rot)
	local x, y, z, h = Ships.frame_pos(on, c[1], c[2], c[3])
	if x == nil then
		e.z = -1000
		return
	end
	e.x = x
	e.y = y
	e.z = z
	e.rz = Furn.rz(rot) + h
end

function Furn.unmap(f)
	if f.mapped == nil then
		return
	end
	for i = 1, #f.mapped do
		local k = f.mapped[i]
		if Furn.cells[k] == f.id then
			Furn.cells[k] = nil
		end
	end
	f.mapped = nil
end

-- A `furniture` event or snapshot entry.
function Furn.set(p)
	local f = Furn.pieces[p.id]
	if f ~= nil then
		Furn.unmap(f)
		if f.kind ~= p.kind then
			f.ent:kill()
			f.ent = nil
		end
	else
		f = {}
		f.id = p.id
	end
	f.kind = p.kind
	f.on = Furn.frame(p.on)
	f.origin = p.origin
	f.rot = p.rot
	f.lifted = p.lifted
	f.carriers = p.carriers or {}
	f.helpers = p.helpers or {}
	f.slots = p.slots or {}
	if f.ent == nil then
		local model = p.kind
		local ent = make(model, 0, 0, -1000, 1)
		f.ent = ent
	end
	Furn.pieces[p.id] = f

	-- which helpers have hold of it now
	for hid, fid in pairs(Furn.helper_holds) do
		if fid == f.id then
			Furn.helper_holds[hid] = nil
		end
	end
	for i = 1, #f.helpers do
		Furn.helper_holds[f.helpers[i]] = f.id
	end

	if not f.lifted then
		local k = Furn.kinds[f.kind]
		local size = { 1, 1, 1 }
		if k ~= nil then
			size = k.size
		end
		local cs = Furn.cells_of(f.origin, size, f.rot)
		f.mapped = {}
		for i = 1, #cs do
			local key = Furn.key(f.on, cs[i][1], cs[i][2], cs[i][3])
			Furn.cells[key] = f.id
			table.insert(f.mapped, key)
		end
		Furn.put(f.ent, f.on, f.origin, f.rot)
	end
end

function Furn.gone(id)
	local f = Furn.pieces[id]
	if f == nil then
		return
	end
	Furn.unmap(f)
	f.ent:kill()
	Furn.pieces[id] = nil
	for hid, fid in pairs(Furn.helper_holds) do
		if fid == id then
			Furn.helper_holds[hid] = nil
		end
	end
	if Bag.box == id then
		Bag.box = nil
	end
end

-- A blueprint: scaffolding in each cell.
function Furn.set_site(p)
	local old = Furn.sites[p.id]
	if old ~= nil then
		Furn.kill_site(old)
	end
	local s = {}
	s.id = p.id
	s.kind = p.kind
	s.on = Furn.frame(p.on)
	s.origin = p.origin
	s.rot = p.rot
	s.have = p.have or {}
	s.need = p.need or {}
	s.ents = {}
	s.mapped = {}
	local k = Furn.kinds[s.kind]
	local size = { 1, 1, 1 }
	if k ~= nil then
		size = k.size
	end
	local cs = Furn.cells_of(s.origin, size, s.rot)
	s.cs = cs
	for i = 1, #cs do
		local c = cs[i]
		local ent = make("scaffold", 0, 0, -1000, 1)
		Furn.put(ent, s.on, c, 0)
		table.insert(s.ents, ent)
		local key = Furn.key(s.on, c[1], c[2], c[3])
		Furn.site_cells[key] = s.id
		table.insert(s.mapped, key)
	end
	s.top = cs[#cs]
	Furn.sites[p.id] = s
end

function Furn.kill_site(s)
	for i = 1, #s.ents do
		s.ents[i]:kill()
	end
	for i = 1, #s.mapped do
		if Furn.site_cells[s.mapped[i]] == s.id then
			Furn.site_cells[s.mapped[i]] = nil
		end
	end
end

function Furn.site_gone(id)
	local s = Furn.sites[id]
	if s ~= nil then
		Furn.kill_site(s)
		Furn.sites[id] = nil
	end
end

-- Everything at once, from the join reply.
function Furn.sync(pieces, sites)
	Furn.init()
	for i = 1, #pieces do
		Furn.set(pieces[i])
	end
	for i = 1, #sites do
		Furn.set_site(sites[i])
	end
end

-- How many of `item` a site has, out of how many it needs.
function Furn.site_has(s, item)
	for i = 1, #s.have do
		if s.have[i][1] == item then
			return s.have[i][2]
		end
	end
	return 0
end

-- "wood 2/4 stone 0/1"
function Furn.site_progress(s)
	local out = ""
	for i = 1, #s.need do
		local n = s.need[i]
		local part = n[1] .. " " .. tostring(Furn.site_has(s, n[1])) .. "/" .. tostring(n[2])
		if out == "" then
			out = part
		else
			out = out .. "  " .. part
		end
	end
	return out
end

-- "wood 4, stone 1"
function Furn.recipe_text(name)
	local k = Furn.kinds[name]
	if k == nil then
		return ""
	end
	local out = ""
	for i = 1, #k.recipe do
		local part = k.recipe[i][1] .. " " .. tostring(k.recipe[i][2])
		if out == "" then
			out = part
		else
			out = out .. ", " .. part
		end
	end
	return out
end

-- Lifted pieces ride over their carriers, and whatever's on a ship goes
-- where it goes; call after the avatars pose.
function Furn.update()
	for id, f in pairs(Furn.pieces) do
		if f.lifted then
			Furn.carry(f)
		elseif f.on ~= nil then
			Furn.put(f.ent, f.on, f.origin, f.rot)
		end
	end
	for id, s in pairs(Furn.sites) do
		if s.on ~= nil then
			for i = 1, #s.ents do
				-- hoisted: indexed userdata can't be passed on directly (SILT-BUGS.md #11)
				local e = s.ents[i]
				Furn.put(e, s.on, s.cs[i], 0)
			end
		end
	end
end

function Furn.carry(f)
	local sx = 0
	local sy = 0
	local sz = 0
	local n = 0
	local first = nil
	local last = nil
	for i = 1, #f.carriers + #f.helpers do
		local av = nil
		if i <= #f.carriers then
			av = avatar_of(f.carriers[i])
		else
			av = Helpers.avatar(f.helpers[i - #f.carriers])
		end
		if av ~= nil and av.hold ~= nil then
			local h = av.hold
			sx = sx + h[1]
			sy = sy + h[2]
			sz = sz + h[3]
			n = n + 1
			if first == nil then
				first = h
			end
			last = h
		end
	end
	local e = f.ent
	if n == 0 then
		e.z = -1000
		return
	end
	local cx = sx / n
	local cy = sy / n
	local heading = first[4]
	if n >= 2 then
		heading = U.atan2(last[2] - first[2], last[1] - first[1])
	end
	-- the model's origin is its first cell, off its middle
	local k = Furn.kinds[f.kind]
	local ox = 0
	local oy = 0
	if k ~= nil then
		ox = -(k.size[1] - 1) / 2
		oy = -(k.size[2] - 1) / 2
	end
	local c = cos(heading)
	local s = sin(heading)
	e.x = cx + ox * c - oy * s
	e.y = cy + ox * s + oy * c
	e.z = sz / n
	e.rz = heading
end

-- How tall a piece is, for the name tag over whoever carries it.
function Furn.height(id)
	local f = Furn.pieces[id]
	if f == nil then
		return 0
	end
	local k = Furn.kinds[f.kind]
	if k == nil then
		return 1
	end
	return k.size[3]
end

-- The green outline of where something `size` big would go (cells of the
-- world, or of ship `on`), or nothing (cells nil).
function Furn.show_ghost(cells, on)
	local n = 0
	if cells ~= nil then
		n = #cells
	end
	if n > GHOST_MAX then
		n = GHOST_MAX
	end
	while #Furn.ghosts < n do
		local ent = make("ghost", 0, 0, -1000, 1)
		table.insert(Furn.ghosts, ent)
	end
	for i = 1, #Furn.ghosts do
		local g = Furn.ghosts[i]
		if i <= n then
			Furn.put(g, on, cells[i], 0)
		else
			g.z = -1000
		end
	end
end

-- Labels over blueprints nearby: what they still need. {p, text} each.
function Furn.site_labels(me)
	local out = {}
	if me == nil then
		return out
	end
	for id, s in pairs(Furn.sites) do
		local t = s.top
		local tx, ty, tz = Ships.frame_pos(s.on, t[1], t[2], t[3])
		if tx == nil then
			tx = 10000
			ty = 0
			tz = 0
		end
		local dx = tx - me.x
		local dy = ty - me.y
		if dx * dx + dy * dy < SITE_LABEL_DIST * SITE_LABEL_DIST then
			local p = UI.project(tx, ty, tz + 1.3)
			if p ~= nil then
				local l = {}
				l.p = p
				l.text = s.kind .. ": " .. Furn.site_progress(s)
				table.insert(out, l)
			end
		end
	end
	return out
end
