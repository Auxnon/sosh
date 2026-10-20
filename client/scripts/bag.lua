-- bag — what we carry about (the server's Sosh.Players bag), and the
-- insides of whatever chest, drawer, dresser or wardrobe we have open.
--
-- The bag goes by our name and follows us from universe to universe; every
-- reply that changed it carries the new one (`bag`). Building spends from
-- it and digging fills it. A slot is {item, count}, or {} when empty.
--
-- The panel (I, or the bag button) shows its slots. With a piece of
-- furniture open (click it with the walk tool) its slots show above: click a
-- bag slot to put that stack in, a furniture slot to take it out. Without
-- one open, clicking a slot picks that item to build with.

Bag = {}

SLOT_W = 26
SLOT_H = 22
BAG_COLS = 8

-- A colour for each item's swatch.
ITEM_COLORS = {
	grass = "70A860",
	dirt = "86603E",
	stone = "787C88",
	wood = "A87848",
	path = "C4B28C",
	pot = "C4683E",
	carrot = "EE842A",
	drawer = "965A3C",
	stool = "C4966A",
}

function Bag.init()
	Bag.slots = {}
	Bag.open = false
	-- the furniture id whose insides are showing, or nil
	Bag.box = nil
	Bag.tip = nil
end

function Bag.set(slots)
	if slots ~= nil then
		Bag.slots = slots
	end
end

function Bag.count(item)
	local n = 0
	for i = 1, #Bag.slots do
		local s = Bag.slots[i]
		if s[1] == item then
			n = n + s[2]
		end
	end
	return n
end

-- Items in the bag that can be placed (blocks, furniture that packs away),
-- each once, in bag order.
function Bag.placeable()
	local out = {}
	local seen = {}
	for i = 1, #Bag.slots do
		local s = Bag.slots[i]
		if s[1] ~= nil and not seen[s[1]] then
			local info = Furn.items[s[1]]
			if info ~= nil and (info.block ~= nil or info.furniture ~= nil) then
				seen[s[1]] = true
				table.insert(out, s[1])
			end
		end
	end
	return out
end

-- Open furniture `id`'s insides beside the bag.
function Bag.open_box(id)
	Bag.box = id
	Bag.open = true
end

function Bag.close()
	Bag.open = false
	Bag.box = nil
end

-- Where the panels go: {x, y, w, h} for the bag and, if open, the box.
function Bag.layout(bottom)
	local L = {}
	local cols = BAG_COLS
	local rows = flr((#Bag.slots + cols - 1) / cols)
	if rows < 1 then
		rows = 1
	end
	L.w = cols * SLOT_W + PAD * 2
	L.x = flr((gui.w - L.w) / 2)
	L.bag_h = rows * SLOT_H + LH + PAD * 3
	L.bag_y = bottom - L.bag_h
	L.box = nil
	local f = nil
	if Bag.box ~= nil then
		f = Furn.pieces[Bag.box]
	end
	if f ~= nil then
		local n = #f.slots
		local brows = flr((n + cols - 1) / cols)
		if brows < 1 then
			brows = 1
		end
		L.box = f
		L.box_h = brows * SLOT_H + LH + PAD * 3
		L.box_y = L.bag_y - L.box_h - PAD
	end
	return L
end

function Bag.hit(x, y, bottom)
	if not Bag.open then
		return false
	end
	local L = Bag.layout(bottom)
	if x < L.x or x >= L.x + L.w then
		return false
	end
	if y >= L.bag_y and y < L.bag_y + L.bag_h then
		return true
	end
	return L.box ~= nil and y >= L.box_y and y < L.box_y + L.box_h
end

-- One grid of slots; returns the index clicked, or nil.
function Bag.grid(title, slots, x, y, w, h)
	UI.panel(x, y, w, h)
	UI.text(title, x + PAD, y + PAD, C_ACCENT)
	local clicked = nil
	local gy = y + LH + PAD * 2
	for i = 1, #slots do
		local col = (i - 1) % BAG_COLS
		local row = flr((i - 1) / BAG_COLS)
		local sx = x + PAD + col * SLOT_W
		local sy = gy + row * SLOT_H
		local over = UI.inside(sx, sy, SLOT_W - 2, SLOT_H - 2)
		local bg = "0A0E1680"
		if over then
			bg = C_PANEL_HI
			UI.hot = true
		end
		gui:rrect(sx, sy, SLOT_W - 2, SLOT_H - 2, 2, bg)
		local s = slots[i]
		if s[1] ~= nil then
			local c = ITEM_COLORS[s[1]] or "DDDDDD"
			gui:rrect(sx + 3, sy + 3, 8, 8, 1, c)
			local n = tostring(s[2])
			-- calls hoisted out of argument lists (petrichor64 SILT-BUGS.md #1)
			local nw = UI.text_w(n)
			UI.text(n, sx + SLOT_W - 3 - nw, sy + SLOT_H - LH - 1, C_TEXT)
			if over then
				Bag.tip = s[1] .. " x" .. n
			end
		end
		if over and UI.clicked then
			clicked = i
		end
	end
	return clicked
end

-- Draw the panels and act on clicks; `bottom` is the y they sit above.
function Bag.draw(bottom)
	Bag.tip = nil
	if not Bag.open then
		return
	end
	if Bag.box ~= nil and Furn.pieces[Bag.box] == nil then
		Bag.box = nil -- broken or carried off
	end
	local L = Bag.layout(bottom)
	local clicked = Bag.grid("bag", Bag.slots, L.x, L.bag_y, L.w, L.bag_h)
	if clicked ~= nil then
		local s = Bag.slots[clicked]
		if L.box ~= nil then
			if s[1] ~= nil then
				box_action("stash_action", L.box.id, clicked - 1)
			end
		elseif s[1] ~= nil then
			pick_build_item(s[1])
		end
	end
	if L.box ~= nil then
		local title = L.box.kind
		if L.box.kind == "sack" then
			title = "sack (what didn't fit)"
		end
		local got = Bag.grid(title, L.box.slots, L.x, L.box_y, L.w, L.box_h)
		if got ~= nil and L.box.slots[got][1] ~= nil then
			box_action("take_action", L.box.id, got - 1)
		end
	end
	if Bag.tip ~= nil then
		local tw = UI.text_w(Bag.tip)
		UI.text(Bag.tip, L.x + L.w - tw - PAD, L.bag_y + PAD, C_TEXT)
	end
end
