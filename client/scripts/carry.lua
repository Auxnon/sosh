-- carry — who holds what, overhead.
--
-- The server's universe (Sosh.Sim) decides what can be carried: the block
-- ids it lists on join (`carryable`) and any cow. Each change arrives as
-- `carry` {user_id, block, cow}, both nil when they put it down; picking a
-- block up or putting it down also arrives as an ordinary `block_changed`.
--
-- The thing rides directly above its holder, where the raised arms point:
-- a block as its own small entity, a cow as the herd's entity, moved there.
--
-- silt's pairs() still yields a key after it's set to nil, with a nil
-- value, so the loops here skip those.

Carry = {}

CARRY_Z = 1.5 -- above the holder's feet, as the universe carries a cow
HELD_H = 0.85 -- how tall a held block is, for the name tag above it
HELD_COW_H = 1.1

function Carry.init()
	if Carry.by ~= nil then
		for id, h in pairs(Carry.by) do
			if h ~= nil then
				Carry.let_go(h)
			end
		end
	end
	-- user id -> {block, cow, ent}
	Carry.by = {}
	-- cow id -> user id
	Carry.cows = {}
	if Carry.blocks == nil then
		Carry.blocks = {}
	end
end

-- The block ids the universe lets players carry.
function Carry.set_carryable(list)
	Carry.blocks = {}
	for i = 1, #list do
		Carry.blocks[list[i]] = true
	end
end

function Carry.can_carry(id)
	return Carry.blocks[id] == true
end

-- Replace everything with the server's list of {user_id, block, cow}.
function Carry.sync(list)
	Carry.init()
	for i = 1, #list do
		Carry.set(list[i])
	end
end

-- One `carry` event.
function Carry.set(p)
	local old = Carry.by[p.user_id]
	if old ~= nil then
		Carry.let_go(old)
		Carry.by[p.user_id] = nil
	end
	if p.block == nil and p.cow == nil then
		return
	end
	local h = {}
	h.block = p.block
	h.cow = p.cow
	if p.block ~= nil then
		-- hoisted: see Farm.set (SILT-BUGS.md #7)
		local model = Carry.model(p.block)
		local ent = make(model, 0, 0, -1000, 1)
		h.ent = ent
	else
		Carry.cows[p.cow] = p.user_id
	end
	Carry.by[p.user_id] = h
end

-- The entity model for a held block: a model block's own model.
function Carry.model(block)
	return BLOCK_NAMES[block] or "pot"
end

function Carry.let_go(h)
	if h.ent ~= nil then
		h.ent:kill()
	end
	if h.cow ~= nil then
		Carry.cows[h.cow] = nil
	end
end

-- What a player holds, or nil.
function Carry.of(user_id)
	if user_id == nil then
		return nil
	end
	return Carry.by[user_id]
end

-- How tall the thing a player holds is, or 0.
function Carry.height(user_id)
	local h = Carry.of(user_id)
	if h == nil then
		return 0
	end
	if h.cow ~= nil then
		return HELD_COW_H
	end
	return HELD_H
end

-- Where a carried cow is ({x, y, z, heading}), or nil if it isn't carried
-- or its holder isn't here, so it should follow the server.
function Carry.cow_spot(cow_id)
	local holder = Carry.cows[cow_id]
	if holder == nil then
		return nil
	end
	local av = avatar_of(holder)
	if av == nil or av.hold == nil then
		return nil
	end
	return av.hold
end

-- Put each held block over its holder, after the avatars have posed.
function Carry.update()
	for id, h in pairs(Carry.by) do
		local e = nil
		if h ~= nil then
			e = h.ent
		end
		if e ~= nil then
			local av = avatar_of(id)
			if av ~= nil and av.hold ~= nil then
				local p = av.hold
				e.x = p[1]
				e.y = p[2]
				e.z = p[3]
				e.rz = p[4]
			else
				e.z = -1000
			end
		end
	end
end
