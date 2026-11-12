-- media — pictures and carts shared in chat, as the game shows them.
--
-- The game doesn't draw the picture itself: it shows a little shape the size
-- of a letter where it sits in a message (in the log, the chat column and
-- speech bubbles), and a word for what it is. A still picture is a framed
-- hill under a sun; an animated one (a gif, an animated webp or png) is the
-- same frame with its sun going round; a Petrichor64 cart is a cartridge.
-- The Android app shows the pictures themselves, and runs carts.
--
-- A message's `media` (server: Sosh.Media.view): {key, url, kind ("image"
-- or "cart"), mime, animated, w, h, size, name}.

Media = {}

MEDIA_W = 8 -- the shape is one letter wide (CH; ui.lua loads after this)
MEDIA_GAP = 2 -- and this far from the word after it

C_MEDIA_FRAME = "C9A86A"
C_MEDIA_SKY = "9FD3F5"
C_MEDIA_HILL = "5DBB46"
C_MEDIA_SUN = "F7A531"
C_CART = "4D44A0"
C_CART_LABEL = "FFF4D6"

-- What it's called in a line of chat.
function Media.label(m)
	if m.kind == "cart" then
		local name = m.name or "a game"
		local bare = name:gsub("%.game%.png$", "")
		local plain = bare:gsub("%.png$", "")
		return plain .. " - play"
	end
	local what = "picture"
	if m.animated then
		what = "gif"
		if m.mime == "image/webp" then
			what = "moving webp"
		end
	elseif m.mime == "image/webp" then
		what = "webp"
	end
	if m.w ~= nil and m.h ~= nil then
		what = what .. " " .. tostring(m.w) .. "x" .. tostring(m.h)
	end
	return what
end

-- The text a line shows for it after the shape: a space for the shape, then
-- the label.
function Media.text(m)
	return "  " .. Media.label(m)
end

-- Draw the shape for `m` with its top left at (x, y), sized to a line of
-- text. `t` is the time, which moves an animated one.
function Media.glyph(x, y, m, t)
	x = flr(x)
	y = flr(y)
	if m.kind == "cart" then
		-- a cartridge: a body with a notch out of the top right, its label,
		-- and the grip ridges under it
		gui:rect(x, y, MEDIA_W - 2, LH - 2, C_CART)
		gui:rect(x + MEDIA_W - 2, y + 2, 1, LH - 4, C_CART)
		gui:rect(x + 1, y + 1, MEDIA_W - 4, 4, C_CART_LABEL)
		gui:rect(x + 2, y + 2, 2, 2, C_MEDIA_SUN)
		gui:rect(x + 1, y + 6, 1, 1, C_CART_LABEL)
		gui:rect(x + 3, y + 6, 1, 1, C_CART_LABEL)
		gui:rect(x + 5, y + 6, 1, 1, C_CART_LABEL)
		return
	end
	-- a framed picture: sky, a hill, a sun
	local w = MEDIA_W
	local h = LH - 2
	gui:rect(x, y, w, h, C_MEDIA_FRAME)
	gui:rect(x + 1, y + 1, w - 2, h - 2, C_MEDIA_SKY)
	gui:rect(x + 1, y + h - 3, w - 2, 2, C_MEDIA_HILL)
	gui:rect(x + 3, y + h - 4, 3, 1, C_MEDIA_HILL)
	local sx = x + w - 3
	local sy = y + 2
	if m.animated then
		-- round the frame, a step every few frames
		local steps = { { 1, 1 }, { 3, 1 }, { 5, 1 }, { 5, 2 }, { 3, 3 }, { 1, 2 } }
		local i = flr(t * 6) % #steps + 1
		sx = x + steps[i][1]
		sy = y + steps[i][2]
	end
	gui:rect(sx, sy, 2, 2, C_MEDIA_SUN)
end
