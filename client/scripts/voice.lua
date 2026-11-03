-- voice — chat read aloud, the way Animal Crossing villagers talk.
--
-- What someone says in the world (a room's `new_msg`) is babbled by
-- speech.lua's talk() in that player's voice, if we're near enough to hear
-- it: full volume within VOICE_NEAR tiles, fading out to nothing at
-- VOICE_FAR, and kept in step with the distance while they talk, so walking
-- away from someone trails off. Our own lines are heard at full volume.
--
-- A handful of channels are speakers (VOICE_CHANNELS): a player keeps theirs
-- while they're talking, so a second line waits for the first (talk() queues
-- on the same seq id); when all are busy, the farthest speaker gives theirs
-- up. Each player's voice (pitch, pace) comes from their id, so it's the same
-- on every client.

Voice = {}
Voice.slots = {}

VOICE_NEAR = 4 -- tiles: full volume this close
VOICE_FAR = 16 -- and silent this far
VOICE_CHANNELS = { 8, 9, 10, 11 }
VOICE_SEQ = 90 -- slot i talks on seq id VOICE_SEQ + i
VOICE_MAX = 140 -- characters of a line that get read out
VOICE_BPM = 120
VOICE_KINDS = { "peppy", "normal", "lazy", "cranky" }
VOICE_STEP = 0.1 -- seconds between volume updates
VOICE_PACE = 0.8 -- of sound-chor's talking speed: chat reads slower

-- speech.lua's helpers from sound-chor's music.lua: words on spaces, and
-- seconds as beats at the tempo talk() is counted against.
function split(s)
	local out = {}
	local n = 0
	local i = 1
	local len = #s
	while i <= len do
		local a, b = string.find(s, "[^ ]+", i)
		if a == nil then
			break
		end
		n = n + 1
		out[n] = string.sub(s, a, b)
		i = b + 1
	end
	return out
end

function beats(secs)
	return secs * VOICE_BPM / 60
end

function Voice.init()
	bpm(VOICE_BPM)
	Voice.slots = {}
	for i = 1, #VOICE_CHANNELS do
		local s = {}
		s.ch = VOICE_CHANNELS[i]
		s.id = VOICE_SEQ + i
		s.who = nil
		s.till = 0
		Voice.slots[i] = s
	end
	Voice.tick = 0
end

-- A player's voice from their id: a kind and a pitch a little off its own.
function Voice.of(id)
	local h = 7
	for i = 1, #id do
		h = (h * 31 + id:byte(i)) % 1000003
	end
	local kind = VOICE_KINDS[(h % #VOICE_KINDS) + 1]
	local v = VOICES[kind]
	local cfg = {}
	cfg.voice = kind
	cfg.pitch = v.pitch * (0.9 + (flr(h / 7) % 21) / 100)
	cfg.rate = v.rate * VOICE_PACE
	return cfg
end

-- How loud someone `d` tiles away is.
function Voice.volume(d)
	if d <= VOICE_NEAR then
		return 1
	end
	local t = 1 - (d - VOICE_NEAR) / (VOICE_FAR - VOICE_NEAR)
	if t <= 0 then
		return 0
	end
	return t * t
end

-- How far avatar `av` is from us (0 for us).
function Voice.dist(av)
	local me = APP.me
	if me == nil or av == me then
		return 0
	end
	local dx = av.bx - me.bx
	local dy = av.by - me.by
	local dz = av.z - me.z
	return sqrt(dx * dx + dy * dy + dz * dz)
end

-- `av` said `text`: read it out if we can hear them.
function Voice.say(av, text)
	if av == nil or text == nil then
		return
	end
	local d = Voice.dist(av)
	if d >= VOICE_FAR then
		return
	end
	local s = Voice.slot_for(av.id, d)
	if s == nil then
		return
	end
	if #text > VOICE_MAX then
		text = string.sub(text, 1, VOICE_MAX)
	end
	local cfg = Voice.of(av.id)
	cfg.ch = s.ch
	cfg.id = s.id
	fade(s.ch, 0.02, Voice.volume(d))
	local secs = talk(text, cfg)
	local start = U.clock
	if s.who == av.id and s.till > start then
		start = s.till -- queued behind their last line
	end
	s.who = av.id
	s.till = start + secs + 0.2
end

-- A speaker for `id`: theirs if they're talking, else a free one, else the
-- farthest one's if that's farther than `d`.
function Voice.slot_for(id, d)
	local free = nil
	local far = nil
	local far_d = d
	for i = 1, #Voice.slots do
		local s = Voice.slots[i]
		if s.who == id then
			return s
		end
		if s.who == nil then
			if free == nil then
				free = s
			end
		else
			local sd = VOICE_FAR
			local av = avatar_of(s.who)
			if av ~= nil then
				sd = Voice.dist(av)
			end
			if sd > far_d then
				far = s
				far_d = sd
			end
		end
	end
	if free ~= nil then
		return free
	end
	if far ~= nil then
		seq(far.id) -- cut them off
		mute(far.ch)
		far.who = nil
	end
	return far
end

-- Once a frame: each speaker's volume follows how far they are now, and a
-- speaker who's finished (or gone) frees their channel.
function Voice.update(dt)
	Voice.tick = Voice.tick - dt
	if Voice.tick > 0 then
		return
	end
	Voice.tick = VOICE_STEP
	for i = 1, #Voice.slots do
		local s = Voice.slots[i]
		if s.who ~= nil then
			local av = avatar_of(s.who)
			if av == nil then
				seq(s.id)
				mute(s.ch)
				s.who = nil
			elseif U.clock > s.till then
				s.who = nil
			else
				fade(s.ch, VOICE_STEP, Voice.volume(Voice.dist(av)))
			end
		end
	end
end
