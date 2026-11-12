-- chatpane — on a wide screen the server's chat is a column beside the
-- world, the way the Android app puts its chat beside the world turned on
-- its side: a plastic bar on top (where we are, who's here), messages on
-- cream paper under their speaker's name tag, and the box to type in at the
-- bottom. The world takes the rest, its camera shifted so we stay in the
-- middle of what's left (place_camera).
--
-- Narrow screens keep the chat floating over the world (hud.lua's
-- draw_chat), and in the app the chat is the app's own.

Pane = {}

PANE_MIN_GUI_W = 560 -- gui pixels: narrower than this, the chat floats
PANE_MIN_W = 190
PANE_MAX_W = 300
PANE_HEAD_H = 30
C_GROUND = "241E4E" -- the app's ground behind everything
C_GROUND_GRID = "2C2660"

Pane.scroll = 0 -- pixels up from the newest message

-- How wide the column is now: 0 when the chat floats instead.
function Pane.width()
	if APP == nil or APP.embedded or APP.screen ~= "world" then
		return 0
	end
	if gui.w < PANE_MIN_GUI_W or gui.w < gui.h * 1.1 then
		return 0
	end
	local w = flr(gui.w * 0.3)
	if w < PANE_MIN_W then
		w = PANE_MIN_W
	end
	if w > PANE_MAX_W then
		w = PANE_MAX_W
	end
	return w
end

-- One message as the column lays it out at `cols` letters a line: its
-- lines, and where a picture's shape goes (the line it's on), cached until
-- the width changes.
function Pane.lines(c, cols)
	if c.pane_cols == cols then
		return c.pane_lines
	end
	local lines = {}
	if c.body ~= nil and c.body ~= "" then
		lines = U.wrap(c.body, cols)
	end
	c.pane_media_at = nil
	if c.media ~= nil then
		local label = Media.text(c.media)
		if #label > cols then
			label = label:sub(1, cols)
		end
		table.insert(lines, label)
		c.pane_media_at = #lines
	end
	c.pane_cols = cols
	c.pane_lines = lines
	return lines
end

-- Draw it at the right edge, `w` wide.
function Pane.draw(w)
	local x = gui.w - w
	local h = gui.h
	gui:rect(x, 0, w, h, C_GROUND)
	-- the app's faint grid
	local g = 16
	local gx = x + g - (x % g)
	while gx < gui.w do
		gui:rect(gx, 0, 1, h, C_GROUND_GRID)
		gx = gx + g
	end
	local gy = g
	while gy < h do
		gui:rect(x, gy, w, 1, C_GROUND_GRID)
		gy = gy + g
	end
	gui:rect(x, 0, 2, h, C_EDGE)
	if UI.inside(x, 0, w, h) then
		UI.hot = true
	end

	-- the bar: the server and who's here
	local bx = x + PAD + 2
	local bw = w - PAD * 2 - 2
	UI.plastic(bx, PAD, bw, PANE_HEAD_H - PAD, 6)
	local name = "sosh"
	if APP.server ~= nil then
		name = APP.server.name
	end
	local fit = flr((bw - PAD * 4) / CH)
	if #name > fit then
		name = name:sub(1, fit)
	end
	UI.text(name, bx + PAD * 2, PAD + 3, C_TEXT)
	local online = #APP.order
	if APP.me ~= nil then
		online = online + 1
	end
	local sub = "universe " .. universe_key(APP.universe) .. " - " .. tostring(online) .. " here"
	if PHX.state ~= "open" then
		sub = "connecting..."
	end
	if #sub > fit then
		sub = sub:sub(1, fit)
	end
	UI.text(sub, bx + PAD * 2, PAD + 3 + LH, C_DIM)

	-- a shared cart running, under the bar (web.lua)
	local top = PANE_HEAD_H + PAD * 2
	if Web.cart ~= nil then
		top = top + Web.draw_box(bx, top, bw) + PAD * 2
	end

	-- the box to type in, and the attach button beside it on the web
	local ch = LH + PAD * 2
	local cy = h - ch - PAD * 2
	local cx = bx
	local cw = bw
	if Web.can_share() then
		cw = bw - 18 - PAD
		if UI.button("+", cx + cw + PAD, cy, 18, ch) then
			Web.pick()
		end
	end
	if APP.typing then
		gui:rrect(cx - 1, cy - 1, cw + 2, ch + 2, 5, C_ACCENT)
	end
	UI.paper(cx, cy, cw, ch, 5)
	local cols = flr((cw - PAD * 2) / CH)
	local shown = APP.draft.text
	local col = C_INK
	if APP.typing then
		if #shown > cols - 1 then
			shown = shown:sub(#shown - cols + 2)
		end
		if UI.blink < 30 then
			shown = shown .. "_"
		end
	else
		shown = "enter: say something"
		col = C_INK_DIM
	end
	UI.text(shown, cx + PAD, cy + PAD + 1, col)
	if UI.inside(cx, cy, cw, ch) and UI.clicked then
		APP.typing = true
	end

	-- the messages, newest at the bottom, scrolled with the wheel
	local bottom = cy - PAD * 2
	if UI.inside(x, top, w, bottom - top) then
		local s = UI.mouse.scroll or 0
		if s ~= 0 then
			Pane.scroll = Pane.scroll + flr(s * LH * 3)
		end
	end
	if Pane.scroll < 0 then
		Pane.scroll = 0
	end
	local card_x = bx
	local card_w = bw
	local mcols = flr((card_w - PAD * 2) / CH)
	local y = bottom + Pane.scroll
	local i = #APP.chat
	local drawn = 0
	while i >= 1 and y > top do
		local c = APP.chat[i]
		local lines = Pane.lines(c, mcols)
		local lh = #lines * LH + PAD * 2 - 2
		if c.name == nil then
			-- something from the game, not a person: no card
			y = y - #lines * LH - PAD
			Pane.draw_lines(lines, c, card_x + PAD, y + 2, top, bottom, c.col)
			y = y - PAD
		else
			-- the name tag only over the first of a run by the same person
			local prev = APP.chat[i - 1]
			local tagged = prev == nil or prev.name ~= c.name
			y = y - lh
			if y < bottom and y + lh > top then
				gui:rrect(card_x, y + 2, card_w, lh, 4, C_PAPER_EDGE)
				gui:rrect(card_x, y, card_w, lh, 4, C_PAPER)
			end
			Pane.draw_lines(lines, c, card_x + PAD, y + PAD, top, bottom, C_INK)
			if tagged then
				local tag = c.name
				local tw = UI.text_w(tag) + PAD * 2
				y = y - LH - 3
				if y > top - LH then
					gui:rrect(card_x + 2, y, tw, LH + 1, 3, c.col or C_DIM)
					UI.text(tag, card_x + 2 + PAD, y + 1, C_TAG_INK)
				end
				y = y - 1
			end
			y = y - PAD
		end
		drawn = drawn + 1
		i = i - 1
	end
	-- don't scroll past the oldest one
	if i < 1 and y > top + LH then
		Pane.scroll = Pane.scroll - (y - top - LH)
		if Pane.scroll < 0 then
			Pane.scroll = 0
		end
	end
	-- the bar sits over whatever scrolled under it
	if Pane.scroll > 0 then
		local more = "newer below"
		local mw = UI.text_w(more) + PAD * 2
		local mx = x + flr((w - mw) / 2)
		gui:rrect(mx, bottom - LH - PAD, mw, LH + 2, 3, C_GLASS)
		UI.text(more, mx + PAD, bottom - LH - PAD + 2, C_ACCENT)
		if UI.inside(mx, bottom - LH - PAD, mw, LH + 2) and UI.clicked then
			Pane.scroll = 0
		end
	end
end

-- A message's lines from (x, y) down, skipping any outside top..bottom,
-- with the picture's shape where it goes.
function Pane.draw_lines(lines, c, x, y, top, bottom, col)
	for j = 1, #lines do
		local ly = y + (j - 1) * LH
		if ly >= top and ly + LH <= bottom then
			if c.pane_media_at == j and c.media.kind == "cart" then
				-- a game: click to play it
				local lw = UI.text_w(lines[j])
				if UI.inside(x - 2, ly - 2, lw + 4, LH + 2) then
					gui:rrect(x - 2, ly - 2, lw + 4, LH + 2, 3, C_PAPER_EDGE)
					if UI.clicked then
						Web.open(c.media)
					end
				end
			end
			UI.text(lines[j], x, ly, col)
			if c.pane_media_at == j then
				Media.glyph(x, ly - 1, c.media, U.clock)
			end
		end
	end
end
