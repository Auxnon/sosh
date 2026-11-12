-- ui — everything drawn on the `gui` raster: the connect screen, the HUD,
-- chat, name tags and speech bubbles. All in-engine, so desktop and web get
-- the same interface.
--
-- Coordinates are integer pixels (gunit treats a float below 2 as a percent,
-- so every computed position goes through flr). The font is 8px wide with a
-- 10px line.

UI = {}

CH = 8 -- glyph advance
LH = 10 -- line height
PAD = 4
DRAG_PX = 6 -- gui pixels a press moves before it is a drag, not a tap

-- The Android app's look (android/.../ui/Theme.kt): a console's indigo
-- plastic around cozy cream paper, with leaf green and orange.
C_TEXT = "F2EFFF" -- on plastic
C_DIM = "C3BCF5"
C_PANEL = "3B3380E8" -- plastic panels
C_PANEL_HI = "4D44A0" -- plastic buttons
C_PANEL_LIT = "5A50B8" -- a button under the pointer
C_EDGE = "1A1540" -- the solid shadow under plastic and paper
C_SHINE = "FFFFFF40" -- the light along plastic's top edge
C_GLASS = "241E4EB8" -- see-through indigo: the chat log, small labels
C_ACCENT = "F7A531" -- orange: the thing to press, and highlights
C_ACCENT_EDGE = "B86F12"
C_ON_ACCENT = "3A2410"
C_OK = "5DBB46" -- leaf green: what's selected
C_OK_EDGE = "2F7A22"
C_ON_OK = "16300C"
C_BAD = "F07167"
C_PAPER = "FFF4D6"
C_PAPER_EDGE = "C9A86A"
C_INK = "4A3B2A" -- on paper
C_INK_DIM = "8A7458"
C_TAG_INK = "3A2C1C" -- on a name tag
C_BUBBLE = "FFF4D6F4"
C_BUBBLE_TEXT = C_INK

-- Button tones: body, its edge, its text.
TONES = {
	plastic = { C_PANEL_HI, C_EDGE, C_TEXT },
	on = { C_OK, C_OK_EDGE, C_ON_OK },
	go = { C_ACCENT, C_ACCENT_EDGE, C_ON_ACCENT },
}

-- Keyboard text entry. cin() only reports unshifted characters, so shifted
-- symbols are mapped here.
SHIFTED = {}

function UI.init()
	local pairs_src = "1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~"
	local i = 1
	while i < #pairs_src do
		SHIFTED[pairs_src:sub(i, i)] = pairs_src:sub(i + 1, i + 1)
		i = i + 2
	end
	UI.mouse = mus()
	UI.prev_m1 = false
	UI.clicked = false
	UI.tapped = false
	UI.dragging = false
	UI.press_x = 0
	UI.press_y = 0
	UI.last_x = 0
	UI.last_y = 0
	UI.move_x = 0
	UI.move_y = 0
	UI.hot = false
	UI.blink = 0
	UI.back_held = 0
end

-- A single-line text field. Returns a table so several can exist.
function UI.field(text, limit)
	local f = {}
	f.text = text
	f.limit = limit
	return f
end

-- Feed this frame's typing into a field. Returns "enter", "escape" or nil.
function UI.type_into(f)
	local shift = key("shift")
	local typed = cin()
	if #typed > 0 then
		local out = ""
		for i = 1, #typed do
			local c = typed:sub(i, i)
			if shift then
				local m = SHIFTED[c]
				if m ~= nil then
					c = m
				else
					c = c:upper()
				end
			end
			out = out .. c
		end
		f.text = (f.text .. out):sub(1, f.limit)
	end
	-- backspace, with key repeat
	if key("back") then
		UI.back_held = UI.back_held + 1
		if UI.back_held == 1 or (UI.back_held > 24 and UI.back_held % 3 == 0) then
			f.text = f.text:sub(1, #f.text - 1)
		end
	else
		UI.back_held = 0
	end
	if key("enter", true) then
		return "enter"
	end
	if key("escape", true) then
		return "escape"
	end
	return nil
end

-- Call first thing in a frame.
function UI.begin()
	clr()
	local m = mus()
	UI.mouse = m
	UI.mx = flr(m.x * gui.w)
	-- the world's width on screen: all of it, unless the chat is docked
	-- beside it (hud_layout)
	VIEW_W = gui.w
	UI.my = flr(m.y * gui.h)
	-- how far the pointer moved since last frame, as a share of the screen
	-- (from positions: the browser only reports motion deltas when locked)
	UI.move_x = m.x - UI.last_x
	UI.move_y = m.y - UI.last_y
	UI.last_x = m.x
	UI.last_y = m.y
	UI.clicked = m.m1 and not UI.prev_m1
	local released = UI.prev_m1 and not m.m1
	UI.prev_m1 = m.m1
	-- a press that moves far enough is a drag (orbiting, with a finger),
	-- and one let go without dragging is a tap: what the world acts on
	if UI.clicked then
		UI.press_x = UI.mx
		UI.press_y = UI.my
		UI.dragging = false
	elseif m.m1 and not UI.dragging then
		if math.abs(UI.mx - UI.press_x) + math.abs(UI.my - UI.press_y) > DRAG_PX then
			UI.dragging = true
		end
	end
	UI.tapped = released and not UI.dragging
	-- set by buttons/panels under the pointer, so world clicks can be ignored
	UI.hot = false
	UI.blink = (UI.blink + 1) % 60
end

function UI.inside(x, y, w, h)
	return UI.mx >= x and UI.mx < x + w and UI.my >= y and UI.my < y + h
end

-- Plastic: `body` with a light line along the top and a solid `edge`
-- under it.
function UI.plastic(x, y, w, h, r, body, edge)
	gui:rrect(x, y + 2, w, h, r, edge or C_EDGE)
	gui:rrect(x, y, w, h, r, body or C_PANEL)
	gui:rect(x + r, y, w - r * 2, 1, C_SHINE)
end

-- Paper: a cream card with its shadow.
function UI.paper(x, y, w, h, r)
	gui:rrect(x, y + 2, w, h, r, C_PAPER_EDGE)
	gui:rrect(x, y, w, h, r, C_PAPER)
end

-- Panels claim the pointer so clicks on them don't walk the avatar. Plastic
-- unless given a flat colour.
function UI.panel(x, y, w, h, col)
	if col ~= nil then
		gui:rect(x, y, w, h, col)
	else
		UI.plastic(x, y, w, h, 5)
	end
	if UI.inside(x, y, w, h) then
		UI.hot = true
	end
end

function UI.text(s, x, y, col)
	-- call arguments are hoisted throughout: silt can call the wrong value
	-- when a call argument is followed by locals (SILT-BUGS.md #1)
	local px = flr(x)
	local py = flr(y)
	gui:text(s, px, py, col or C_TEXT)
end

function UI.text_w(s)
	return #s * CH
end

-- A plastic button; `tone` "on" (green: selected) or "go" (orange: the
-- thing to do). Held down it sinks onto its edge. True on the frame it's
-- clicked.
function UI.button(label, x, y, w, h, tone)
	local over = UI.inside(x, y, w, h)
	local t = TONES[tone or "plastic"]
	local body = t[1]
	if over then
		UI.hot = true
		if tone == nil then
			body = C_PANEL_LIT
		end
	end
	local dy = 0
	if over and UI.mouse.m1 then
		dy = 1
	end
	gui:rrect(x, y + 2, w, h, 4, t[2])
	gui:rrect(x, y + dy, w, h, 4, body)
	gui:rect(x + 4, y + dy, w - 8, 1, C_SHINE)
	local tw = UI.text_w(label)
	local lx = x + flr((w - tw) / 2)
	local ly = y + dy + flr((h - CH) / 2) + 1
	UI.text(label, lx, ly, t[3])
	return over and UI.clicked
end

function UI.draw_field(label, f, x, y, w, focused)
	UI.text(label, x, y, C_DIM)
	local by = y + LH + 2
	local bh = LH + PAD * 2
	if focused then
		gui:rrect(x - 1, by - 1, w + 2, bh + 2, 4, C_ACCENT)
	end
	UI.paper(x, by, w, bh, 4)
	-- show the tail if it doesn't fit
	local fit = flr((w - PAD * 2) / CH) - 1
	local shown = f.text
	if #shown > fit then
		shown = shown:sub(#shown - fit + 1)
	end
	if focused and UI.blink < 30 then
		shown = shown .. "_"
	end
	UI.text(shown, x + PAD, by + PAD + 1, C_INK)
	return UI.inside(x, by, w, bh) and UI.clicked
end

-- World point -> gui pixel, or nil if behind the camera. Mirrors the engine's
-- camera: forward from (azimuth, altitude), Z up, 45 degree vertical fov.
function UI.project(px, py, pz)
	local ca = cos(CAM.az)
	local sa = sin(CAM.az)
	local cl = cos(CAM.alt)
	local fx = ca * cl
	local fy = sa * cl
	local fz = sin(CAM.alt)
	local rl = sqrt(fx * fx + fy * fy)
	local rx = fy / rl
	local ry = -fx / rl
	local ux = ry * fz
	local uy = -rx * fz
	local uz = rx * fy - ry * fx
	local dx = px - CAM.x
	local dy = py - CAM.y
	local dz = pz - CAM.z
	local depth = dx * fx + dy * fy + dz * fz
	if depth < 0.5 then
		return nil
	end
	local xc = dx * rx + dy * ry
	local yc = dx * ux + dy * uy + dz * uz
	local th = 0.41421356 -- tan(22.5 deg)
	local aspect = gui.w / gui.h
	local sx = 0.5 + 0.5 * xc / (depth * th * aspect)
	local sy = 0.5 - 0.5 * yc / (depth * th)
	-- calls hoisted out of the constructor (silt miscompiles them there)
	local px_x = flr(sx * gui.w)
	local px_y = flr(sy * gui.h)
	local out = { px_x, px_y, depth }
	return out
end

-- Name tag and stacked speech bubbles over one avatar, at its projected
-- head point `p` (UI.project of av:top()).
function UI.avatar_overlay(av, is_me, p)
	local x = p[1]
	local y = p[2]
	if x < -200 or x > gui.w + 200 or y < -200 or y > gui.h + 200 then
		return
	end

	local name = av.name
	if is_me then
		name = name .. " (you)"
	end
	-- the speaker's colour as a name tag, dark ink on it
	local nw = UI.text_w(name) + PAD * 2
	local nx = x - flr(nw / 2)
	gui:rrect(nx, y - LH - 2, nw, LH + 2, 3, av.hex)
	UI.text(name, nx + PAD, y - LH, C_TAG_INK)

	-- newest bubble lowest, nearest the head
	local by = y - LH - 6
	local i = #av.bubbles
	while i >= 1 do
		local b = av.bubbles[i]
		local lines = b.lines
		local wmax = 0
		for j = 1, #lines do
			if #lines[j] > wmax then
				wmax = #lines[j]
			end
		end
		local bw = wmax * CH + PAD * 2
		local bh = #lines * LH + PAD * 2 - 2
		local bx = x - flr(bw / 2)
		by = by - bh
		gui:rrect(bx, by + 2, bw, bh, 4, C_PAPER_EDGE)
		gui:rrect(bx, by, bw, bh, 4, C_BUBBLE)
		if i == #av.bubbles then
			-- little tail pointing at the speaker
			gui:rect(x - 2, by + bh, 5, 2, C_BUBBLE)
			gui:rect(x - 1, by + bh + 2, 3, 2, C_BUBBLE)
		end
		for j = 1, #lines do
			UI.text(lines[j], bx + PAD, by + PAD + (j - 1) * LH, C_BUBBLE_TEXT)
			if b.media_at == j then
				Media.glyph(bx + PAD, by + PAD + (j - 1) * LH - 1, b.media, U.clock)
			end
		end
		by = by - 4
		i = i - 1
	end
end
