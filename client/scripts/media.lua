-- media — pictures and carts shared in chat, as the game shows them.
--
-- The game doesn't draw the picture itself: it shows a little shape the size
-- of a letter where it sits in a message (in the log, the chat column and
-- speech bubbles), and a word for what it is. A still picture is a framed
-- hill under a sun; an animated one (a gif, an animated webp or png) is the
-- same frame with its sun going round; a Petrichor64 cart is a cartridge.
-- The Android app shows the pictures themselves, and runs carts.
--
-- A link to a post or video on another app (Sosh.Embeds: X, Instagram,
-- Threads, Bluesky, Mastodon, YouTube, TikTok, Reddit, Spotify, Vimeo,
-- SoundCloud) shows the same way, as its own shape: a tile in the app's
-- colour with an arrow out of it (a play mark for a video, which plays on
-- its own app), then the app and what the post is. The
-- apps show the preview itself (`Media.from_embeds` makes one of these
-- from a message's `embeds`, the first of them; a picture or cart wins).
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

LINK_LABEL_MAX = 40 -- letters of a link's title in a line of chat

PROVIDERS = {}
PROVIDERS["x"] = { "X", "1A1A1A" }
PROVIDERS["instagram"] = { "Instagram", "D6297A" }
PROVIDERS["threads"] = { "Threads", "3A3A3A" }
PROVIDERS["bluesky"] = { "Bluesky", "1185FE" }
PROVIDERS["mastodon"] = { "Mastodon", "6364FF" }
PROVIDERS["youtube"] = { "YouTube", "E62117" }
PROVIDERS["tiktok"] = { "TikTok", "111111" }
PROVIDERS["reddit"] = { "Reddit", "FF4500" }
PROVIDERS["spotify"] = { "Spotify", "1DB954" }
PROVIDERS["vimeo"] = { "Vimeo", "1AB7EA" }
PROVIDERS["soundcloud"] = { "SoundCloud", "FF5500" }

-- A message's link previews as a shape for its line, or nil.
function Media.from_embeds(list)
	if list == nil or #list == 0 then
		return nil
	end
	local e = list[1]
	local m = {}
	m.kind = "link"
	m.provider = e.provider
	m.title = e.title or e.text or e.author
	m.author = e.author
	m.url = e.url
	m.video = e.video == true
	m.more = #list - 1
	return m
end

function Media.provider(m)
	return PROVIDERS[m.provider] or { m.provider or "link", "777777" }
end

-- What it's called in a line of chat.
function Media.label(m)
	if m.kind == "link" then
		local p = Media.provider(m)
		local t = p[1]
		local title = m.title
		if title ~= nil then
			local flat = title:gsub("%s+", " ")
			if #flat > LINK_LABEL_MAX then
				flat = flat:sub(1, LINK_LABEL_MAX - 3) .. "..."
			end
			t = t .. ": " .. flat
		elseif m.author ~= nil then
			t = t .. ": " .. m.author
		end
		if m.video then
			t = t .. " (video)"
		end
		if m.more ~= nil and m.more > 0 then
			t = t .. " +" .. tostring(m.more)
		end
		return t
	end
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
	if m.kind == "link" then
		-- a tile in the app's colour, an arrow pointing out of it
		local p = Media.provider(m)
		local w = MEDIA_W
		local h = LH - 2
		gui:rect(x, y, w, h, p[2])
		local n = w - 4
		if h - 4 < n then
			n = h - 4
		end
		if m.video then
			-- a play mark: a triangle pointing right
			local mid = flr(h / 2)
			for i = 0, 3 do
				gui:rect(x + 2 + i, y + mid - 3 + i, 1, 7 - 2 * i, "FFFFFF")
			end
			return
		end
		for i = 0, n - 1 do
			gui:rect(x + 2 + i, y + h - 3 - i, 1, 1, "FFFFFF")
		end
		local tx = x + 2 + n - 1
		local ty = y + h - 3 - (n - 1)
		gui:rect(tx - 2, ty, 3, 1, "FFFFFF")
		gui:rect(tx, ty, 1, 3, "FFFFFF")
		return
	end
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
