-- blocks — the client's copy of the universe's blocks (Sosh.Sim).
--
-- A universe is 96x96 blocks of floating islands (cells -48..47 on x and y,
-- -32..31 up), 6x6x4 chunks of 16x16x16 block ids. The server sends them run
-- length encoded, the whole universe a few dozen at a time; edits arrive as
-- `block_changed`. Here every solid block is a tile() and also kept in a
-- table for height and ray queries. A block with a model (the pot) is an
-- entity in its cell instead of a tile: on the web the tile world lives in
-- the Lua worker, which only knows texture names, so a model name there
-- draws as a cube with the model's texture. Furniture and blueprint cells
-- are solid but drawn by furniture.lua.
--
-- Tile convention: a block at integer (x, y, z) spans x-0.5..x+0.5,
-- y-0.5..y+0.5 and z..z+1, so standing on it puts your feet at z + 1.

Blocks = {}

CHUNK = 16
-- a name is its tile texture, or for a model block its model
BLOCK_NAMES = {
	"grass",
	"dirt",
	"stone",
	"wood",
	"path",
	"water",
	"pot",
	"furniture",
	"scaffold",
	"deck",
	"hull",
	"balloon",
	"rail",
	"helm",
}
WATER = 6
POT = 7
FURNITURE = 8
SCAFFOLD = 9
-- a universe's chunks: -3..2 on x and y, -2..1 up
CHUNKS_HALF = 3
CHUNKS_Z = { -2, -1, 0, 1 }
UNIVERSE_HALF = 48
REACH = 6.5 -- slightly under the server's 7

function Blocks.init()
	Blocks.solid = {}
	-- model blocks' entities, by key
	Blocks.models = {}
	Blocks.have = {}
	-- chunks applied at least once this session: a refresh of one must also
	-- clear blocks that became air meanwhile
	Blocks.seen = {}
	Blocks.wanted = {}
	Blocks.pending = false
end

function Blocks.key(x, y, z)
	return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

function Blocks.get(x, y, z)
	return Blocks.solid[Blocks.key(x, y, z)] or 0
end

-- Forget every block, for another universe: clear each tile we placed.
-- (Not dtile(): on the web it waits on a reply the worker never gets, and
-- hangs the VM.)
function Blocks.clear()
	if Blocks.models ~= nil then
		for k, ent in pairs(Blocks.models) do
			ent:kill()
		end
	end
	if Blocks.solid ~= nil then
		for k, id in pairs(Blocks.solid) do
			if Blocks.is_tile(id) then
				local xs, ys, zs = k:match("(-?%d+),(-?%d+),(-?%d+)")
				local x = tonumber(xs)
				local y = tonumber(ys)
				local z = tonumber(zs)
				tile(nil, x, y, z, 0)
			end
		end
	end
	Blocks.init()
end

-- Drawn as a model entity rather than a tile.
function Blocks.is_model(id)
	return id == POT
end

-- Solid, but drawn by something else (furniture, scaffolding).
function Blocks.is_hidden(id)
	return id == FURNITURE or id == SCAFFOLD
end

-- Drawn as a tile.
function Blocks.is_tile(id)
	return id ~= 0 and not Blocks.is_model(id) and not Blocks.is_hidden(id)
end

function Blocks.set(x, y, z, id)
	local k = Blocks.key(x, y, z)
	local was = Blocks.solid[k] or 0
	local ent = Blocks.models[k]
	if ent ~= nil and was ~= id then
		ent:kill()
		Blocks.models[k] = nil
		ent = nil
	end
	-- only clear a tile that's there: clearing one in an empty chunk makes
	-- the engine build that chunk for nothing
	local tiled = Blocks.is_tile(was)
	if id == 0 then
		Blocks.solid[k] = nil
		if tiled then
			tile(nil, x, y, z, 0)
		end
		return
	end
	Blocks.solid[k] = id
	local name = BLOCK_NAMES[id] or "stone"
	if Blocks.is_hidden(id) then
		if tiled then
			tile(nil, x, y, z, 0)
		end
	elseif Blocks.is_model(id) then
		if tiled then
			tile(nil, x, y, z, 0)
		end
		if ent == nil then
			ent = make(name, x, y, z, 1)
			Blocks.models[k] = ent
		end
	else
		tile(name, x, y, z, 0)
	end
end

-- A run-length encoded chunk from the server: {id, count, id, count, ...},
-- x fastest then y then z.
function Blocks.apply_chunk(key, rle)
	local bx = key[1] * CHUNK
	local by = key[2] * CHUNK
	local bz = key[3] * CHUNK
	local ck = Blocks.key(key[1], key[2], key[3])
	local refresh = Blocks.seen[ck] == true
	local i = 0
	local r = 1
	while r < #rle do
		local id = rle[r]
		local count = rle[r + 1]
		if id ~= 0 or refresh then
			for n = 0, count - 1 do
				local j = i + n
				local lx = j % CHUNK
				local ly = flr(j / CHUNK) % CHUNK
				local lz = flr(j / (CHUNK * CHUNK))
				local wx = bx + lx
				local wy = by + ly
				local wz = bz + lz
				if id ~= 0 then
					Blocks.set(wx, wy, wz, id)
				elseif Blocks.get(wx, wy, wz) ~= 0 then
					Blocks.set(wx, wy, wz, 0)
				end
			end
		end
		i = i + count
		r = r + 2
	end
	Blocks.have[ck] = true
	Blocks.seen[ck] = true
end

-- The universe's chunks we don't have yet, nearest (x, y) first; the
-- server answers a few dozen a request.
function Blocks.missing_around(x, y)
	local cx = flr((x + 0.5) / CHUNK)
	local cy = flr((y + 0.5) / CHUNK)
	local keys = {}
	for ring = 0, CHUNKS_HALF * 2 do
		for dx = -ring, ring do
			for dy = -ring, ring do
				local edge = dx == -ring or dx == ring or dy == -ring or dy == ring
				local kx = cx + dx
				local ky = cy + dy
				local inside = kx >= -CHUNKS_HALF and kx < CHUNKS_HALF and ky >= -CHUNKS_HALF and ky < CHUNKS_HALF
				if edge and inside then
					for zi = 1, #CHUNKS_Z do
						local kz = CHUNKS_Z[zi]
						local k = Blocks.key(kx, ky, kz)
						if not Blocks.have[k] and not Blocks.wanted[k] then
							local entry = { kx, ky, kz }
							table.insert(keys, entry)
						end
					end
				end
			end
		end
	end
	return keys
end

function Blocks.mark_wanted(keys)
	for i = 1, #keys do
		local k = keys[i]
		Blocks.wanted[Blocks.key(k[1], k[2], k[3])] = true
	end
end

-- Block column index for a world coordinate.
function Blocks.cell(v)
	return flr(v + 0.5)
end

-- Where feet rest at (x, y) for someone currently at height z: the top of the
-- highest solid block that is no more than one block above their feet (so a
-- single block is a step, two is a wall). nil if there's nothing below.
function Blocks.ground(x, y, z)
	local cx = Blocks.cell(x)
	local cy = Blocks.cell(y)
	local bz = flr(z + 0.01)
	local stop = bz - 24
	while bz >= stop do
		local id = Blocks.get(cx, cy, bz)
		if id == WATER then
			return nil
		end
		if id ~= 0 then
			return bz + 1
		end
		bz = bz - 1
	end
	return nil
end

-- Can someone at height z walk into column (x, y)?
function Blocks.walkable(x, y, z)
	local g = Blocks.ground(x, y, z)
	if g == nil then
		return false
	end
	-- headroom: the two cells the body occupies must be clear
	local cx = Blocks.cell(x)
	local cy = Blocks.cell(y)
	return Blocks.get(cx, cy, g) == 0 and Blocks.get(cx, cy, g + 1) == 0
end

-- The first solid block along a ray: in the world, or on a ship (`on` its
-- id), whichever is nearer.
function Blocks.raycast(ox, oy, oz, dx, dy, dz, max_dist)
	local hit = Blocks.raycast_in(nil, ox, oy, oz, dx, dy, dz, max_dist)
	local d = max_dist
	if hit ~= nil then
		d = hit.dist
	end
	local aboard = Ships.raycast(ox, oy, oz, dx, dy, dz, d)
	if aboard ~= nil then
		return aboard
	end
	return hit
end

-- The block at (x, y, z) of `ship`'s frame, or of the world's for nil.
function Blocks.get_in(ship, x, y, z)
	if ship == nil then
		return Blocks.get(x, y, z)
	end
	return Ships.block_at(ship, x, y, z)
end

-- Step through the grid along a ray (Amanatides-Woo): the world's, or
-- `ship`'s, in its frame (origin and direction already in it). Returns
-- {hit = {x, y, z}, before = {x, y, z}, dist, id} for the first solid block
-- within max_dist, where `before` is the empty cell the ray was in just
-- before it (the place a new block would go), or nil.
function Blocks.raycast_in(ship, ox, oy, oz, dx, dy, dz, max_dist)
	-- shift into a grid where every cell is [i, i+1) on all axes
	local px = ox + 0.5
	local py = oy + 0.5
	local pz = oz
	local ix = flr(px)
	local iy = flr(py)
	local iz = flr(pz)
	local sx = 1
	local sy = 1
	local sz = 1
	if dx < 0 then
		sx = -1
	end
	if dy < 0 then
		sy = -1
	end
	if dz < 0 then
		sz = -1
	end
	local big = 1000000000 -- silt has no exponent literals
	local tdx = big
	local tdy = big
	local tdz = big
	if dx ~= 0 then
		tdx = math.abs(1 / dx)
	end
	if dy ~= 0 then
		tdy = math.abs(1 / dy)
	end
	if dz ~= 0 then
		tdz = math.abs(1 / dz)
	end
	local tmx = big
	local tmy = big
	local tmz = big
	if dx > 0 then
		tmx = (ix + 1 - px) * tdx
	elseif dx < 0 then
		tmx = (px - ix) * tdx
	end
	if dy > 0 then
		tmy = (iy + 1 - py) * tdy
	elseif dy < 0 then
		tmy = (py - iy) * tdy
	end
	if dz > 0 then
		tmz = (iz + 1 - pz) * tdz
	elseif dz < 0 then
		tmz = (pz - iz) * tdz
	end

	local px0 = ix
	local py0 = iy
	local pz0 = iz
	local t = 0
	while t <= max_dist do
		local id = Blocks.get_in(ship, ix, iy, iz)
		if id ~= 0 then
			local hit = { ix, iy, iz }
			local before = { px0, py0, pz0 }
			local res = {}
			res.hit = hit
			res.before = before
			res.dist = t
			res.id = id
			return res
		end
		px0 = ix
		py0 = iy
		pz0 = iz
		if tmx < tmy and tmx < tmz then
			ix = ix + sx
			t = tmx
			tmx = tmx + tdx
		elseif tmy < tmz then
			iy = iy + sy
			t = tmy
			tmy = tmy + tdy
		else
			iz = iz + sz
			t = tmz
			tmz = tmz + tdz
		end
	end
	return nil
end
