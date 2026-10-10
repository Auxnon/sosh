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

C_TEXT = "F4F0E6"
C_DIM = "A8B0BC"
C_PANEL = "141A26C8"
C_PANEL_HI = "26304AE0"
C_ACCENT = "F2B84B"
C_OK = "7BD389"
C_BAD = "F07167"
C_BUBBLE = "FFFDF6F0"
C_BUBBLE_TEXT = "222034"

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
	UI.my = flr(m.y * gui.h)
	UI.clicked = m.m1 and not UI.prev_m1
	UI.prev_m1 = m.m1
	-- set by buttons/panels under the pointer, so world clicks can be ignored
	UI.hot = false
	UI.blink = (UI.blink + 1) % 60
end

function UI.inside(x, y, w, h)
	return UI.mx >= x and UI.mx < x + w and UI.my >= y and UI.my < y + h
end

-- Panels claim the pointer so clicks on them don't walk the avatar.
function UI.panel(x, y, w, h, col)
	gui:rect(x, y, w, h, col or C_PANEL)
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

-- Returns true on the frame it's clicked.
function UI.button(label, x, y, w, h)
	local over = UI.inside(x, y, w, h)
	local bg = C_PANEL
	if over then
		bg = C_PANEL_HI
		UI.hot = true
	end
	gui:rrect(x, y, w, h, 3, bg)
	local tw = UI.text_w(label)
	local lx = x + flr((w - tw) / 2)
	local ly = y + flr((h - CH) / 2) + 1
	UI.text(label, lx, ly, C_TEXT)
	return over and UI.clicked
end

function UI.draw_field(label, f, x, y, w, focused)
	UI.text(label, x, y, C_DIM)
	local by = y + LH + 2
	local bh = LH + PAD * 2
	local col = C_PANEL
	if focused then
		col = C_PANEL_HI
	end
	gui:rrect(x, by, w, bh, 3, col)
	-- show the tail if it doesn't fit
	local fit = flr((w - PAD * 2) / CH) - 1
	local shown = f.text
	if #shown > fit then
		shown = shown:sub(#shown - fit + 1)
	end
	if focused and UI.blink < 30 then
		shown = shown .. "_"
	end
	UI.text(shown, x + PAD, by + PAD + 1, C_TEXT)
	if focused then
		gui:rect(x, by + bh - 2, w, 2, C_ACCENT)
	end
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

-- Name tag and stacked speech bubbles over one avatar.
function UI.avatar_overlay(av, is_me)
	local top = av:top()
	local p = UI.project(top[1], top[2], top[3])
	if p == nil then
		return
	end
	local x = p[1]
	local y = p[2]
	if x < -200 or x > gui.w + 200 or y < -200 or y > gui.h + 200 then
		return
	end

	local name = av.name
	if is_me then
		name = name .. " (you)"
	end
	local nw = UI.text_w(name) + PAD * 2
	local nx = x - flr(nw / 2)
	gui:rrect(nx, y - LH - 2, nw, LH + 2, 2, "0009")
	UI.text(name, nx + PAD, y - LH, av.hex)

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
		gui:rrect(bx, by, bw, bh, 4, C_BUBBLE)
		if i == #av.bubbles then
			-- little tail pointing at the speaker
			gui:rect(x - 2, by + bh, 5, 2, C_BUBBLE)
			gui:rect(x - 1, by + bh + 2, 3, 2, C_BUBBLE)
		end
		for j = 1, #lines do
			UI.text(lines[j], bx + PAD, by + PAD + (j - 1) * LH, C_BUBBLE_TEXT)
		end
		by = by - 4
		i = i - 1
	end
end
