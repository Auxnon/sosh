-- hud — the toolbar and its picker, the button column, chat, the bag
-- panel (bag.lua), and the labels over the world.

HUD_BTN_W = 72
HUD_BTN_H = 18
HUD_ROWS = 9 -- right-hand column: 4 emotes, look, pose, bag, chat, home
HINT = "enter: chat  wasd: walk  1-6: tool  z/x: pick  r: turn  i: bag  b: helm  h: helper  f: look  g: pose/drop  7-0: emote  q/e: look"
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
	elseif APP.tool == "craft" then
		for i = 1, #Furn.order do
			table.insert(out, Furn.order[i])
		end
		chosen = APP.craft_i
	end
	return out, chosen
end

function picker_pick(i)
	if APP.tool == "build" then
		local items = Bag.placeable()
		APP.build_item = items[i]
	else
		APP.craft_i = i
	end
end

-- Where everything on the HUD goes this frame. The gui can be as small as
-- 320x240, so nothing overlaps there: the button column hangs from the top
-- right, the toolbar sits on the bottom edge (the picker wraps to a row
-- above it when it doesn't fit beside it), the bag panel above those in
-- the middle, and chat stacks above them on the left, clear of the column.
function hud_layout()
	local L = {}
	L.top_h = LH + PAD * 2
	L.col_x = gui.w - HUD_BTN_W - PAD * 2
	L.col_y = L.top_h + PAD * 2
	L.col_h = (HUD_BTN_H + PAD) * HUD_ROWS

	-- tool buttons narrow (and drop their numbers) on a small gui
	local nt = #TOOLS
	L.tool_w = TOOL_W
	local tfit = flr((gui.w - PAD * 4 - PAD * (nt - 1)) / nt)
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
		local fit = flr((gui.w - PAD * 4 - PAD * (n - 1)) / n)
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
	L.tb_x = flr((gui.w - tools_w) / 2)
	L.tb_w = tools_w
	L.pick = n > 0
	L.pick_x = 0
	L.pick_y = L.tb_y
	L.pick_w = pick_w
	local bottom = L.tb_y
	if L.pick then
		local both = tools_w + PAD * 3 + pick_w
		if both <= gui.w - PAD * 4 and L.pick_bw == PICK_W then
			L.tb_x = flr((gui.w - both) / 2)
			L.pick_x = L.tb_x + tools_w + PAD * 3
		else
			L.pick_y = L.tb_y - HUD_BTN_H - PAD * 2
			L.pick_x = flr((gui.w - pick_w) / 2)
			bottom = L.pick_y
		end
	end
	L.panel_bottom = bottom - PAD
	L.hint_text = HINT
	if Ships.piloted_by(APP.my_id) ~= nil then
		L.hint_text = HINT_HELM
	end
	L.hint = UI.text_w(L.hint_text) <= gui.w - PAD * 4
	if L.hint then
		bottom = bottom - LH - PAD
	end
	L.chat_bottom = bottom - PAD
	local w = flr(gui.w * 0.45)
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
	local L = hud_layout()
	if y < L.top_h then
		return true
	end
	if x >= L.col_x and y >= L.col_y and y < L.col_y + L.col_h then
		return true
	end
	if y >= L.tb_y and x >= L.tb_x and x < L.tb_x + L.tb_w then
		return true
	end
	if L.pick and y >= L.pick_y and y < L.pick_y + HUD_BTN_H and x >= L.pick_x and x < L.pick_x + L.pick_w then
		return true
	end
	if APP.typing and x < PAD + L.chat_w and y >= L.chat_bottom - LH - PAD * 2 and y < L.chat_bottom then
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
			draw_tag(l.text, l.p, C_ACCENT)
		else
			UI.avatar_overlay(l.av, l.me, l.p)
		end
	end
end

-- A small label centred over a projected point.
function draw_tag(text, p, col)
	local w = UI.text_w(text) + PAD * 2
	local x = p[1] - flr(w / 2)
	gui:rrect(x, p[2] - LH - 2, w, LH + 2, 2, "0009")
	UI.text(text, x + PAD, p[2] - LH, col)
end

function draw_hud()
	local L = hud_layout()
	-- world overlays first so panels sit on top of them
	draw_world_labels()

	-- top strip: connection, which universe, who's here
	local online = #APP.order
	if APP.me ~= nil then
		online = online + 1
	end
	UI.panel(0, 0, gui.w, L.top_h, "0A0E16B0")
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
	local hx = gui.w - UI.text_w(here) - PAD * 2
	UI.text(here, hx, PAD + 1, C_DIM)
	local edge = edge_note()
	if edge ~= nil then
		local ew = UI.text_w(edge)
		local ex = flr((gui.w - ew) / 2)
		gui:rrect(ex - PAD, L.top_h + PAD * 2, ew + PAD * 2, LH + PAD, 3, "0A0E16C0")
		UI.text(edge, ex, L.top_h + PAD * 3, C_ACCENT)
	end

	draw_chat(L)
	if APP.me ~= nil then
		draw_toolbar(L)
		draw_buttons(L)
		Bag.draw(L.panel_bottom)
		if L.hint and not APP.typing then
			UI.text(L.hint_text, PAD * 2, L.chat_bottom + PAD + 1, "FFFFFF70")
		end
	end
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
		if APP.tool == name then
			gui:rrect(x - 1, y - 1, L.tool_w + 2, HUD_BTN_H + 2, 3, C_ACCENT)
		end
		if UI.button(label, x, y, L.tool_w, HUD_BTN_H) then
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
		if UI.button(label, x, y, L.pick_bw, HUD_BTN_H) then
			if UI.mx < x + L.pick_bw / 2 then
				cycle_pick(-1)
			else
				cycle_pick(1)
			end
		end
		items = {}
	end
	for i = 1, #items do
		if chosen == i then
			gui:rrect(x - 1, y - 1, L.pick_bw + 2, HUD_BTN_H + 2, 3, C_OK)
		end
		if UI.button(items[i], x, y, L.pick_bw, HUD_BTN_H) then
			picker_pick(i)
		end
		x = x + L.pick_bw + PAD
	end
	-- what the chosen blueprint takes
	if APP.tool == "craft" then
		local kind = craft_kind()
		if kind ~= nil then
			local text = kind .. ": " .. Furn.recipe_text(kind) .. "  (r: turn)"
			UI.text(text, L.pick_x, L.pick_y - LH - 2, C_DIM)
		end
	end
end

function draw_buttons(L)
	local me = APP.me
	local x = L.col_x
	local y = L.col_y
	for i = 1, #EMOTES do
		local label = EMOTE_KEYS[i] .. " " .. EMOTES[i]
		if UI.button(label, x, y, HUD_BTN_W, HUD_BTN_H) then
			do_emote(EMOTES[i])
		end
		y = y + HUD_BTN_H + PAD
	end
	if UI.button("look", x, y, HUD_BTN_W, HUD_BTN_H) then
		Creator.open()
	end
	y = y + HUD_BTN_H + PAD
	local pose_label = me:anim_name()
	if Ships.piloted_by(APP.my_id) ~= nil then
		pose_label = "let go"
	elseif Carry.of(APP.my_id) ~= nil then
		pose_label = "put down"
	end
	if UI.button(pose_label, x, y, HUD_BTN_W, HUD_BTN_H) then
		pose_pressed()
	end
	y = y + HUD_BTN_H + PAD
	if UI.button("i bag", x, y, HUD_BTN_W, HUD_BTN_H) then
		if Bag.open then
			Bag.close()
		else
			Bag.open = true
		end
	end
	y = y + HUD_BTN_H + PAD
	if UI.button("chat", x, y, HUD_BTN_W, HUD_BTN_H) then
		APP.typing = not APP.typing
		APP.draft.text = ""
	end
	y = y + HUD_BTN_H + PAD
	if UI.button("home", x, y, HUD_BTN_W, HUD_BTN_H) then
		Account.leave_world()
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
			if c.name ~= nil then
				text = c.name .. ": " .. c.body
			end
			local wrapped = U.wrap(text, cols)
			local j = #wrapped
			while j >= 1 and #rows < CHAT_SHOWN do
				local row = {}
				row.text = wrapped[j]
				row.col = c.col
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
		gui:rrect(PAD, bottom - h, w, h, 3, "0A0E1690")
		for r = 1, #rows do
			UI.text(rows[r].text, PAD * 2, bottom - PAD - r * LH + 1, rows[r].col)
		end
	end

	if APP.typing then
		local y = L.chat_bottom - LH - PAD * 2
		UI.panel(PAD, y, w, LH + PAD * 2, C_PANEL_HI)
		local shown = "> " .. APP.draft.text
		if #shown > cols - 1 then
			shown = shown:sub(#shown - cols + 2)
		end
		if UI.blink < 30 then
			shown = shown .. "_"
		end
		UI.text(shown, PAD * 2, y + PAD + 1, C_TEXT)
	end
end
