-- From sound-chor (scripts/speech.lua at d393db3, branch feat/seq-songs),
-- unchanged but for this header: keep it in step with that one rather than
-- editing it here. voice.lua gives it split() and beats(), and decides who's
-- heard.
--
-- Speech for the singing voice. English text is respelled into the syllables
-- sing() and seq{say=} understand ("hello" -> "heh", "lo"), then either sung
-- on a melody, one syllable per note (lyric), or babbled as quick pitched blips
-- the way Animal Crossing villagers talk (talk).
--
-- The respelling is rules plus a small dictionary (words.lua) for the words the
-- rules get wrong. It's meant to be readable, not phonetically exact: the voice
-- has eight vowels and a handful of consonant noises to work with.

SP = { dict = {}, ready = false }

VOWELS = "aeiouy"

-- Consonant spellings, longest first; what each turns into for the voice.
CONS_SPELL = {
	{ "tch", "ch" }, { "sch", "sk" },
	{ "ch", "ch" }, { "sh", "sh" }, { "th", "th" }, { "ph", "f" }, { "wh", "w" },
	{ "ck", "k" }, { "ng", "ng" }, { "gh", "" }, { "dg", "j" },
}
-- Vowel spellings, longest first.
VOW_SPELL = {
	{ "eigh", "ei" }, { "ough", "o" }, { "augh", "ah" },
	{ "igh", "ai" }, { "eau", "o" },
	{ "ee", "ee" }, { "ea", "ee" }, { "ai", "ei" }, { "ay", "ei" }, { "oa", "o" },
	{ "oe", "o" }, { "oo", "oo" }, { "ou", "au" }, { "ow", "au" }, { "oi", "oi" },
	{ "oy", "oi" }, { "au", "ah" }, { "aw", "ah" }, { "ew", "oo" }, { "ue", "oo" },
	{ "ie", "ee" }, { "ey", "ei" }, { "ei", "ei" },
}
SHORT = { a = "ae", e = "eh", i = "ih", o = "ah", u = "uh", y = "ih" }
LONG = { a = "ei", e = "ee", i = "ai", o = "o", u = "oo", y = "ai" }
-- Two consonants that start a syllable together ("a-pron", "mi-stake").
ONSET2 = {
	bl = true, br = true, kl = true, kr = true, dr = true, fl = true, fr = true,
	gl = true, gr = true, pl = true, pr = true, tr = true, sk = true, sl = true,
	sm = true, sn = true, sp = true, st = true, sw = true, kw = true, thr = true,
	shr = true,
}
-- Letter names, for talk{letters=true}: real Animalese reads out a word's
-- letters, sped up.
LETTERS = {
	a = "ei", b = "bee", c = "see", d = "dee", e = "ee", f = "ehf", g = "jee",
	h = "eich", i = "ai", j = "jei", k = "kei", l = "ehl", m = "ehm", n = "ehn",
	o = "o", p = "pee", q = "kyoo", r = "ar", s = "ehs", t = "tee", u = "yoo",
	v = "vee", w = "duh", x = "ehks", y = "wai", z = "zee",
}

function speech_init()
	if SP.ready then
		return
	end
	SP.ready = true
	local src = WORDS_SRC
	local i = 1
	local len = #src
	while i <= len do
		local a, b = string.find(src, "[^|]+", i)
		if a == nil then
			break
		end
		local entry = string.sub(src, a, b)
		local c = string.find(entry, ":", 1, true)
		if c ~= nil then
			local w = string.sub(entry, 1, c - 1)
			local syl = string.sub(entry, c + 1)
			SP.dict[w] = syl
		end
		i = b + 1
	end
end

function is_vowel(ch)
	if ch == "" then
		return false
	end
	local at = string.find(VOWELS, ch, 1, true)
	return at ~= nil
end

-- Does the word have a vowel letter anywhere but position `skip`?
function other_vowel(w, skip)
	for i = 1, #w do
		local ch = string.sub(w, i, i)
		if i ~= skip and is_vowel(ch) then
			return true
		end
	end
	return false
end

-- The first entry of `list` whose spelling starts at position i of w.
function spelled_at(w, i, list)
	for k = 1, #list do
		local pair = list[k]
		local sp = pair[1]
		local j = i + #sp - 1
		local piece = string.sub(w, i, j)
		if piece == sp then
			return pair
		end
	end
	return nil
end

-- Is the vowel at i lengthened by a silent e after one consonant? ("make",
-- "makes", "timed"; not "the", whose e is the vowel itself.)
function magic_e(w, i)
	local len = #w
	local ch = string.sub(w, i, i)
	local nx = string.sub(w, i + 1, i + 1)
	local nx2 = string.sub(w, i + 2, i + 2)
	if not is_vowel(ch) or is_vowel(nx) or nx == "" or nx2 ~= "e" then
		return false
	end
	if i + 2 == len then
		return true
	end
	local tail = string.sub(w, i + 3)
	return i + 3 == len and (tail == "s" or tail == "d")
end

-- One word (lower case letters) as a token list: {v = true/false, s = sound}.
function phonemes(w)
	local toks = {}
	local n = 0
	local len = #w
	local i = 1
	local last = ""
	while i <= len do
		local ch = string.sub(w, i, i)
		local nx = string.sub(w, i + 1, i + 1)
		local nx2 = string.sub(w, i + 2, i + 2)
		local back2 = i - 2
		local last_v = ""
		if back2 >= 1 and magic_e(w, back2) then
			last_v = string.sub(w, back2, back2)
		end
		local vow = spelled_at(w, i, VOW_SPELL)
		local con = spelled_at(w, i, CONS_SPELL)
		local tok = nil
		local step = 1
		-- y starts a word as a consonant ("yes"); elsewhere it's a vowel.
		local y_cons = ch == "y" and (i == 1 or is_vowel(nx))
		if vow ~= nil and not y_cons then
			tok = { v = true, s = vow[2] }
			step = #vow[1]
		elseif con ~= nil then
			if con[2] ~= "" then
				tok = { v = false, s = con[2] }
			end
			step = #con[1]
		elseif is_vowel(ch) and not y_cons then
			local snd = SHORT[ch]
			local after_r = nx == "r" and not is_vowel(nx2)
			local tail = string.sub(w, i + 1)
			if ch == "e" and i == len and other_vowel(w, i) then
				snd = "" -- silent final e
			elseif ch == "e" and i == len - 1 and (tail == "s" or tail == "d") and is_vowel(last_v) then
				-- makes, timed: the e after a magic-e vowel stays silent; and a
				-- plain -ed only sounds after t/d (wanted), else it's just "d".
				snd = ""
			elseif ch == "e" and tail == "d" and i == len - 1 and last ~= "t" and last ~= "d" and i > 2 then
				snd = ""
			elseif i == len then
				snd = LONG[ch]
				if ch == "y" and other_vowel(w, i) then
					snd = "ee" -- happy, city
				elseif ch == "a" then
					snd = "ah"
				end
			elseif after_r and ch == "a" then
				snd = "ah" -- car, park
			elseif after_r and ch == "o" then
				snd = "o" -- for, born
			elseif magic_e(w, i) then
				snd = LONG[ch] -- magic e: make, time, home, makes
			elseif not is_vowel(nx) and is_vowel(nx2) and nx2 ~= "e" then
				-- An open syllable: a/o/u go long ("pa-per", "o-ver"),
				-- e/i mostly stay short ("ne-ver", "ri-ver").
				if ch == "a" or ch == "o" or ch == "u" then
					snd = LONG[ch]
				end
			end
			if snd ~= "" then
				tok = { v = true, s = snd }
			end
		else
			local snd = ch
			if ch == "c" then
				snd = "k"
				if nx == "e" or nx == "i" or nx == "y" then
					snd = "s"
				end
			elseif ch == "q" then
				snd = "k"
			elseif ch == "x" then
				snd = "ks"
			elseif ch == "g" and nx == "e" and i + 1 == len then
				snd = "j" -- page, change
			end
			-- "-le" after a consonant is its own syllable: lit-tle, peo-ple.
			if ch == "l" and nx == "e" and i + 1 == len and n > 0 and not toks[n].v then
				n = n + 1
				local uh = { v = true, s = "uh" }
				toks[n] = uh
			end
			-- Doubled letters sound once (tt, ll, ss).
			if snd ~= last then
				tok = { v = false, s = snd }
			end
			if ch == "q" and nx == "u" then
				n = n + 1
				toks[n] = tok
				tok = { v = false, s = "w" }
				step = 2
			end
		end
		if tok ~= nil then
			n = n + 1
			toks[n] = tok
			last = tok.s
		end
		if tok == nil or tok.v then
			last = ""
		end
		i = i + step
	end
	return toks
end

-- Group tokens into syllables around each vowel. Between two vowels a single
-- consonant starts the next syllable; of several, the first closes this one and
-- the rest start the next, unless the last two make a good onset together.
function syllabify(toks)
	local nuc = {}
	local nn = 0
	for i = 1, #toks do
		local t = toks[i]
		if t.v then
			nn = nn + 1
			nuc[nn] = i
		end
	end
	local out = {}
	if nn == 0 then
		local s = ""
		for i = 1, #toks do
			local t = toks[i]
			s = s .. t.s
		end
		if s ~= "" then
			local one = { s = s, v = "uh" }
			out[1] = one
		end
		return out
	end
	-- Where each syllable's onset starts.
	local starts = {}
	starts[1] = 1
	for k = 2, nn do
		local a = nuc[k - 1]
		local b = nuc[k]
		local run = b - a - 1
		local cut = b
		if run == 1 then
			cut = b - 1
		elseif run >= 2 then
			cut = a + 2
			local t1 = toks[b - 2]
			local t2 = toks[b - 1]
			local pair = t1.s .. t2.s
			if ONSET2[pair] == true then
				cut = b - 2
			end
		end
		starts[k] = cut
	end
	for k = 1, nn do
		local from = starts[k]
		local to = #toks
		if k < nn then
			to = starts[k + 1] - 1
		end
		local s = ""
		for i = from, to do
			local t = toks[i]
			s = s .. t.s
		end
		local vt = toks[nuc[k]]
		local syl = { s = s, v = vt.s }
		out[k] = syl
	end
	return out
end

-- A word's syllables, from the dictionary or the rules.
function word_syllables(w)
	speech_init()
	local d = SP.dict[w]
	if d ~= nil then
		local parts = split(d)
		local out = {}
		for i = 1, #parts do
			local p = parts[i]
			local syl = { s = p, v = p }
			out[i] = syl
		end
		return out
	end
	local toks = phonemes(w)
	return syllabify(toks)
end

-- Text as a flat list of units: {s = syllable, v = its vowel, word = n,
-- first = starts a word} and, after a word followed by punctuation, a pause
-- unit {pause = secs, mark = "," / "." / "?" / "!"}.
function speech_units(text)
	local low = string.lower(text)
	local out = {}
	local n = 0
	local word = ""
	local wn = 0
	local len = #low
	for i = 1, len + 1 do
		local ch = " "
		if i <= len then
			ch = string.sub(low, i, i)
		end
		local letter = string.find("abcdefghijklmnopqrstuvwxyz", ch, 1, true)
		if letter ~= nil then
			word = word .. ch
		elseif ch ~= "'" then
			if word ~= "" then
				wn = wn + 1
				local syls = word_syllables(word)
				for k = 1, #syls do
					local sy = syls[k]
					n = n + 1
					local u = { s = sy.s, v = sy.v, word = wn, first = k == 1, text = word }
					out[n] = u
				end
				word = ""
			end
			local pause = 0
			if ch == "," or ch == ";" or ch == ":" then
				pause = 0.18
			elseif ch == "." or ch == "!" or ch == "?" then
				pause = 0.34
			elseif ch == "-" then
				pause = 0.08
			end
			if pause > 0 then
				n = n + 1
				local p = { pause = pause, mark = ch }
				out[n] = p
			end
		end
	end
	return out
end

-- Put lyrics on a melody: syllable k on the k-th sounding note of `steps`
-- (from melody()). "_" in the text holds the last vowel over one more note (a
-- melisma); notes past the end of the words hold it too. Returns new steps.
function lyric(text, steps)
	local units = speech_units(text)
	local syl = {}
	local ns = 0
	for i = 1, #units do
		local u = units[i]
		if u.pause == nil then
			ns = ns + 1
			syl[ns] = u.s
		end
	end
	-- "_" isn't a letter, so speech_units drops it: find them in the raw text.
	local holds = split(text)
	local out = {}
	local k = 0
	local hold_v = "a"
	local tok = 0
	for i = 1, #steps do
		local st = steps[i]
		local copy = { st[1], st[2], st[3], st[4], len = st.len, at = st.at }
		if st[2] ~= 0 then
			tok = tok + 1
			local raw = holds[tok]
			if raw == "_" or k >= ns then
				copy.say = hold_v
			else
				k = k + 1
				local s = syl[k]
				copy.say = s
				hold_v = vowel_of(s)
			end
		end
		out[i] = copy
	end
	return out
end

-- The vowel part of a respelled syllable ("feel" -> "ee"), for held notes.
function vowel_of(s)
	local a, b = string.find(s, "[aeiou]+h?")
	if a == nil then
		return "a"
	end
	return string.sub(s, a, b)
end

-- Voices for talk(): base pitch (Hz), speed, and how far each blip wanders.
VOICES = {
	peppy = { pitch = 520, rate = 1.25, wobble = 0.22, breath = 0.05 },
	normal = { pitch = 330, rate = 1.0, wobble = 0.16, breath = 0.08 },
	lazy = { pitch = 180, rate = 0.75, wobble = 0.12, breath = 0.15 },
	cranky = { pitch = 130, rate = 0.9, wobble = 0.1, breath = 0.2 },
	robot = { pitch = 220, rate = 1.0, wobble = 0, breath = 0 },
}

-- Babble `text` the way Animal Crossing villagers talk: every syllable a short
-- sung blip at a pitch that wanders around the voice's, drifting down through
-- a sentence, rising at a "?", up and louder at a "!". cfg (all optional):
--   voice = "peppy"/"normal"/"lazy"/"cranky"/"robot", or pitch/rate/wobble
--   letters = true  read each word's letters instead (true Animalese)
--   ch = 8, id = 90  the channel and seq id it speaks on
-- Runs on seq(), so it keeps time with a song and a second talk() waits for
-- the first to finish. Returns how many seconds it'll take.
function talk(text, cfg)
	local c = cfg or {}
	local vname = c.voice or "normal"
	local v = VOICES[vname] or VOICES.normal
	local pitch = c.pitch or v.pitch
	local rate = c.rate or v.rate
	local wob = c.wobble or v.wobble
	local ch = c.ch or 8
	local id = c.id or 90
	local vx = { breath = v.breath, vib = 0 }
	vox(ch, vx)
	local units = speech_units(text)
	if c.letters == true then
		units = letter_units(units)
	end
	local blip = 0.085 / rate
	if c.letters == true then
		blip = 0.055 / rate
	end
	local steps = {}
	local n = 0
	local secs = 0
	local sentence = 0 -- syllables into the current sentence
	local sent_start = 1
	local shout = 1
	for i = 1, #units do
		local u = units[i]
		if u.pause ~= nil then
			local p = u.pause / rate
			n = n + 1
			local bt = beats(p)
			local rest = { bt, 0 }
			steps[n] = rest
			secs = secs + p
			if u.mark == "?" then
				-- A question lifts its last two syllables.
				lift(steps, n - 1, 1.35)
				lift(steps, n - 2, 1.15)
			elseif u.mark == "!" then
				for k = sent_start, n - 1 do
					lift(steps, k, 1.12)
				end
			end
			if u.mark == "." or u.mark == "?" or u.mark == "!" then
				sentence = 0
				sent_start = n + 1
			end
		else
			sentence = sentence + 1
			local r = rnd()
			local jig = 1 + (r * 2 - 1) * wob
			local fall = 1 - sentence * 0.012
			if fall < 0.8 then
				fall = 0.8
			end
			-- Each word's first syllable sits a touch higher: a little stress.
			local stress = 1
			if u.first then
				stress = 1.05
			end
			local f = pitch * jig * fall * stress
			local len = blip
			if u.first == false then
				len = blip * 0.9
			end
			local bt = beats(len)
			-- Held nearly the whole slot: the engine carries the voice from one
			-- syllable into the next while it's still sounding, so a phrase
			-- runs together instead of beeping.
			local hold = beats(len * 0.92)
			n = n + 1
			local st = { bt, f, 0, 0.9, say = u.s, len = hold }
			steps[n] = st
			secs = secs + len
			-- A hair of space between words (punctuation pauses are longer).
			local nxt = units[i + 1]
			if nxt ~= nil and nxt.first == true then
				local gap = 0.01 / rate
				n = n + 1
				local gb = beats(gap)
				local g = { gb, 0 }
				steps[n] = g
				secs = secs + gap
			end
		end
	end
	if n == 0 then
		return 0
	end
	local scfg = { ch = ch }
	seq(id, steps, scfg)
	return secs
end

-- Raise step k's pitch by `by`, if it's a sounding note.
function lift(steps, k, by)
	if k < 1 then
		return
	end
	local st = steps[k]
	if st == nil or st[2] == 0 then
		return
	end
	st[2] = st[2] * by
	st[4] = 1
end

-- Words as their letter names: "hi" -> "eich", "ai".
function letter_units(units)
	local out = {}
	local n = 0
	local lastw = 0
	for i = 1, #units do
		local u = units[i]
		if u.pause ~= nil then
			n = n + 1
			out[n] = u
		elseif u.word ~= lastw then
			lastw = u.word
			local w = u.text
			for k = 1, #w do
				local ch = string.sub(w, k, k)
				local s = LETTERS[ch]
				if s ~= nil then
					n = n + 1
					local lu = { s = s, v = s, word = u.word, first = k == 1 }
					out[n] = lu
				end
			end
		end
	end
	return out
end

-- Print how text respells, for checking the rules: "hello world" ->
-- "heh.lo werld".
function respell(text)
	local units = speech_units(text)
	local s = ""
	for i = 1, #units do
		local u = units[i]
		if u.pause ~= nil then
			s = s .. u.mark
		else
			if u.first and s ~= "" then
				s = s .. " "
			elseif not u.first then
				s = s .. "."
			end
			s = s .. u.s
		end
	end
	return s
end
