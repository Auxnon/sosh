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
--
-- Drag a slot onto another to sort (like stacks pour together, others
-- swap), between the bag and the box, or out over the world to drop the
-- whole stack there (in a sack; a bag of marbles as itself). Right-click
-- or hold a slot for its menu: collect (marbles into the wallet), hold,
-- put in, split, drop. With a finger (the Android app) a slot only tugs
-- until the hold lifts it, then drags (Bag.input).
--
-- Marbles are the money: in the bag they're bags of them (`marbles:<n>`,
-- set down in the world like furniture), in the wallet just a number
-- (Bag.wallet). The panel's last row shows the wallet: "collect" empties
-- every bag of marbles into it, "take out" takes 100, 1000 or however many
-- back out; /marbles does either.
--
-- In the Android app its pockets are the bag (they pick what's in hand,
-- passed on by `hold`), so the panel only shows beside an open box.

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
	sign = "E8D8A8",
	marbles = "5C8EE0",
	plank = "C4966A",
	post = "A87848",
	wool = "F4F0E6",
	yarn = "D696BE",
	cloth = "E4DAF0",
	veneer = "965A3C",
	bench = "A87848",
	spinning_wheel = "B07850",
	loom = "8A5A3C",
}

-- Item icons: 8 units square at (x, y) on image `im` (the gui, or a page
-- of the book), `u` pixels a unit. Most things are their swatch; what
-- crafting makes is drawn.
Icons = {}

function Icons.draw(im, item, x, y, u)
	local name = item:match("^(%a+):%d+$") or item
	local c = ITEM_COLORS[name] or "DDDDDD"
	if name == "plank" then
		im:rect(x, y + 2 * u, 8 * u, 4 * u, c)
		im:rect(x, y + 3 * u, 8 * u, u, "96643C")
		im:rect(x + 5 * u, y + 2 * u, u, u, "96643C")
	elseif name == "post" then
		im:rect(x + 3 * u, y, 2 * u, 8 * u, c)
		im:rect(x + 4 * u, y + u, u, 6 * u, "78542F")
	elseif name == "wool" then
		im:rrect(x, y + 2 * u, 8 * u, 5 * u, 2 * u, "D8D0C0")
		im:rrect(x + u, y + u, 6 * u, 5 * u, 2 * u, c)
		im:rect(x + 2 * u, y + 3 * u, u, u, "D8D0C0")
		im:rect(x + 5 * u, y + 2 * u, u, u, "D8D0C0")
	elseif name == "yarn" then
		im:rrect(x + u, y + u, 6 * u, 6 * u, 3 * u, c)
		im:rect(x + 2 * u, y + 3 * u, 4 * u, u, "B0709A")
		im:rect(x + 3 * u, y + 5 * u, 3 * u, u, "B0709A")
		im:rect(x + 6 * u, y + 6 * u, 2 * u, u, c)
	elseif name == "cloth" then
		im:rect(x, y + u, 8 * u, 6 * u, c)
		for i = 0, 3 do
			local gx = x + (i * 2 + 1) * u
			im:rect(gx, y + u, u, 6 * u, "C4B4DC")
		end
		im:rect(x, y + 6 * u, 8 * u, u, "C4B4DC")
	else
		im:rrect(x, y, 8 * u, 8 * u, u, c)
	end
end

LONG_PRESS = 0.45 -- seconds held still before a slot's menu opens
PULL_MAX = 7 -- gui pixels a pressed slot tugs toward the pointer, at most
PULL_SOFT = 14 -- how soon the tug gives out
MENU_W = 72
MENU_ROW = 14
AMOUNT_W = 200

function Bag.init()
	Bag.slots = {}
	Bag.open = false
	-- the furniture id whose insides are showing, or nil
	Bag.box = nil
	Bag.tip = nil
	Bag.press = nil -- a slot pressed: {src, i, x, y, t0, lifted}
	Bag.drag = nil -- a slot being dragged: {src, i}
	Bag.menu = nil -- a slot's menu: {src, i, opts, x, y, w, h}
	Bag.amount = nil -- asking how many: {title, kind, i, max, field, step, ...}
	Bag.prev_m2 = false
	if Bag.wallet == nil then
		Bag.wallet = 0
	end
end

function Bag.set(slots)
	if slots ~= nil then
		Bag.slots = slots
		-- the book's ready and waiting go by it
		Book.changed()
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

-- How many marbles the bag of them `item` holds, or nil.
function Bag.marbles_in(item)
	if item == nil then
		return nil
	end
	local n = item:match("^marbles:(%d+)$")
	if n == nil then
		return nil
	end
	return tonumber(n)
end

-- A count short enough for a slot: 12345 is 12k.
function Bag.short(n)
	if n >= 1000000 then
		return tostring(flr(n / 1000000)) .. "m"
	end
	if n >= 10000 then
		return tostring(flr(n / 1000)) .. "k"
	end
	return tostring(n)
end

-- Every bag of marbles in the bag, into the wallet.
function Bag.deposit_all()
	local any = false
	for i = 1, #Bag.slots do
		if Bag.marbles_in(Bag.slots[i][1]) ~= nil then
			any = true
			local p = {}
			p.deposit = i - 1
			Account.ask("wallet", p, Bag.wallet_reply)
		end
	end
	if not any then
		add_chat(nil, "no marbles in your bag", C_DIM)
	end
end

function Bag.withdraw(n)
	local p = {}
	p.withdraw = n
	Account.ask("wallet", p, Bag.wallet_reply)
end

function Bag.wallet_reply(r)
	Bag.set(r.bag)
	Bag.wallet = r.wallet
end

-- Items in the bag that can be placed (blocks, furniture that packs away),
-- each once, in bag order.
function Bag.placeable()
	local out = {}
	local seen = {}
	for i = 1, #Bag.slots do
		local s = Bag.slots[i]
		if s[1] ~= nil and not seen[s[1]] then
			local info = Furn.item(s[1])
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
	Bag.press = nil
	Bag.drag = nil
	Bag.menu = nil
	Bag.amount = nil
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
	L.x = flr((VIEW_W - L.w) / 2)
	-- the slots, then the wallet's row
	L.bag_h = rows * SLOT_H + LH * 2 + PAD * 5
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
	if Bag.menu ~= nil and Bag.in_menu(x, y) then
		return true
	end
	if Bag.amount ~= nil and Bag.in_amount(x, y) then
		return true
	end
	if x < L.x or x >= L.x + L.w then
		return false
	end
	if y >= L.bag_y and y < L.bag_y + L.bag_h then
		return true
	end
	return L.box ~= nil and y >= L.box_y and y < L.box_y + L.box_h
end

-- One grid of slots, `src` "bag" or "box"; returns the index under the
-- pointer, or nil. A slot being pressed tugs toward the pointer (but stays
-- put until it lifts); one being dragged shows empty.
function Bag.grid(title, slots, x, y, w, h, src)
	UI.panel(x, y, w, h)
	UI.text(title, x + PAD, y + PAD, C_TEXT)
	local hover = nil
	local gy = y + LH + PAD * 2
	local p = Bag.press
	local d = Bag.drag
	for i = 1, #slots do
		local col = (i - 1) % BAG_COLS
		local row = flr((i - 1) / BAG_COLS)
		local sx = x + PAD + col * SLOT_W
		local sy = gy + row * SLOT_H
		local over = UI.inside(sx, sy, SLOT_W - 2, SLOT_H - 2)
		local pressed = p ~= nil and p.src == src and p.i == i
		local dragged = d ~= nil and d.src == src and d.i == i
		if over then
			hover = i
			UI.hot = true
		end
		-- a paper pocket, ringed in orange under the pointer (green as a
		-- drop target), and lit as a long press comes due
		local ring = nil
		if over and d ~= nil and not dragged then
			ring = C_OK
		elseif over or (pressed and Bag.held_for(p) > LONG_PRESS / 3) then
			ring = C_ACCENT
		end
		if ring ~= nil then
			gui:rrect(sx - 1, sy - 1, SLOT_W, SLOT_H, 4, ring)
		end
		UI.paper(sx, sy, SLOT_W - 2, SLOT_H - 4, 4)
		local s = slots[i]
		if s[1] ~= nil and not dragged then
			local ox = 0
			local oy = 0
			if pressed and not p.lifted then
				ox, oy = Bag.pull(p)
			elseif pressed then
				oy = -2 -- lifted
			end
			Bag.draw_stack(s, sx + ox, sy + oy)
			if over and d == nil then
				Bag.tip = Bag.tip_for(s)
			end
		end
	end
	return hover
end

-- A stack's swatch and count, in a slot-sized box at (sx, sy).
function Bag.draw_stack(s, sx, sy)
	Icons.draw(gui, s[1], sx + 3, sy + 3, 1)
	local n = Bag.count_text(s)
	-- calls hoisted out of argument lists (petrichor64 SILT-BUGS.md #1)
	local nw = UI.text_w(n)
	UI.text(n, sx + SLOT_W - 3 - nw, sy + SLOT_H - LH - 3, C_INK)
end

function Bag.count_text(s)
	local marbles = Bag.marbles_in(s[1])
	if marbles ~= nil then
		return Bag.short(marbles)
	end
	return tostring(s[2])
end

function Bag.tip_for(s)
	local marbles = Bag.marbles_in(s[1])
	if marbles ~= nil then
		return tostring(marbles) .. " marbles"
	end
	local name = s[1]:match("^(%a+):%d+$") or s[1]
	if name == "sign" then
		return "a pinned message: place it like furniture"
	end
	return name .. " x" .. tostring(s[2])
end

-- How long the press `p` has been held, in seconds.
function Bag.held_for(p)
	return U.clock - p.t0
end

-- Where a pressed (not yet lifted) slot's contents are tugged: toward the
-- pointer, giving less the further it's pulled, never past PULL_MAX.
function Bag.pull(p)
	local dx = UI.mx - p.x
	local dy = UI.my - p.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 1 then
		return 0, 0
	end
	local k = PULL_MAX / (d + PULL_SOFT)
	return flr(dx * k), flr(dy * k)
end

-- The slot `i` of `src`, or nil.
function Bag.slot_of(src, i)
	if src == "bag" then
		return Bag.slots[i]
	end
	local f = nil
	if Bag.box ~= nil then
		f = Furn.pieces[Bag.box]
	end
	if f == nil then
		return nil
	end
	return f.slots[i]
end

-- Whether furniture `f` holds nothing.
function Bag.box_empty(f)
	for i = 1, #f.slots do
		if f.slots[i][1] ~= nil then
			return false
		end
	end
	return true
end

function Bag.filled(src, i)
	local s = Bag.slot_of(src, i)
	return s ~= nil and s[1] ~= nil
end

-- The wallet: how many marbles, and buttons to move them.
function Bag.wallet_row(x, y, w)
	-- a marble's swatch and the count, shortened: the whole of it on hover
	local w_n = Bag.wallet or 0
	gui:rrect(x + PAD, y + 2, 8, 8, 4, ITEM_COLORS.marbles)
	local text = "wallet " .. Bag.short(w_n)
	UI.text(text, x + PAD + 11, y + 2, C_TEXT)
	if UI.inside(x, y, w - 130, 12) then
		Bag.tip = tostring(w_n) .. " marbles in your wallet"
	end
	if UI.button("collect", x + w - PAD - 126, y, 60, 12) then
		Bag.deposit_all()
	end
	if UI.button("take out", x + w - PAD - 64, y, 64, 12) then
		Bag.open_menu("wallet", 0, x + w - PAD - 64, y + 12)
	end
end

-- Pointers on the slots: a press that's let go where it started is a tap
-- (what clicking a slot always did); held still for LONG_PRESS, or
-- right-clicked, it opens the slot's menu. With a mouse a press that moves
-- is a drag straight away; with a finger (the Android app) the slot only
-- tugs until the long press lifts it, and then moving it drags. Let go on
-- another slot to move it there (or into, or out of, the open box), or out
-- over the world to drop the whole stack there.
function Bag.input(L, hover)
	local m = UI.mouse
	local over_menu = Bag.menu ~= nil and Bag.in_menu(UI.mx, UI.my)
	local over_amount = Bag.amount ~= nil and Bag.in_amount(UI.mx, UI.my)
	local right = m.m2 and not Bag.prev_m2
	Bag.prev_m2 = m.m2
	if Bag.amount ~= nil then
		if UI.clicked and not over_amount then
			Bag.amount = nil
		end
		return
	end
	if right and hover ~= nil and Bag.filled(hover.src, hover.i) then
		Bag.press = nil
		Bag.drag = nil
		Bag.open_menu(hover.src, hover.i, UI.mx, UI.my)
		return
	end
	if UI.clicked then
		if Bag.menu ~= nil and not over_menu then
			Bag.menu = nil
			return
		end
		if not over_menu and hover ~= nil and Bag.filled(hover.src, hover.i) then
			local p = {}
			p.src = hover.src
			p.i = hover.i
			p.x = UI.mx
			p.y = UI.my
			p.t0 = U.clock
			p.lifted = false
			Bag.press = p
		end
	end
	local p = Bag.press
	if p == nil then
		return
	end
	if not Bag.filled(p.src, p.i) then
		-- the stack went (the server, another of our clients)
		Bag.press = nil
		Bag.drag = nil
		return
	end
	local dist = math.abs(UI.mx - p.x) + math.abs(UI.my - p.y)
	if m.m1 then
		if Bag.drag == nil and not p.lifted and Bag.held_for(p) >= LONG_PRESS and (APP.embedded or dist <= DRAG_PX) then
			p.lifted = true
			-- moving on from here drags, so measure from where it lifted
			p.x = UI.mx
			p.y = UI.my
			Bag.open_menu(p.src, p.i, UI.mx, UI.my)
			return
		end
		if Bag.drag == nil and (p.lifted or not APP.embedded) and dist > DRAG_PX then
			local d = {}
			d.src = p.src
			d.i = p.i
			Bag.drag = d
			Bag.menu = nil
		end
		return
	end
	-- let go
	local d = Bag.drag
	Bag.press = nil
	Bag.drag = nil
	if d ~= nil then
		Bag.drop_drag(L, d, hover)
	elseif not p.lifted then
		Bag.tap(p.src, p.i, L)
	end
end

-- What clicking a slot does: with a box open, move the stack across;
-- otherwise pick a bag item to build with.
function Bag.tap(src, i, L)
	local s = Bag.slot_of(src, i)
	-- a station open: in onto its work, as if dragged there
	if src == "bag" and Station.cur ~= nil then
		Station.add_item(s[1])
		return
	end
	if src == "box" then
		box_action("take_action", L.box.id, i - 1)
	elseif L.box ~= nil then
		box_action("stash_action", L.box.id, i - 1)
	else
		pick_build_item(s[1])
	end
end

function Bag.drop_drag(L, d, hover)
	if hover ~= nil then
		if d.src == "bag" and hover.src == "bag" and hover.i ~= d.i then
			local mv = { d.i - 1, hover.i - 1 }
			local payload = {}
			payload.move = mv
			act("bag_action", payload, "move that")
		elseif d.src == "bag" and hover.src == "box" then
			box_action("stash_action", L.box.id, d.i - 1)
		elseif d.src == "box" and hover.src == "bag" then
			box_action("take_action", L.box.id, d.i - 1)
		end
		return
	end
	-- onto an open station's work
	if d.src == "bag" and Station.over(UI.mx, UI.my) then
		local s = Bag.slots[d.i]
		Station.add_item(s[1])
		return
	end
	-- out over the world (not the HUD): set it down
	local over_hud = hud_hit(UI.mx, UI.my)
	if d.src == "bag" and not over_hud then
		Bag.drop(d.i, APP.aim)
	end
end

-- Set the whole stack in bag slot `i` down: at `aim` ({cell, on}, a cell
-- within reach), or at our feet.
function Bag.drop(i, aim)
	local payload = {}
	if aim ~= nil then
		payload = cell_payload(aim.cell, aim.on)
	end
	payload.drop = i - 1
	act("bag_action", payload, "drop that")
end

-- The menu for slot `i` of `src` ("bag", "box", or the "wallet"'s take out),
-- opened at (x, y).
function Bag.open_menu(src, i, x, y)
	local opts = {}
	if src == "wallet" then
		table.insert(opts, "100")
		table.insert(opts, "1000")
		table.insert(opts, "custom")
	elseif src == "box" then
		table.insert(opts, "take")
	else
		local s = Bag.slots[i]
		local marbles = Bag.marbles_in(s[1])
		local info = Furn.item(s[1])
		if marbles ~= nil then
			table.insert(opts, "collect")
		end
		if Bag.box ~= nil then
			table.insert(opts, "put in")
		elseif info ~= nil and (info.block ~= nil or info.furniture ~= nil) then
			table.insert(opts, "hold")
		end
		if (marbles ~= nil and marbles > 1) or (marbles == nil and s[2] > 1) then
			table.insert(opts, "split")
		end
		table.insert(opts, "drop")
	end
	local menu = {}
	menu.src = src
	menu.i = i
	menu.opts = opts
	menu.w = MENU_W
	menu.h = #opts * MENU_ROW + PAD * 2
	menu.x = U.clamp(x, PAD, VIEW_W - MENU_W - PAD)
	menu.y = U.clamp(y - menu.h, PAD, gui.h - menu.h - PAD)
	Bag.menu = menu
end

function Bag.in_menu(x, y)
	local mn = Bag.menu
	return x >= mn.x and x < mn.x + mn.w and y >= mn.y and y < mn.y + mn.h
end

function Bag.draw_menu()
	local mn = Bag.menu
	if mn == nil then
		return
	end
	if mn.src ~= "wallet" and not Bag.filled(mn.src, mn.i) then
		Bag.menu = nil
		return
	end
	UI.panel(mn.x, mn.y, mn.w, mn.h)
	local chosen = nil
	for k = 1, #mn.opts do
		local by = mn.y + PAD + (k - 1) * MENU_ROW
		if UI.button(mn.opts[k], mn.x + PAD, by, mn.w - PAD * 2, MENU_ROW - 2) then
			chosen = mn.opts[k]
		end
	end
	if chosen ~= nil then
		Bag.menu = nil
		Bag.choose(mn, chosen)
	end
end

function Bag.choose(mn, what)
	local i = mn.i
	if what == "100" or what == "1000" then
		Bag.withdraw(tonumber(what))
	elseif what == "custom" then
		Bag.ask_amount("take out", "withdraw", nil, Bag.wallet or 0, "")
	elseif what == "take" then
		box_action("take_action", Bag.box, i - 1)
	elseif what == "put in" then
		box_action("stash_action", Bag.box, i - 1)
	elseif what == "hold" then
		pick_build_item(Bag.slots[i][1])
	elseif what == "collect" then
		local p = {}
		p.deposit = i - 1
		Account.ask("wallet", p, Bag.wallet_reply)
	elseif what == "split" then
		local s = Bag.slots[i]
		local have = Bag.marbles_in(s[1]) or s[2]
		local half = flr(have / 2)
		Bag.ask_amount("split off", "split", i, have - 1, tostring(half))
	elseif what == "drop" then
		Bag.drop(i, nil)
	end
end

-- Ask how many, from 1 to `max`, for `kind` ("split" slot `i`, or
-- "withdraw" from the wallet): typed, or stepped with the buttons.
function Bag.ask_amount(title, kind, i, max, text)
	if max < 1 then
		add_chat(nil, "not enough to do that with", C_DIM)
		return
	end
	local a = {}
	a.title = title
	a.kind = kind
	a.i = i
	a.max = max
	a.field = UI.field(text, 10)
	-- a step that suits the size: 1, 10, 100 ...
	local step = 1
	while step * 100 <= max do
		step = step * 10
	end
	a.step = step
	a.w = AMOUNT_W
	a.h = LH * 2 + 12 * 2 + PAD * 6
	a.x = flr((VIEW_W - a.w) / 2)
	a.y = flr(gui.h / 3)
	Bag.amount = a
	cin() -- nothing typed before it opened
end

function Bag.in_amount(x, y)
	local a = Bag.amount
	return x >= a.x and x < a.x + a.w and y >= a.y and y < a.y + a.h
end

function Bag.amount_n()
	local a = Bag.amount
	local n = tonumber(a.field.text)
	if n == nil then
		return 0
	end
	return flr(n)
end

function Bag.set_amount(n)
	local a = Bag.amount
	local v = U.clamp(n, 1, a.max)
	a.field.text = tostring(v)
end

-- The keyboard, while it's open: digits, backspace, enter and escape.
function Bag.amount_keys()
	local a = Bag.amount
	local before = a.field.text
	local k = UI.type_into(a.field)
	if a.field.text:match("^%d*$") == nil then
		a.field.text = before
	end
	if k == "enter" then
		Bag.amount_ok()
	elseif k == "escape" then
		Bag.amount = nil
	end
end

function Bag.amount_ok()
	local a = Bag.amount
	local n = Bag.amount_n()
	if n < 1 or n > a.max then
		add_chat(nil, "pick from 1 to " .. tostring(a.max), C_DIM)
		return
	end
	Bag.amount = nil
	if a.kind == "withdraw" then
		Bag.withdraw(n)
	else
		local sp = { a.i - 1, n }
		local payload = {}
		payload.split = sp
		act("bag_action", payload, "split that")
	end
end

function Bag.draw_amount()
	local a = Bag.amount
	if a == nil then
		return
	end
	UI.panel(a.x, a.y, a.w, a.h)
	local title = a.title .. " (1 to " .. tostring(a.max) .. ")"
	UI.draw_field(title, a.field, a.x + PAD, a.y + PAD, a.w - PAD * 2, true)
	local by = a.y + LH * 2 + PAD * 4 + 2
	local bw = flr((a.w - PAD * 6) / 5)
	local bx = a.x + PAD
	local n = Bag.amount_n()
	local minus = "-" .. tostring(a.step)
	local plus = "+" .. tostring(a.step)
	if UI.button(minus, bx, by, bw, 12) then
		Bag.set_amount(n - a.step)
	end
	if UI.button(plus, bx + (bw + PAD), by, bw, 12) then
		Bag.set_amount(n + a.step)
	end
	if UI.button("half", bx + (bw + PAD) * 2, by, bw, 12) then
		Bag.set_amount(flr((a.max + 1) / 2))
	end
	if UI.button("all", bx + (bw + PAD) * 3, by, bw, 12) then
		Bag.set_amount(a.max)
	end
	if UI.button("ok", bx + (bw + PAD) * 4, by, bw, 12, "go") then
		Bag.amount_ok()
	end
end

-- What's being dragged, under the pointer, saying "drop" over the world.
function Bag.draw_ghost()
	local d = Bag.drag
	if d == nil then
		return
	end
	local s = Bag.slot_of(d.src, d.i)
	if s == nil or s[1] == nil then
		return
	end
	local gx = UI.mx - flr(SLOT_W / 2)
	local gy = UI.my - SLOT_H
	gui:rrect(gx + 1, gy + 3, SLOT_W - 2, SLOT_H - 4, 4, "00000060")
	UI.paper(gx, gy, SLOT_W - 2, SLOT_H - 4, 4)
	Bag.draw_stack(s, gx, gy)
	local over_hud = hud_hit(UI.mx, UI.my)
	if d.src == "bag" and not over_hud then
		UI.text("drop", gx, gy + SLOT_H, C_ACCENT)
	end
end

-- Draw the panels and act on the pointer; `bottom` is the y they sit above.
function Bag.draw(bottom)
	Bag.tip = nil
	if not Bag.open then
		Bag.press = nil
		Bag.drag = nil
		Bag.menu = nil
		Bag.amount = nil
		return
	end
	if Bag.box ~= nil and Furn.pieces[Bag.box] == nil then
		Bag.box = nil -- broken or carried off
	end
	local L = Bag.layout(bottom)
	local hover = nil
	local hi = Bag.grid("bag", Bag.slots, L.x, L.bag_y, L.w, L.bag_h, "bag")
	if hi ~= nil then
		hover = {}
		hover.src = "bag"
		hover.i = hi
	end
	if L.box ~= nil then
		local title = L.box.kind
		if L.box.kind == "sack" then
			title = "sack (what didn't fit)"
		end
		local bi = Bag.grid(title, L.box.slots, L.x, L.box_y, L.w, L.box_h, "box")
		if bi ~= nil then
			hover = {}
			hover.src = "box"
			hover.i = bi
		end
		-- empty, and made from a recipe: it can be broken for its parts
		if Bag.box_empty(L.box) and Recipes.making[L.box.kind] ~= nil then
			local bx = L.x + L.w - PAD - 44
			if UI.button("break", bx, L.box_y + PAD - 1, 44, 12) then
				ask_break(L.box)
			end
		end
	end
	-- before the menu's buttons, so a click on one isn't also a press on
	-- the slot under it
	Bag.input(L, hover)
	Bag.wallet_row(L.x, L.bag_y + L.bag_h - LH - PAD * 2, L.w)
	if Bag.tip ~= nil and Bag.menu == nil then
		local tw = UI.text_w(Bag.tip)
		UI.text(Bag.tip, L.x + L.w - tw - PAD, L.bag_y + PAD, C_TEXT)
	end
	Bag.draw_menu()
	Bag.draw_amount()
	Bag.draw_ghost()
end
