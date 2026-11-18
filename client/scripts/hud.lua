-- hud — the toolbar and its picker, the button column, chat, the bag
-- panel (bag.lua), and the labels over the world.

HUD_BTN_W = 72
HUD_BTN_H = 18
-- right-hand column: emote (a dropdown of them), the book, look, pose,
-- bag, chat, home (in the app, whose own screens do chat, looks, the bag
-- and going home: emote, the book, pose); and holding furniture, break
HUD_ROWS = 7
HUD_ROWS_APP = 3
HINT = "enter: chat  wasd: walk  1-5: tool  z/x: pick  r: turn  i: bag  o: book  b: helm  h: helper  f: look  g: pose/drop  7-0: emote  q/e: look"
HINT_HELM = "at the helm: w/s ahead/astern  a/d turn  space/c up/down  b: let go"
TOOL_W = 60
PICK_W = 72
-- the sides of a universe, in the order its `open` list gives them
SIDES = { "east", "west", "north", "south" }

-- What the picker offers for the tool in hand: labels and the one chosen.
function picker_items()
	local out = {}
	local chosen = 0
	if APP.tool == "build" then
		local items = Bag.placeable()
		for i = 1, #items do
			local n = Bag.count(items[i])
			local label = items[i] .. " " .. tostring(n)
			table.insert(out, label)
			if items[i] == APP.build_item then
				chosen = i
			end
		end
	end
	return out, chosen
end

function picker_pick(i)
	if APP.tool == "build" then
		local items = Bag.placeable()
		APP.build_item = items[i]
	end
end

-- Where everything on the HUD goes this frame. The gui can be as small as
-- 320x240 (or wide and short, filling a browser window), so nothing
-- overlaps there: the button column hangs from the top right, wrapping into
-- a second column when it would reach the toolbar, the toolbar sits on the
-- bottom edge (the picker wraps to a row above it when it doesn't fit beside
-- it), the bag panel above those in the middle, and chat stacks above them
-- on the left, clear of the column.
function hud_layout()
	local L = {}
	-- the docked chat column (chatpane.lua) takes the right of a wide screen
	L.pane_w = Pane.width()
	VIEW_W = gui.w - L.pane_w
	L.top_h = LH + PAD * 2
	L.col_y = L.top_h + PAD * 2

	-- tool buttons narrow (and drop their numbers) on a small gui
	local nt = #TOOLS
	L.tool_w = TOOL_W
	local tfit = flr((VIEW_W - PAD * 4 - PAD * (nt - 1)) / nt)
	if tfit < L.tool_w then
		L.tool_w = tfit
	end
	local tools_w = L.tool_w * nt + PAD * (nt - 1)
	local items = picker_items()
	local n = #items
	L.items = items
	L.pick_bw = PICK_W
	-- too many to fit side by side: one button, "< chest >", that cycles
	L.compact = false
	if n > 0 then
		local widest = 0
		for i = 1, #items do
			local w = UI.text_w(items[i])
			if w > widest then
				widest = w
			end
		end
		local fit = flr((VIEW_W - PAD * 4 - PAD * (n - 1)) / n)
		if fit < widest + PAD * 2 then
			L.compact = true
			L.pick_bw = widest + CH * 4 + PAD * 2
			n = 1
		elseif fit < L.pick_bw then
			L.pick_bw = fit
		end
	end
	local pick_w = L.pick_bw * n + PAD * (n - 1)
	L.tb_y = gui.h - HUD_BTN_H - PAD * 2
	L.tb_x = flr((VIEW_W - tools_w) / 2)
	L.tb_w = tools_w
	L.pick = n > 0
	L.pick_x = 0
	L.pick_y = L.tb_y
	L.pick_w = pick_w
	local bottom = L.tb_y
	if L.pick then
		local both = tools_w + PAD * 3 + pick_w
		if both <= VIEW_W - PAD * 4 and L.pick_bw == PICK_W then
			L.tb_x = flr((VIEW_W - both) / 2)
			L.pick_x = L.tb_x + tools_w + PAD * 3
		else
			L.pick_y = L.tb_y - HUD_BTN_H - PAD * 2
			L.pick_x = flr((VIEW_W - pick_w) / 2)
			bottom = L.pick_y
		end
	end
	L.panel_bottom = bottom - PAD
	local rows = flr((L.panel_bottom - L.col_y + PAD) / (HUD_BTN_H + PAD))
	if rows < 1 then
		rows = 1
	end
	local count = HUD_ROWS
	if APP.embedded then
		count = HUD_ROWS_APP
	end
	if Carry.furniture(APP.my_id) ~= nil then
		count = count + 1
	end
	if rows > count then
		rows = count
	end
	local cols = flr((count + rows - 1) / rows)
	L.col_rows = rows
	L.col_x = VIEW_W - PAD * 2 - HUD_BTN_W * cols - PAD * (cols - 1)
	L.col_h = (HUD_BTN_H + PAD) * rows
	-- the emote dropdown opens to the left of its button, the column's first
	L.emotes_x = L.col_x - HUD_BTN_W - PAD
	L.emotes_y = L.col_y
	L.emotes_h = (HUD_BTN_H + PAD) * #EMOTES
	L.hint_text = HINT
	if Ships.piloted_by(APP.my_id) ~= nil then
		L.hint_text = HINT_HELM
	end
	-- key hints mean nothing on a phone
	L.hint = not APP.embedded and UI.text_w(L.hint_text) <= VIEW_W - PAD * 4
	if L.hint then
		bottom = bottom - LH - PAD
	end
	L.chat_bottom = bottom - PAD
	local w = flr(VIEW_W * 0.45)
	if w < 160 then
		w = 160
	end
	local room = L.col_x - PAD * 3
	if w > room then
		w = room
	end
	L.chat_w = w
	return L
end

function hud_hit(x, y)
	-- the book open over the world has it all
	if Book.is_up() then
		return true
	end
	if Choice.hit(x, y) or Station.over(x, y) or Heavy.hit(x, y) then
		return true
	end
	local L = hud_layout()
	if L.pane_w > 0 and x >= VIEW_W then
		return true
	end
	if Web.hit(x, y) then
		return true
	end
	if y < L.top_h then
		return true
	end
	if x >= L.col_x and y >= L.col_y and y < L.col_y + L.col_h then
		return true
	end
	if APP.emotes_open and x >= L.emotes_x and x < L.col_x and y >= L.emotes_y and y < L.emotes_y + L.emotes_h then
		return true
	end
	if y >= L.tb_y and x >= L.tb_x and x < L.tb_x + L.tb_w then
		return true
	end
	if L.pick and y >= L.pick_y and y < L.pick_y + HUD_BTN_H and x >= L.pick_x and x < L.pick_x + L.pick_w then
		return true
	end
	if L.pane_w == 0 and APP.typing and x < PAD + L.chat_w and y >= L.chat_bottom - LH - PAD * 2 and y < L.chat_bottom then
		return true
	end
	return Bag.hit(x, y, L.panel_bottom)
end

-- Name tags, speech bubbles, moos and blueprint labels, painted farthest
-- first. The gui is flat: whatever is drawn last covers the rest, so
-- drawing them in a fixed order put a far label over a near one.
function draw_world_labels()
	local labels = {}
	for id, c in pairs(Herd.cows) do
		local p = Herd.moo_point(c)
		if p ~= nil then
			local l = {}
			l.p = p
			l.cow = c
			table.insert(labels, l)
		end
	end
	local avs = {}
	for i = 1, #APP.order do
		table.insert(avs, APP.players[APP.order[i]])
	end
	for id, h in pairs(Helpers.list) do
		table.insert(avs, h.av)
	end
	if APP.me ~= nil then
		table.insert(avs, APP.me)
	end
	for i = 1, #avs do
		local av = avs[i]
		local top = av:top()
		local p = UI.project(top[1], top[2], top[3])
		if p ~= nil then
			local l = {}
			l.p = p
			l.av = av
			l.me = av == APP.me
			table.insert(labels, l)
		end
	end
	local sites = Furn.site_labels(APP.me)
	for i = 1, #sites do
		table.insert(labels, sites[i])
	end
	local signs = Furn.sign_labels(APP.me)
	for i = 1, #signs do
		table.insert(labels, signs[i])
	end
	-- insertion sort by depth (p[3]), farthest first; there are only a few
	for i = 2, #labels do
		local l = labels[i]
		local j = i - 1
		while j >= 1 and labels[j].p[3] < l.p[3] do
			labels[j + 1] = labels[j]
			j = j - 1
		end
		labels[j + 1] = l
	end
	for i = 1, #labels do
		local l = labels[i]
		if l.cow ~= nil then
			Herd.moo_bubble(l.p)
		elseif l.text ~= nil then
			draw_tag(l.text, l.p, l.col or C_ACCENT)
		else
			UI.avatar_overlay(l.av, l.me, l.p)
		end
	end
end

-- A small label centred over a projected point.
function draw_tag(text, p, col)
	local w = UI.text_w(text) + PAD * 2
	local x = p[1] - flr(w / 2)
	gui:rrect(x, p[2] - LH - 2, w, LH + 2, 3, C_GLASS)
	UI.text(text, x + PAD, p[2] - LH, col)
end

function draw_hud()
	local L = hud_layout()
	-- world overlays first so panels sit on top of them (not over the book)
	if not Book.is_up() then
		draw_world_labels()
	end

	-- top strip: connection, which universe, who's here
	local online = #APP.order
	if APP.me ~= nil then
		online = online + 1
	end
	UI.plastic(0, 0, VIEW_W, L.top_h, 0)
	if UI.inside(0, 0, VIEW_W, L.top_h) then
		UI.hot = true
	end
	local st = PHX.state
	local label = "connecting..."
	local col = C_ACCENT
	if st == "open" then
		label = "universe " .. universe_key(APP.universe)
		col = C_OK
	elseif st == "waiting" then
		label = "reconnecting in " .. tostring(flr(PHX.retry_in / FPS) + 1) .. "s"
		col = C_BAD
	end
	UI.text("sosh", PAD * 2, PAD + 1, C_ACCENT)
	UI.text(label, PAD * 2 + 6 * CH, PAD + 1, col)
	local here = tostring(online) .. " here"
	local hx = VIEW_W - UI.text_w(here) - PAD * 2
	UI.text(here, hx, PAD + 1, C_DIM)
	local edge = edge_note()
	if edge ~= nil then
		local ew = UI.text_w(edge)
		local ex = flr((VIEW_W - ew) / 2)
		gui:rrect(ex - PAD, L.top_h + PAD * 2, ew + PAD * 2, LH + PAD, 3, C_GLASS)
		UI.text(edge, ex, L.top_h + PAD * 3, C_ACCENT)
	end

	-- the book open: only the book (and its own buttons, book.lua)
	local book = Book.is_up()
	if book then
		L.pane_w = 0
	elseif L.pane_w > 0 then
		Pane.draw(L.pane_w)
	elseif not APP.embedded then
		draw_chat(L)
	end
	if APP.me ~= nil and not book then
		draw_toolbar(L)
		draw_buttons(L)
		Station.draw(L)
		Bag.draw(L.panel_bottom)
		Heavy.draw(L)
		if Station.placing ~= nil then
			local kname = Recipes.pretty(Station.placing.kind)
			local note = "click where to build the " .. kname .. "  (r: turn, esc: never mind)"
			local nw = UI.text_w(note) + PAD * 2
			local nx = flr((VIEW_W - nw) / 2)
			gui:rrect(nx, L.top_h + PAD * 2, nw, LH + PAD, 3, C_GLASS)
			UI.text(note, nx + PAD, L.top_h + PAD * 3, C_ACCENT)
		elseif L.hint and not APP.typing then
			UI.text(L.hint_text, PAD * 2, L.chat_bottom + PAD + 1, "FFFFFF70")
		end
		Choice.draw()
	elseif book then
		Choice.draw()
	end
	Book.draw_overlay()
	Fly.draw_labels()
end

-- Flying near the edge of the universe: what's past it.
function edge_note()
	if APP.me == nil then
		return nil
	end
	local s = Ships.get(APP.me.on)
	if s == nil then
		return nil
	end
	local near = UNIVERSE_HALF - 4
	local side = 0
	if s.x > near then
		side = 1
	elseif s.x < -near then
		side = 2
	elseif s.y > near then
		side = 3
	elseif s.y < -near then
		side = 4
	end
	if side == 0 then
		return nil
	end
	if APP.open[side] then
		return "the next universe lies " .. SIDES[side]
	end
	return "nothing lies " .. SIDES[side] .. " of here"
end

-- Tools (1-6) and what the tool in hand uses (Z/X): what to build from
-- the bag, or which blueprint to lay out.
function draw_toolbar(L)
	local x = L.tb_x
	local y = L.tb_y
	for i = 1, #TOOLS do
		local name = TOOLS[i]
		local label = name
		if L.tool_w >= TOOL_W then
			label = tostring(i) .. " " .. name
		end
		local tone = nil
		if APP.tool == name then
			tone = "on"
		end
		if UI.button(label, x, y, L.tool_w, HUD_BTN_H, tone) then
			APP.tool = name
		end
		x = x + L.tool_w + PAD
	end
	if not L.pick then
		return
	end
	local items, chosen = picker_items()
	x = L.pick_x
	y = L.pick_y
	if L.compact then
		local label = "< " .. (items[chosen] or "") .. " >"
		if UI.button(label, x, y, L.pick_bw, HUD_BTN_H, "go") then
			if UI.mx < x + L.pick_bw / 2 then
				cycle_pick(-1)
			else
				cycle_pick(1)
			end
		end
		items = {}
	end
	for i = 1, #items do
		local tone = nil
		if chosen == i then
			tone = "go"
		end
		if UI.button(items[i], x, y, L.pick_bw, HUD_BTN_H, tone) then
			picker_pick(i)
		end
		x = x + L.pick_bw + PAD
	end
end

-- The next place in the button column: down, then on to the next column.
function hud_next(L, P)
	P.row = P.row + 1
	if P.row >= L.col_rows then
		P.row = 0
		P.x = P.x + HUD_BTN_W + PAD
		P.y = L.col_y
	else
		P.y = P.y + HUD_BTN_H + PAD
	end
end

function draw_buttons(L)
	local me = APP.me
	local P = { x = L.col_x, y = L.col_y, row = 0 }
	-- one button for the emotes, opening the list of them (for now)
	local etone = nil
	local elabel = "emote v"
	if APP.emotes_open then
		etone = "on"
		elabel = "emote ^"
	end
	if UI.button(elabel, P.x, P.y, HUD_BTN_W, HUD_BTN_H, etone) then
		APP.emotes_open = not APP.emotes_open
	elseif UI.clicked and APP.emotes_open and not UI.inside(L.emotes_x, L.emotes_y, HUD_BTN_W, L.emotes_h) then
		APP.emotes_open = false
	end
	hud_next(L, P)
	draw_book_button(P.x, P.y)
	hud_next(L, P)
	if not APP.embedded then
		if UI.button("look", P.x, P.y, HUD_BTN_W, HUD_BTN_H) then
			Creator.open()
		end
		hud_next(L, P)
	end
	local pose_label = me:anim_name()
	if Ships.piloted_by(APP.my_id) ~= nil then
		pose_label = "let go"
	elseif Carry.of(APP.my_id) ~= nil then
		pose_label = "put down"
	end
	if UI.button(pose_label, P.x, P.y, HUD_BTN_W, HUD_BTN_H) then
		pose_pressed()
	end
	-- something in our arms that isn't going anywhere: break it for parts
	if Carry.furniture(APP.my_id) ~= nil then
		hud_next(L, P)
		if UI.button("break", P.x, P.y, HUD_BTN_W, HUD_BTN_H) then
			ask_break_held()
		end
	end
	APP.bag_btn = nil
	if not APP.embedded then
		hud_next(L, P)
		local btone = nil
		if Bag.open then
			btone = "on"
		end
		local bb = {}
		bb.x = P.x
		bb.y = P.y
		bb.w = HUD_BTN_W
		bb.h = HUD_BTN_H
		APP.bag_btn = bb
		if UI.button("i bag", P.x, P.y, HUD_BTN_W, HUD_BTN_H, btone) then
			if Bag.open then
				Bag.close()
			else
				Bag.open = true
			end
		end
		hud_next(L, P)
		local ctone = nil
		if APP.typing then
			ctone = "on"
		end
		if UI.button("chat", P.x, P.y, HUD_BTN_W, HUD_BTN_H, ctone) then
			APP.typing = not APP.typing
			APP.draft.text = ""
		end
		hud_next(L, P)
		if UI.button("home", P.x, P.y, HUD_BTN_W, HUD_BTN_H) then
			Account.leave_world()
		end
	end
	if APP.emotes_open then
		draw_emotes(L)
	end
end

-- The emotes, in a list beside their button; picking one plays it and
-- closes the list. (Keys 7-0 still play them directly.)
function draw_emotes(L)
	local y = L.emotes_y
	for i = 1, #EMOTES do
		local label = EMOTE_KEYS[i] .. " " .. EMOTES[i]
		if UI.button(label, L.emotes_x, y, HUD_BTN_W, HUD_BTN_H) then
			do_emote(EMOTES[i])
			APP.emotes_open = false
		end
		y = y + HUD_BTN_H + PAD
	end
end

function draw_chat(L)
	local w = L.chat_w
	local cols = flr((w - PAD * 2) / CH)
	local bottom = L.chat_bottom
	if APP.typing then
		bottom = bottom - (LH + PAD * 3)
	end

	-- gather wrapped lines from the newest message back
	local rows = {}
	local i = #APP.chat
	while i >= 1 and #rows < CHAT_SHOWN do
		local c = APP.chat[i]
		c.age = c.age + 1
		if c.age < CHAT_FADE or APP.typing then
			local text = c.body
			local prefix = ""
			if c.name ~= nil then
				prefix = c.name .. ": "
			end
			local wrapped = {}
			if text ~= "" then
				wrapped = U.wrap(prefix .. text, cols)
			end
			-- a picture or cart: its shape and what it is, on a line of its own
			-- (after the name, if it came alone)
			local media_at = nil
			if c.media ~= nil then
				local lead = "  "
				if text == "" then
					lead = prefix
				end
				local mline = lead .. Media.text(c.media)
				if #mline > cols then
					mline = mline:sub(1, cols)
				end
				table.insert(wrapped, mline)
				media_at = #wrapped
				c.media_col = #lead
			end
			local j = #wrapped
			while j >= 1 and #rows < CHAT_SHOWN do
				local row = {}
				row.text = wrapped[j]
				row.col = c.col
				if j == media_at then
					row.media = c.media
					row.media_col = c.media_col
				end
				table.insert(rows, row)
				j = j - 1
			end
		end
		i = i - 1
	end
	-- still age the rest
	while i >= 1 do
		APP.chat[i].age = APP.chat[i].age + 1
		i = i - 1
	end

	-- never climb into the top strip
	local max_rows = flr((bottom - L.top_h - PAD * 4) / LH)
	while #rows > max_rows and #rows > 0 do
		table.remove(rows)
	end

	if #rows > 0 then
		local h = #rows * LH + PAD * 2
		gui:rrect(PAD, bottom - h, w, h, 4, C_GLASS)
		for r = 1, #rows do
			local ry = bottom - PAD - r * LH + 1
			local row = rows[r]
			if row.media ~= nil and row.media.kind == "cart" then
				-- a game: click to play it
				local mx = PAD * 2 + row.media_col * CH
				local mw = UI.text_w(row.text) - row.media_col * CH
				if UI.inside(mx - 2, ry - 2, mw + 4, LH + 1) then
					UI.hot = true
					gui:rrect(mx - 2, ry - 2, mw + 4, LH + 1, 3, C_PANEL_LIT)
					if UI.clicked then
						Web.open(row.media)
					end
				end
			end
			UI.text(row.text, PAD * 2, ry, row.col)
			if row.media ~= nil then
				Media.glyph(PAD * 2 + row.media_col * CH, ry - 1, row.media, U.clock)
			end
		end
	end

	-- a shared cart running, over the world's top left (web.lua)
	if Web.cart ~= nil then
		local bw = flr(VIEW_W * 0.5)
		if bw > 320 then
			bw = 320
		end
		if bw < 160 then
			bw = 160
		end
		Web.draw_box(PAD * 2, L.top_h + PAD * 2, bw)
	end

	if APP.typing then
		local y = L.chat_bottom - LH - PAD * 2
		if Web.can_share() then
			-- the attach button, at the end of the box
			w = w - 18 - PAD
			if UI.button("+", PAD + w + PAD, y, 18, LH + PAD * 2) then
				Web.pick()
			end
		end
		UI.paper(PAD, y, w, LH + PAD * 2, 4)
		if UI.inside(PAD, y, w, LH + PAD * 2) then
			UI.hot = true
		end
		local shown = "> " .. APP.draft.text
		if #shown > cols - 1 then
			shown = shown:sub(#shown - cols + 2)
		end
		if UI.blink < 30 then
			shown = shown .. "_"
		end
		UI.text(shown, PAD * 2, y + PAD + 1, C_INK)
	end
end

-- The book's button: a plastic button like the rest, with a little open
-- book drawn on it.
function draw_book_button(x, y)
	local tone = nil
	if Book.is_up() then
		tone = "on"
	end
	local bb = {}
	bb.x = x
	bb.y = y
	bb.w = HUD_BTN_W
	bb.h = HUD_BTN_H
	APP.book_btn = bb
	local hit = UI.button("   book", x, y, HUD_BTN_W, HUD_BTN_H, tone)
	local dy = 0
	if UI.inside(x, y, HUD_BTN_W, HUD_BTN_H) and UI.mouse.m1 then
		dy = 1
	end
	local gx = x + 10
	local gy = y + 4 + dy
	gui:rect(gx - 1, gy + 1, 15, 10, "7A3E2A")
	gui:rect(gx, gy, 6, 9, C_PAPER)
	gui:rect(gx + 7, gy, 6, 9, C_PAPER)
	gui:rect(gx + 1, gy + 2, 4, 1, C_INK_DIM)
	gui:rect(gx + 1, gy + 4, 4, 1, C_INK_DIM)
	gui:rect(gx + 8, gy + 2, 4, 1, C_INK_DIM)
	gui:rect(gx + 8, gy + 4, 4, 1, C_INK_DIM)
	if hit then
		Book.toggle()
	end
end

-- -- a question with buttons: how to finish heavy furniture, whether to
-- break something

Choice = {}

-- Ask `title`, with buttons `opts`; the one pressed goes to choice_made
-- with `kind` and `data`.
function Choice.ask(title, opts, kind, data)
	local c = {}
	c.title = title
	c.opts = opts
	c.kind = kind
	c.data = data
	Choice.cur = c
end

function Choice.box()
	local c = Choice.cur
	local w = UI.text_w(c.title) + PAD * 4
	local bw = 0
	for i = 1, #c.opts do
		bw = bw + UI.text_w(c.opts[i]) + PAD * 3
	end
	if bw + PAD * 2 > w then
		w = bw + PAD * 2
	end
	if w > VIEW_W - PAD * 4 then
		w = VIEW_W - PAD * 4
	end
	local B = {}
	B.w = w
	B.h = LH + 14 + PAD * 4
	B.x = flr((VIEW_W - w) / 2)
	B.y = flr(gui.h / 3)
	return B
end

function Choice.hit(x, y)
	if Choice.cur == nil then
		return false
	end
	local B = Choice.box()
	return x >= B.x and x < B.x + B.w and y >= B.y and y < B.y + B.h
end

function Choice.draw()
	local c = Choice.cur
	if c == nil then
		return
	end
	if key("escape", true) then
		Choice.cur = nil
		choice_made(c.kind, "cancel", c.data)
		return
	end
	local B = Choice.box()
	UI.panel(B.x, B.y, B.w, B.h)
	UI.text(c.title, B.x + PAD * 2, B.y + PAD * 2, C_TEXT)
	local bx = B.x + PAD
	local by = B.y + LH + PAD * 3
	local chosen = nil
	for i = 1, #c.opts do
		local o = c.opts[i]
		local ow = UI.text_w(o) + PAD * 2
		local tone = nil
		if i == 1 then
			tone = "go"
		end
		if UI.button(o, bx, by, ow, 14, tone) then
			chosen = o
		end
		bx = bx + ow + PAD
	end
	if chosen ~= nil then
		Choice.cur = nil
		choice_made(c.kind, chosen, c.data)
	end
end

function choice_made(kind, opt, data)
	if kind == "finish" then
		if opt == "cancel" then
			-- the step from the book: back to it
			if data.from ~= nil and Station.cur == nil then
				Book.reopen()
			end
			return
		end
		Station.finish_choice(opt, data)
	elseif kind == "break" then
		if opt == "break" then
			break_action(data)
		end
	end
end

-- -- overencumbered: holding furniture that takes more carriers than it
-- has, we're stuck where we stand (`encumbered`, carry.lua)

Heavy = {}
HEAVY_TITLE = "too heavy to carry alone"
HEAVY_NOTE = "wait for help, or:"

function Heavy.box(L)
	local B = {}
	B.w = UI.text_w(HEAVY_TITLE) + PAD * 4
	local tw = UI.text_w(HEAVY_NOTE) + PAD * 4
	if tw > B.w then
		B.w = tw
	end
	if B.w > VIEW_W - PAD * 4 then
		B.w = VIEW_W - PAD * 4
	end
	B.h = LH * 2 + 14 + PAD * 5
	B.x = flr((VIEW_W - B.w) / 2)
	B.y = L.top_h + PAD * 2 + LH + PAD * 3
	return B
end

function Heavy.hit(x, y)
	if APP.my_id == nil or not Carry.is_pinned(APP.my_id) then
		return false
	end
	local L = hud_layout()
	local B = Heavy.box(L)
	return x >= B.x and x < B.x + B.w and y >= B.y and y < B.y + B.h
end

function Heavy.draw(L)
	if APP.my_id == nil or not Carry.is_pinned(APP.my_id) then
		return
	end
	local B = Heavy.box(L)
	UI.panel(B.x, B.y, B.w, B.h)
	UI.text(HEAVY_TITLE, B.x + PAD * 2, B.y + PAD * 2, C_ACCENT)
	UI.text(HEAVY_NOTE, B.x + PAD * 2, B.y + PAD * 2 + LH, C_DIM)
	local by = B.y + LH * 2 + PAD * 3
	if UI.button("put down", B.x + PAD * 2, by, 72, 14, "go") then
		put_down_ahead()
	end
	if UI.button("break", B.x + PAD * 3 + 72, by, 56, 14) then
		local what = {}
		break_action(what)
	end
end
