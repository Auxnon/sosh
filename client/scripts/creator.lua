-- creator — the character creator (C on the home screen, or /look in the
-- world). A preview stands in front of the camera and is rebuilt on every
-- change; saving sends it to our account (`user:<id>` `character`), which
-- cleans it, keeps it and shows everyone.
--
-- Rows pick each piece (< and >) and, when selected, take a colour from
-- the palette. The face is a list of sprites: pick one to move it (the
-- arrows, or arrow keys), scale it, turn it, reshape it or recolour it;
-- add more of any part or remove it. Drag the preview to turn it.

Creator = {}

COLORS = {
	"FFDBAC", "F1C27D", "E8B796", "C68642", "8D5524", "4A3020",
	"302820", "F4F0E6", "A8B0BC", "40404A", "C04040", "E07040",
	"E0C040", "40A060", "4F7FC0", "8050C0", "E04080", "6A4A30",
}
-- the preview stands high above any island, alone in the sky
PREVIEW_Z = 80
FACE_PARTS = { "eye", "brow", "mouth", "nose", "cheek", "mark" }
CREATOR_ROWS = { "height", "skin", "head", "hair", "top", "bottom", "shoes", "hat" }
OPTIONS = {
	head = { "round", "square", "long", "bean" },
	hair = { "none", "short", "tuft", "bob", "spikes", "long" },
	top = { "none", "tee", "jacket", "sweater" },
	bottom = { "none", "pants", "shorts", "skirt" },
	shoes = { "none", "shoes", "boots" },
	hat = { "none", "cap", "beanie", "tophat" },
}
-- which colour each row edits
ROW_COLOR = {
	skin = "skin",
	hair = "hair_color",
	top = "top_color",
	bottom = "bottom_color",
	shoes = "shoes_color",
	hat = "hat_color",
}

function Creator.open()
	local base = Character.default()
	if APP.account ~= nil and APP.account.character ~= nil then
		base = APP.account.character
	end
	local c = {}
	c.spec = U.copy(base)
	c.row = "skin"
	c.part = 0
	c.facing = 0
	c.back = APP.screen
	c.status = ""
	c.dirty = false
	-- the catalog the server sent, if it did
	if APP.catalog ~= nil then
		OPTIONS.head = APP.catalog.heads
		local hair = APP.catalog.hair
		OPTIONS.hair = hair
		local cl = APP.catalog.clothes
		OPTIONS.top = cl.top
		OPTIONS.bottom = cl.bottom
		OPTIONS.shoes = cl.shoes
		OPTIONS.hat = cl.hat
	end
	c.preview = Character.new(c.spec, 0, 0, PREVIEW_Z)
	APP.creator = c
	APP.screen = "creator"
end

function Creator.close(save)
	local c = APP.creator
	if save then
		local p = {}
		p.character = c.spec
		Account.ask("character", p, function(r)
			APP.account.character = r.user.character
		end)
	end
	c.preview:kill()
	APP.creator = nil
	APP.screen = c.back
end

function Creator.changed()
	local c = APP.creator
	c.preview:restyle(c.spec)
	c.dirty = true
end

-- Step `field` through `options` by `d`.
function cycle(spec, field, options, d)
	local at = 1
	for i = 1, #options do
		if options[i] == spec[field] then
			at = i
		end
	end
	at = (at - 1 + d) % #options + 1
	spec[field] = options[at]
end

FACE_SHORT = { eye = "e", brow = "b", mouth = "m", nose = "n", cheek = "c", mark = "k" }
ROW_H = 14

function creator_screen()
	if PHX ~= nil then
		PHX:update()
	end
	local c = APP.creator
	local spec = c.spec

	local w = 168
	local x = gui.w - w - 4
	-- the preview, left of the panel: turning gently, or as dragged
	if UI.mouse.m1 and UI.mx < x then
		c.facing = c.facing + UI.mouse.dx * 0.02
	else
		c.facing = c.facing + 0.004
	end
	local none = {}
	c.preview:pose(0, 0, PREVIEW_Z, c.facing, "idle", none)
	local h = 1.45 * (spec.height or 1)
	local eye = { 3.4, 1.0, PREVIEW_Z + h * 0.6 }
	local look = { 3.14159, -0.02 }
	cam({ pos = eye, rot = look })

	local y = 4
	UI.panel(x, y, w, gui.h - 8)
	UI.text("your look", x + PAD, y + PAD, C_ACCENT)
	local ry = y + 16
	for i = 1, #CREATOR_ROWS do
		local row = CREATOR_ROWS[i]
		ry = creator_row(row, x + PAD, ry, w - PAD * 2)
	end

	-- colours for the selected row, or the selected face sprite
	ry = ry + 1
	local target = ROW_COLOR[c.row]
	local face = spec.face
	local sel = nil
	if c.part > 0 and face[c.part] ~= nil then
		sel = face[c.part]
	end
	ry = palette_row(x + PAD, ry, w - PAD * 2, function(hex)
		if sel ~= nil then
			sel.color = hex
		elseif target ~= nil then
			spec[target] = hex
		end
		Creator.changed()
	end)

	-- the face: add a part, pick one
	ry = ry + 3
	UI.text("face +", x + PAD, ry + 3, C_DIM)
	local bx = x + PAD + 52
	for i = 1, #FACE_PARTS do
		local name = FACE_PARTS[i]
		if UI.button(FACE_SHORT[name], bx, ry, 16, 13) and #face < 12 then
			local p = face_part(name, 0, 0, 0, "302820")
			table.insert(face, p)
			c.part = #face
			c.row = ""
			Creator.changed()
		end
		bx = bx + 18
	end
	ry = ry + 16
	local lx = x + PAD
	for i = 1, #face do
		local p = face[i]
		local label = FACE_SHORT[p.part] .. tostring(i)
		local lw = UI.text_w(label) + 4
		if lx + lw > x + w - PAD then
			lx = x + PAD
			ry = ry + 15
		end
		local was = c.part == i
		if UI.button(label, lx, ry, lw, 13) then
			if was then
				c.part = 0
			else
				c.part = i
				c.row = ""
			end
		end
		if was then
			gui:rect(lx, ry + 12, lw, 2, C_ACCENT)
		end
		lx = lx + lw + 2
	end
	ry = ry + 16
	if sel ~= nil then
		ry = sprite_controls(sel, x + PAD, ry, w - PAD * 2)
	end

	local by = gui.h - 22
	if UI.button("save", x + w - 84, by, 38, 14) then
		Creator.close(true)
		return
	end
	if UI.button("back", x + w - 42, by, 38, 14) or key("escape", true) then
		Creator.close(false)
	end
end

-- One row: its name (click: its colour takes the palette), < value >.
function creator_row(row, x, y, w)
	local c = APP.creator
	local spec = c.spec
	local picked = c.row == row
	if UI.button(row, x, y, 50, 12) then
		c.row = row
		c.part = 0
	end
	if picked then
		gui:rect(x, y + 11, 50, 2, C_ACCENT)
	end
	local vx = x + 54
	if row == "height" then
		local hv = spec.height or 1
		if UI.button("-", vx, y, 12, 12) then
			spec.height = U.clamp(hv - 0.05, 0.85, 1.2)
			Creator.changed()
		end
		local pct = flr(hv * 100 + 0.5)
		local label = tostring(pct) .. "%"
		UI.text(label, vx + 16, y + 2, C_TEXT)
		if UI.button("+", vx + 52, y, 12, 12) then
			spec.height = U.clamp(hv + 0.05, 0.85, 1.2)
			Creator.changed()
		end
	elseif row == "skin" then
		gui:rect(vx, y + 1, 20, 10, spec.skin or "FFFFFF")
	else
		if UI.button("<", vx, y, 12, 12) then
			cycle(spec, row, OPTIONS[row], -1)
			Creator.changed()
		end
		local value = spec[row] or "none"
		if #value > 7 then
			value = value:sub(1, 7)
		end
		UI.text(value, vx + 15, y + 2, C_TEXT)
		if UI.button(">", vx + 74, y, 12, 12) then
			cycle(spec, row, OPTIONS[row], 1)
			Creator.changed()
		end
		local col = ROW_COLOR[row]
		if col ~= nil then
			gui:rect(vx + 90, y + 1, 10, 10, spec[col] or "FFFFFF")
		end
	end
	return y + ROW_H
end

function palette_row(x, y, w, pick)
	local size = 10
	local per = flr(w / (size + 2))
	for i = 1, #COLORS do
		local col = (i - 1) % per
		local row = flr((i - 1) / per)
		local sx = x + col * (size + 2)
		local sy = y + row * (size + 2)
		gui:rect(sx, sy, size, size, COLORS[i])
		if UI.inside(sx, sy, size, size) then
			UI.hot = true
			if UI.clicked then
				pick(COLORS[i])
			end
		end
	end
	local rows = flr((#COLORS - 1) / per) + 1
	return y + rows * (size + 2)
end

-- Move, scale, turn, reshape or remove the picked face sprite.
function sprite_controls(p, x, y, w)
	local changed = false
	local step = 0.05
	local n = RIG.parts[p.part] or 1
	UI.text("shape", x, y + 2, C_DIM)
	if UI.button("<", x + 44, y, 12, 12) then
		p.shape = (p.shape - 1) % n
		changed = true
	end
	if UI.button(">", x + 58, y, 12, 12) then
		p.shape = (p.shape + 1) % n
		changed = true
	end
	if UI.button("-", x + 84, y, 12, 12) then
		p.scale = U.clamp((p.scale or 1) - 0.1, 0.4, 2.5)
		changed = true
	end
	if UI.button("+", x + 98, y, 12, 12) then
		p.scale = U.clamp((p.scale or 1) + 0.1, 0.4, 2.5)
		changed = true
	end
	if UI.button("(", x + 124, y, 12, 12) then
		p.rot = (p.rot or 0) - 0.2
		changed = true
	end
	if UI.button(")", x + 138, y, 12, 12) then
		p.rot = (p.rot or 0) + 0.2
		changed = true
	end
	y = y + ROW_H
	UI.text("move", x, y + 2, C_DIM)
	local left = UI.button("<", x + 44, y, 12, 12) or key("left", true)
	local right = UI.button(">", x + 58, y, 12, 12) or key("right", true)
	local up = UI.button("^", x + 72, y, 12, 12) or key("up", true)
	local down = UI.button("v", x + 86, y, 12, 12) or key("down", true)
	-- +x is to the viewer's right, facing the character
	if left then
		p.x = U.clamp((p.x or 0) - step, -1, 1)
		changed = true
	end
	if right then
		p.x = U.clamp((p.x or 0) + step, -1, 1)
		changed = true
	end
	if up then
		p.y = U.clamp((p.y or 0) + step, -1, 1)
		changed = true
	end
	if down then
		p.y = U.clamp((p.y or 0) - step, -1, 1)
		changed = true
	end
	if UI.button("del", x + 112, y, 26, 12) then
		local face = APP.creator.spec.face
		table.remove(face, APP.creator.part)
		APP.creator.part = 0
		changed = true
	end
	if changed then
		Creator.changed()
	end
	return y + ROW_H
end
