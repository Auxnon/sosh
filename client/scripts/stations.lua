-- stations — the screens of the crafting stations (veneer, bench, spinning
-- wheel, loom), the pieces drawn on them, and what's made flying home.
--
-- A station furniture clicked in reach (walk tool) opens its screen; so
-- does a step's "do it" in the book (book.lua), which also says the step.
-- Along the top, its tools: one for each gesture of the steps done there
-- (the bench has saw and assemble). In the middle, the work: the piece the
-- gesture is drawn on, laid out exactly as the server scores the stroke
-- (server/native/universe/src/recipes.rs: points 0..1 across and down the
-- drawing area; the plank lies along x over heights PLANK, the block over
-- widths BLOCK, the wheel a circle of WHEEL_RADIUS, the loom's passes
-- PASS wide). What goes in is dragged in from the bag panel (or a bag
-- slot tapped), and decides which step it is; then the gesture is drawn,
-- or "assemble" pressed. The stroke goes to `craft_action` and the
-- server's reply says what was made: its `n` can be less than the best
-- case. The result flies to the bag button.
--
-- Opened from the book, the station closes itself on success and the
-- book moves on; opened by hand it stays open. Furniture too big for a bag
-- asks "build it here" (aimed and turned like placing furniture, R turns
-- it, then `how: "place"`) or "carry it" (`how: "carry"`).

Station = {}
Piece = {}
Fly = {}

-- the layout recipes.rs scores against
PIECE_PLANK = { 0.35, 0.65 }
PIECE_BLOCK = { 0.1, 0.9 }
PIECE_WHEEL = 0.25
PIECE_PASS = 0.6
PIECE_PASSES = 4

STROKE_MAX = 512 -- points sent at most (the server reads 1024)
STROKE_STEP = 2 -- gui pixels the pointer moves before the next point
STATION_W = 248

FLY_TIME = 0.75 -- seconds from where it was made to the bag
FLY_DEPTH = 3 -- tiles ahead of the camera it lands
FLY_GAP = 0.12 -- seconds between several of a thing
FLY_MAX = 3 -- of a stack, at most this many fly
-- the items crafting makes have small models of their own (item_<name>)
FLY_ITEMS = { plank = true, post = true, wool = true, yarn = true, cloth = true }

function Station.init()
	Station.cur = nil
	-- heavy furniture being aimed: {step, from, kind}
	Station.placing = nil
	-- the craft we're waiting on: {step, from, how}
	Station.pending = nil
	Fly.list = {}
	Fly.labels = {}
end

-- The gestures done at station `kind` (nil: by hand), in the catalog's
-- order: its tools.
function Station.tools_for(kind)
	local out = {}
	local seen = {}
	for i = 1, #Recipes.order do
		local st = Recipes.steps[Recipes.order[i]]
		local g = st.gesture or "assemble"
		local sk = Recipes.station_of(st)
		if sk == kind and not seen[g] then
			seen[g] = true
			table.insert(out, g)
		end
	end
	return out
end

-- Open station `kind`'s screen: furniture `fid` (opened by hand, nil from
-- the book), on step `step` (from the book, `from` = {recipe, spread}).
function Station.open(kind, fid, step, from)
	local s = {}
	s.kind = kind
	s.fid = fid
	s.from = from
	s.fixed = step
	s.tools = Station.tools_for(kind)
	s.tool = s.tools[1] or "assemble"
	if step ~= nil then
		s.tool = step.gesture or "assemble"
	end
	s.tray = {}
	s.pick = 1
	s.stroke = {}
	s.drawing = false
	s.result = nil
	s.result_col = C_TEXT
	Station.cur = s
	if step ~= nil then
		local inputs = step.inputs
		for i = 1, #inputs do
			Station.add_item(inputs[i][1])
		end
	end
	Bag.box = nil
	Bag.open = true
	Choice.cur = nil
end

-- A station furniture clicked in the world.
function Station.open_piece(f)
	Station.open(f.kind, f.id, nil, nil)
end

-- Shut it. Opened from the book, the book comes back (where it was, or
-- on the next step after Book.step_done).
function Station.close()
	local s = Station.cur
	if s == nil then
		return
	end
	Station.cur = nil
	if Bag.box == nil then
		Bag.close()
	end
	if s.from ~= nil then
		Book.reopen()
	end
end

-- Leaving the world: nothing's open, nothing's aimed.
function Station.reset()
	Station.cur = nil
	Station.placing = nil
	Station.pending = nil
	Choice.cur = nil
	Fly.clear()
end

-- An item into the work (dragged from the bag, or a slot tapped).
function Station.add_item(item)
	local s = Station.cur
	if s == nil or item == nil then
		return
	end
	for i = 1, #s.tray do
		if s.tray[i] == item then
			return
		end
	end
	table.insert(s.tray, item)
	s.pick = 1
	s.result = nil
end

-- The steps the tool in hand could be doing here, given what's in the
-- tray: those using everything in it, the exact ones first.
function Station.matches(s)
	local out = {}
	if s.fixed ~= nil then
		table.insert(out, s.fixed)
		return out
	end
	if #s.tray == 0 then
		return out
	end
	local exact = {}
	local rest = {}
	for i = 1, #Recipes.order do
		local st = Recipes.steps[Recipes.order[i]]
		local g = st.gesture or "assemble"
		local sk = Recipes.station_of(st)
		if sk == s.kind and g == s.tool then
			local uses = 0
			local all = true
			for j = 1, #s.tray do
				local found = false
				for k = 1, #st.inputs do
					if st.inputs[k][1] == s.tray[j] then
						found = true
					end
				end
				if found then
					uses = uses + 1
				else
					all = false
				end
			end
			if all and uses == #st.inputs then
				table.insert(exact, st)
			elseif all then
				table.insert(rest, st)
			end
		end
	end
	for i = 1, #rest do
		table.insert(exact, rest[i])
	end
	return exact
end

-- The step the screen is on, or nil.
function Station.step(s)
	local list = Station.matches(s)
	if #list == 0 then
		return nil, list
	end
	if s.pick > #list then
		s.pick = 1
	end
	return list[s.pick], list
end

-- -- the screen

-- Where it goes: above the bag panel, as wide as it can be up to
-- STATION_W. A row for its name and tools, then the work square on the
-- left (as tall as what's left allows) and the words and tray beside it.
function Station.layout(L)
	local BL = Bag.layout(L.panel_bottom)
	local S = {}
	local bottom = BL.bag_y - PAD
	local top = L.top_h + PAD * 2
	local w = STATION_W
	if w > VIEW_W - PAD * 4 then
		w = VIEW_W - PAD * 4
	end
	S.w = w
	S.x = flr((VIEW_W - w) / 2)
	local head = 14 + PAD * 3
	local area = bottom - top - head - PAD
	if area > flr(w / 2) then
		area = flr(w / 2)
	end
	if area < 48 then
		area = 48
	end
	S.area = area
	S.h = head + area + PAD
	S.y = bottom - S.h
	if S.y < top then
		S.y = top
	end
	S.ax = S.x + PAD * 2
	S.ay = S.y + head
	-- the column beside the work
	S.cx = S.ax + area + PAD * 2
	S.cw = S.x + S.w - PAD * 2 - S.cx
	return S
end

function Station.over(x, y)
	local S = Station.box
	if Station.cur == nil or S == nil then
		return false
	end
	return x >= S.x and x < S.x + S.w and y >= S.y and y < S.y + S.h
end

-- Words in the column beside the work, wrapped; the y under them.
function Station.words(S, text, y, col)
	local per = flr(S.cw / CH)
	if per < 4 then
		per = 4
	end
	local lines = U.wrap(text, per)
	for i = 1, #lines do
		UI.text(lines[i], S.cx, y, col)
		y = y + LH
	end
	return y
end

-- Draw it and take the pointer, before the bag panel. `L` is the HUD's
-- layout.
function Station.draw(L)
	local s = Station.cur
	if s == nil then
		Station.box = nil
		return
	end
	if key("escape", true) then
		Station.close()
		return
	end
	local S = Station.layout(L)
	Station.box = S
	UI.panel(S.x, S.y, S.w, S.h)
	local title = "by hand"
	if s.kind ~= nil then
		title = Recipes.pretty(s.kind)
	end
	UI.text(title, S.x + PAD * 2, S.y + PAD * 2 + 2, C_TEXT)
	if UI.button("x", S.x + S.w - PAD - 16, S.y + PAD, 16, 14) then
		Station.close()
		return
	end
	-- the tools, after the name
	local tx = S.x + PAD * 3 + UI.text_w(title)
	local ty = S.y + PAD
	for i = 1, #s.tools do
		local t = s.tools[i]
		local tw = UI.text_w(t) + PAD * 2
		local tone = nil
		if s.tool == t then
			tone = "on"
		end
		if UI.button(t, tx, ty, tw, 14, tone) and s.fixed == nil and s.tool ~= t then
			s.tool = t
			s.stroke = {}
			s.pick = 1
			s.result = nil
		end
		tx = tx + tw + PAD
	end
	-- the work
	local st, list = Station.step(s)
	UI.paper(S.ax, S.ay, S.area, S.area, 3)
	Piece.draw(gui, s.tool, S.ax, S.ay, S.area, st ~= nil, st)
	Station.draw_stroke(s, S)
	Station.pointer(s, S, st)
	-- beside it: what it is and what it takes, the tray, the result
	local y = S.ay
	if st == nil then
		local why = "drag in what goes into it from your bag"
		if #s.tray > 0 then
			why = "nothing here takes that with " .. s.tool
		end
		y = Station.words(S, why, y, C_DIM)
	else
		local out_item, out_n = Recipes.output(st)
		local oname = Recipes.pretty(out_item)
		local line1 = "makes " .. oname
		if out_n > 1 then
			line1 = line1 .. " (up to " .. tostring(out_n) .. ")"
		end
		y = Station.words(S, line1, y, C_TEXT)
		local line2, col2 = Station.needs_text(st)
		y = Station.words(S, line2, y, col2)
	end
	y = y + PAD
	local rx = S.cx
	for i = 1, #s.tray do
		gui:rrect(rx - 1, y - 1, 12, 12, 2, C_PAPER)
		Icons.draw(gui, s.tray[i], rx + 1, y + 1, 1)
		rx = rx + 14
	end
	if #s.tray > 0 and s.fixed == nil then
		if UI.button("clear", rx + PAD, y - 2, 40, 14) then
			s.tray = {}
			s.pick = 1
		end
	end
	if #list > 1 and s.fixed == nil then
		local of = tostring(s.pick) .. "/" .. tostring(#list) .. " >"
		local ow = UI.text_w(of) + PAD * 2
		if UI.button(of, S.x + S.w - PAD * 2 - ow, y - 2, ow, 14) then
			s.pick = s.pick % #list + 1
		end
	end
	y = y + 14 + PAD
	local bottom = S.ay + S.area
	if st ~= nil and not st.stroke then
		local bw = 72
		local by = bottom - 14
		if UI.button("assemble", S.cx, by, bw, 14, "go") and Station.pending == nil then
			Station.send(st, nil, s.from)
		end
	elseif s.result ~= nil then
		Station.words(S, s.result, y, s.result_col)
	elseif st ~= nil then
		Station.words(S, "draw it on the left", y, C_DIM)
	end
	-- walked away from the station
	if s.fid ~= nil then
		local f = Furn.pieces[s.fid]
		if f == nil or f.lifted or APP.me == nil or not in_reach(APP.me, f.origin, f.on) then
			Station.close()
		end
	end
end

-- What a step takes, against the bag: the text and its colour.
function Station.needs_text(st)
	local t = "takes"
	local short = false
	local inputs = st.inputs
	for i = 1, #inputs do
		local inp = inputs[i]
		local have = Bag.count(inp[1])
		local name = Recipes.pretty(inp[1])
		t = t .. " " .. tostring(inp[2]) .. " " .. name .. " (" .. tostring(have) .. ")"
		if have < inp[2] then
			short = true
		end
	end
	local kind = Recipes.station_of(st)
	if kind ~= nil and Recipes.near[kind] ~= true then
		return t .. ": not near one", C_BAD
	end
	if short then
		return t, C_BAD
	end
	return t, C_OK
end

function Station.draw_stroke(s, S)
	local pts = s.stroke
	for i = 2, #pts do
		local a = pts[i - 1]
		local b = pts[i]
		local x1 = S.ax + flr(a[1] * S.area)
		local y1 = S.ay + flr(a[2] * S.area)
		local x2 = S.ax + flr(b[1] * S.area)
		local y2 = S.ay + flr(b[2] * S.area)
		gui:line(x1, y1, x2, y2, C_ACCENT)
		gui:line(x1 + 1, y1, x2 + 1, y2, C_ACCENT)
	end
end

-- Drawing on the work: a press in it starts a stroke, let go sends it.
function Station.pointer(s, S, st)
	local inside = UI.inside(S.ax, S.ay, S.area, S.area)
	if inside then
		UI.hot = true
	end
	if UI.clicked and inside and Bag.drag == nil then
		s.drawing = true
		s.stroke = {}
		s.result = nil
	end
	if not s.drawing then
		return
	end
	if UI.mouse.m1 then
		local nx = U.clamp((UI.mx - S.ax) / S.area, 0, 1)
		local ny = U.clamp((UI.my - S.ay) / S.area, 0, 1)
		local n = #s.stroke
		local far = true
		if n > 0 then
			local last = s.stroke[n]
			local dx = (nx - last[1]) * S.area
			local dy = (ny - last[2]) * S.area
			far = dx * dx + dy * dy >= STROKE_STEP * STROKE_STEP
		end
		if far and n < STROKE_MAX then
			local rx = U.round(nx, 1000)
			local ry = U.round(ny, 1000)
			local pt = { rx, ry }
			table.insert(s.stroke, pt)
		end
		return
	end
	-- let go
	s.drawing = false
	if #s.stroke < 2 then
		return
	end
	if st == nil then
		s.result = "drag in what goes into it first"
		s.result_col = C_DIM
		return
	end
	if not st.stroke or Station.pending ~= nil then
		return
	end
	Station.send(st, s.stroke, s.from)
end

-- -- doing it

-- Do step `st` with `stroke` (nil for none), for the book's `from` (or
-- nil): too big for a bag, first ask how it's finished.
function Station.send(st, stroke, from)
	if not st.to_bag then
		local item = Recipes.output(st)
		local name = Recipes.pretty(item)
		local data = {}
		data.step = st
		data.stroke = stroke
		data.from = from
		local opts = { "build it here", "carry it", "cancel" }
		Choice.ask("the " .. name .. " is too big for your bag", opts, "finish", data)
		return
	end
	Station.push(st, stroke, from, nil, nil, nil)
end

-- What was chosen for heavy furniture.
function Station.finish_choice(opt, data)
	if opt == "build it here" then
		local p = {}
		p.step = data.step
		p.from = data.from
		local item = Recipes.output(data.step)
		p.kind = item
		Station.placing = p
		-- out of the way while it's aimed
		local s = Station.cur
		if s ~= nil then
			s.from = nil
			Station.close()
		end
		add_chat(nil, "click where to build it (r: turn, esc: never mind)", C_DIM)
	elseif opt == "carry it" then
		Station.push(data.step, data.stroke, data.from, "carry", nil, nil)
	end
end

-- Aiming heavy furniture: the build tool's outline, and a click builds it.
function Station.place_at(cell, on)
	local p = Station.placing
	if p == nil or Station.pending ~= nil then
		return
	end
	Station.push(p.step, nil, p.from, "place", cell, on)
end

function Station.cancel_placing()
	local p = Station.placing
	if p == nil then
		return
	end
	Station.placing = nil
	if p.from ~= nil then
		Book.reopen()
	end
end

-- Send it: `how` "place" (at `cell` of frame `on`, turned R) or "carry"
-- for heavy furniture, else nil.
function Station.push(st, stroke, from, how, cell, on)
	if ACTIONS == nil or not ACTIONS.joined then
		add_chat(nil, "not in a world", C_BAD)
		return
	end
	local payload = {}
	if cell ~= nil then
		payload = cell_payload(cell, on)
		payload.rot = APP.rot
	end
	payload.step = st.id
	if stroke ~= nil and #stroke > 0 then
		payload.stroke = stroke
	end
	if how ~= nil then
		payload.how = how
	end
	local p = {}
	p.step = st
	p.from = from
	p.how = how
	if PHX:push(ACTIONS, "craft_action", payload, Station.reply) then
		Station.pending = p
	end
end

-- A hand step outside any world (book mode): `craft` on our channel.
function Station.craft_by_hand(st, from)
	if USER == nil or not USER.joined then
		Book.say("not signed in")
		return
	end
	local payload = {}
	payload.step = st.id
	local p = {}
	p.step = st
	p.from = from
	if PHX:push(USER, "craft", payload, Station.reply) then
		Station.pending = p
	end
end

-- The server's answer: what was made (`n` of `item`, `how`), or why not.
function Station.reply(status, r)
	local p = Station.pending
	Station.pending = nil
	if p == nil then
		return
	end
	local s = Station.cur
	if status ~= "ok" then
		local why = "failed"
		if r ~= nil and r.reason ~= nil then
			why = say_reason(r.reason)
		end
		if r ~= nil and r.reason == "place_or_carry" and APP.screen == "world" then
			Station.send(p.step, nil, p.from)
			return
		end
		Station.say("can't: " .. why, C_BAD, p)
		return
	end
	if r.bag ~= nil then
		Bag.set(r.bag)
	end
	Station.placing = nil
	local item = r.item or Recipes.output(p.step)
	local n = r.n or 1
	local name = Recipes.pretty(item)
	local _, best = Recipes.output(p.step)
	local text = "made " .. tostring(n) .. " " .. name
	if r.how == "place" then
		text = "built the " .. name
	elseif r.how == "carry" then
		text = "the " .. name .. " is in your arms"
	elseif n < best then
		text = text .. " (a cleaner stroke makes " .. tostring(best) .. ")"
	end
	if r.how == nil or r.how == "bag" then
		Fly.from_screen(item, n)
	end
	if p.from ~= nil then
		-- from the book: done here, on to the next step
		if s ~= nil and s.from ~= nil then
			Station.cur = nil
			Bag.close()
		end
		Book.say(text)
		Book.step_done(p.from, r)
		return
	end
	Station.say(text, C_OK, p)
end

-- A word on the open station, or in the chat (or the book's edge).
function Station.say(text, col, p)
	local s = Station.cur
	if s ~= nil then
		s.result = text
		s.result_col = col
		s.stroke = {}
		return
	end
	if APP.book_mode or Book.up then
		Book.say(text)
		return
	end
	add_chat(nil, text, col)
end

-- -- the pieces drawn on the work (and in the book): on image `im`, a
-- square `size` at (x0, y0). `hint` adds the guide for the gesture; `st`
-- (assembling) shows what goes together.

-- A point of the drawing area, 0..1 each way, in pixels.
function Piece.at(x0, y0, size, u, v)
	local px = x0 + flr(u * size)
	local py = y0 + flr(v * size)
	return px, py
end

function Piece.rect(im, x0, y0, size, u0, v0, u1, v1, col)
	local ax, ay = Piece.at(x0, y0, size, u0, v0)
	local bx, by = Piece.at(x0, y0, size, u1, v1)
	im:rect(ax, ay, bx - ax, by - ay, col)
end

function Piece.line(im, x0, y0, size, u0, v0, u1, v1, col)
	local ax, ay = Piece.at(x0, y0, size, u0, v0)
	local bx, by = Piece.at(x0, y0, size, u1, v1)
	im:line(ax, ay, bx, by, col)
end

-- A circle round (cu, cv) of radius r, all 0..1.
function Piece.circle(im, x0, y0, size, cu, cv, r, col)
	local n = 28
	for i = 0, n - 1 do
		local a = i / n * math.pi * 2
		local b = (i + 1) / n * math.pi * 2
		local u0 = cu + cos(a) * r
		local v0 = cv + sin(a) * r
		local u1 = cu + cos(b) * r
		local v1 = cv + sin(b) * r
		Piece.line(im, x0, y0, size, u0, v0, u1, v1, col)
	end
end

-- An arrowhead at (u, v), pointing along (du, dv).
function Piece.arrow(im, x0, y0, size, u, v, du, dv, col)
	local l = sqrt(du * du + dv * dv)
	if l < 0.0001 then
		return
	end
	local fx = du / l * 0.05
	local fy = dv / l * 0.05
	Piece.line(im, x0, y0, size, u, v, u - fx - fy, v - fy + fx, col)
	Piece.line(im, x0, y0, size, u, v, u - fx + fy, v - fy - fx, col)
end

function Piece.draw(im, gesture, x0, y0, size, hint, st)
	if gesture == "saw" then
		Piece.saw(im, x0, y0, size, hint)
	elseif gesture == "veneer" then
		Piece.veneer(im, x0, y0, size, hint)
	elseif gesture == "spin" then
		Piece.spin(im, x0, y0, size, hint)
	elseif gesture == "weave" then
		Piece.weave(im, x0, y0, size, hint)
	else
		Piece.assemble(im, x0, y0, size, st)
	end
end

-- The plank across the middle, along x; saw square across it.
function Piece.saw(im, x0, y0, size, hint)
	local lo = PIECE_PLANK[1]
	local hi = PIECE_PLANK[2]
	Piece.rect(im, x0, y0, size, 0.04, lo, 0.96, hi, "C4966A")
	Piece.rect(im, x0, y0, size, 0.04, hi - 0.03, 0.96, hi, "A07448")
	Piece.line(im, x0, y0, size, 0.1, lo + 0.1, 0.45, lo + 0.1, "A07448")
	Piece.line(im, x0, y0, size, 0.55, lo + 0.18, 0.9, lo + 0.18, "A07448")
	if hint then
		local n = 8
		for i = 0, n - 1 do
			local v0 = lo - 0.08 + i * (hi - lo + 0.16) / n
			local v1 = v0 + (hi - lo + 0.16) / n / 2
			Piece.line(im, x0, y0, size, 0.5, v0, 0.5, v1, "C04838")
		end
	end
end

-- The block, along x; one long stroke along it.
function Piece.veneer(im, x0, y0, size, hint)
	local lo = PIECE_BLOCK[1]
	local hi = PIECE_BLOCK[2]
	Piece.rect(im, x0, y0, size, lo, 0.4, hi, 0.72, "A87848")
	Piece.rect(im, x0, y0, size, lo, 0.4, hi, 0.46, "C4966A")
	Piece.line(im, x0, y0, size, lo + 0.05, 0.56, hi - 0.1, 0.56, "785430")
	Piece.line(im, x0, y0, size, lo + 0.15, 0.64, hi - 0.05, 0.64, "785430")
	if hint then
		Piece.line(im, x0, y0, size, lo, 0.32, hi, 0.32, "C04838")
		Piece.arrow(im, x0, y0, size, hi, 0.32, 1, 0, "C04838")
	end
end

-- The wheel in the middle; once round it.
function Piece.spin(im, x0, y0, size, hint)
	local r = PIECE_WHEEL
	Piece.circle(im, x0, y0, size, 0.5, 0.5, r, "8A5A3C")
	Piece.circle(im, x0, y0, size, 0.5, 0.5, r - 0.015, "8A5A3C")
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local u = 0.5 + cos(a) * r
		local v = 0.5 + sin(a) * r
		Piece.line(im, x0, y0, size, 0.5, 0.5, u, v, "A87848")
	end
	Piece.rect(im, x0, y0, size, 0.47, 0.47, 0.53, 0.53, "D696BE")
	if hint then
		local rr = r + 0.1
		local n = 20
		for i = 0, n - 3 do
			if i % 2 == 0 then
				local a = i / n * math.pi * 2
				local b = (i + 1) / n * math.pi * 2
				local u0 = 0.5 + cos(a) * rr
				local v0 = 0.5 + sin(a) * rr
				local u1 = 0.5 + cos(b) * rr
				local v1 = 0.5 + sin(b) * rr
				Piece.line(im, x0, y0, size, u0, v0, u1, v1, "C04838")
			end
		end
		local e = (n - 2) / n * math.pi * 2
		local eu = 0.5 + cos(e) * rr
		local ev = 0.5 + sin(e) * rr
		local du = -sin(e)
		local dv = cos(e)
		Piece.arrow(im, x0, y0, size, eu, ev, du, dv, "C04838")
	end
end

-- The loom's warp, top to bottom; across it and back, PASSES times.
function Piece.weave(im, x0, y0, size, hint)
	Piece.rect(im, x0, y0, size, 0.08, 0.1, 0.92, 0.15, "8A5A3C")
	Piece.rect(im, x0, y0, size, 0.08, 0.85, 0.92, 0.9, "8A5A3C")
	for i = 0, 8 do
		local u = 0.14 + i * 0.09
		Piece.line(im, x0, y0, size, u, 0.15, u, 0.85, "B8A890")
	end
	-- what's woven so far
	Piece.rect(im, x0, y0, size, 0.12, 0.72, 0.88, 0.85, "E4DAF0")
	if hint then
		local half = PIECE_PASS / 2
		local a = 0.5 - half
		local b = 0.5 + half
		for i = 0, PIECE_PASSES - 1 do
			local v0 = 0.24 + i * 0.11
			local v1 = v0 + 0.11
			if i % 2 == 0 then
				Piece.line(im, x0, y0, size, a, v0, b, v1, "C04838")
			else
				Piece.line(im, x0, y0, size, b, v0, a, v1, "C04838")
			end
		end
		local last = 0.24 + PIECE_PASSES * 0.11
		Piece.arrow(im, x0, y0, size, a, last, -1, 0.3, "C04838")
	end
end

-- What goes together, and what comes of it.
function Piece.assemble(im, x0, y0, size, st)
	if st == nil then
		Piece.rect(im, x0, y0, size, 0.2, 0.45, 0.8, 0.55, "E6D6B0")
		return
	end
	local u = 1
	if size >= 96 then
		u = 2
	end
	if size >= 160 then
		u = 3
	end
	local icon = 8 * u
	local inputs = st.inputs
	local n = #inputs
	local gap = flr(icon / 2)
	local total = n * icon + (n - 1) * gap
	local x = x0 + flr((size - total) / 2)
	local y = y0 + flr(size * 0.25)
	for i = 1, n do
		Icons.draw(im, inputs[i][1], x, y, u)
		local cnt = "x" .. tostring(inputs[i][2])
		im:text(cnt, x, y + icon + 2, "8A7458")
		x = x + icon + gap
	end
	local ax = x0 + flr(size / 2)
	local ay = y0 + flr(size * 0.55)
	local ay2 = ay + flr(size * 0.08)
	im:line(ax, ay, ax, ay2, "C04838")
	local out_item = Recipes.output(st)
	local ox = x0 + flr((size - icon * 2) / 2)
	local oy = y0 + flr(size * 0.68)
	Icons.draw(im, out_item, ox, oy, u * 2)
end

-- -- flying home

function Fly.clear()
	if Fly.list ~= nil then
		for i = 1, #Fly.list do
			Fly.list[i].ent:kill()
		end
	end
	Fly.list = {}
	Fly.labels = {}
end

-- The model a thing flies as, and how big.
function Fly.model(item)
	local name = item:match("^(%a+):%d+$") or item
	if FLY_ITEMS[name] then
		local m = "item_" .. name
		return m, 1
	end
	if name == "marbles" then
		return "marbles", 0.7
	end
	if Furn.kinds[name] ~= nil then
		return name, 0.35
	end
	local info = Furn.items[name]
	if info ~= nil and info.block ~= nil then
		local bname = BLOCK_NAMES[info.block]
		if bname ~= nil then
			return bname, 0.4
		end
	end
	return "sack", 0.7
end

-- Where things land: the bag button, or the book's, or the foot of the
-- screen; in gui pixels.
function Fly.target()
	local b = APP.bag_btn or APP.book_btn
	if b ~= nil and APP.screen == "world" and not APP.book_mode then
		local tx = b.x + flr(b.w / 2)
		local ty = b.y + flr(b.h / 2)
		return tx, ty
	end
	local fx = flr(VIEW_W / 2)
	local fy = gui.h - 8
	return fx, fy
end

-- `n` of `item` fly from world point (x, y, z) to the bag.
function Fly.launch(item, n, x, y, z)
	local model, scale = Fly.model(item)
	local k = n
	if k > FLY_MAX then
		k = FLY_MAX
	end
	if k < 1 then
		k = 1
	end
	for i = 1, k do
		local e = make(model, x, y, z, scale)
		local f = {}
		f.ent = e
		f.x = x
		f.y = y
		f.z = z
		f.scale = scale
		f.t = -(i - 1) * FLY_GAP / FLY_TIME
		f.spin = 0
		table.insert(Fly.list, f)
	end
	local name = Recipes.pretty(item)
	local l = {}
	l.text = "+" .. tostring(n) .. " " .. name
	l.t = U.clock + FLY_TIME
	table.insert(Fly.labels, l)
end

-- From the top of the open station (or the middle of the screen).
function Fly.from_screen(item, n)
	local sx = flr(VIEW_W / 2)
	local sy = flr(gui.h / 3)
	local S = Station.box
	if Station.cur ~= nil and S ~= nil then
		sy = S.y - 4
	end
	local x, y, z = UI.unproject(sx, sy, FLY_DEPTH)
	Fly.launch(item, n, x, y, z)
end

function Fly.update(dt)
	if #Fly.list == 0 then
		return
	end
	local tx, ty = Fly.target()
	local ex, ey, ez = UI.unproject(tx, ty, FLY_DEPTH)
	local A = UI.cam_axes()
	local keep = {}
	for i = 1, #Fly.list do
		local f = Fly.list[i]
		f.t = f.t + dt / FLY_TIME
		local e = f.ent
		if f.t >= 1 then
			e:kill()
		else
			local t = U.clamp(f.t, 0, 1)
			local k = t * t * (3 - 2 * t)
			-- an arc: up the screen, then down onto the button
			local lift = sin(t * math.pi) * 0.6
			e.x = U.lerp(f.x, ex, k) + A.ux * lift
			e.y = U.lerp(f.y, ey, k) + A.uy * lift
			e.z = U.lerp(f.z, ez, k) + A.uz * lift
			f.spin = f.spin + dt * 7
			e.rz = f.spin
			e.rx = f.spin * 0.6
			e.scale = f.scale * (1 - 0.5 * k)
			table.insert(keep, f)
		end
	end
	Fly.list = keep
end

-- "+2 post" by the bag as things land.
function Fly.draw_labels()
	if Fly.labels == nil or #Fly.labels == 0 then
		return
	end
	local tx, ty = Fly.target()
	local keep = {}
	local y = ty + 10
	for i = 1, #Fly.labels do
		local l = Fly.labels[i]
		local age = U.clock - l.t
		if age < 1.5 then
			if age >= 0 then
				local w = UI.text_w(l.text) + PAD * 2
				local half = flr(w / 2)
				local x = U.clamp(tx - half, PAD, VIEW_W - w - PAD)
				local lx = flr(x)
				gui:rrect(lx, y, w, LH + 2, 3, C_GLASS)
				UI.text(l.text, lx + PAD, y + 1, C_OK)
				y = y + LH + 4
			end
			table.insert(keep, l)
		end
	end
	Fly.labels = keep
end
