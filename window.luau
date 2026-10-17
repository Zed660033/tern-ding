--!strict
-- Window half: plays a ding when an agent finishes a turn or needs you, a shell
-- command fails, a long command ends, or a pane raises an unseen alert.

local DIR = tern.plugin.dir
local DATA = tern.plugin.data
local CONFIG_PATH = DATA .. "/config.json"
local SOUNDS = DIR .. "/sounds"

local TICK_MS = 300
local MIN_GAP_TICKS = 2
local CLAIM_WINDOW_S = 2
local QUEUE_MAX = 6
local CONFIG_EVERY_TICKS = 20

local TRIGGERS = { "done", "question", "error", "alert", "longrun" }

local DEFAULTS: { [string]: any } = {
	muted = false,
	only_unfocused = true,
	min_seconds = 30,
	sounds = {
		done = "ding",
		question = "ding",
		error = "ding",
		alert = "ding",
		longrun = "ding",
	},
}

local config: { [string]: any } = DEFAULTS
local queue: { { trigger: string, path: string } } = {}
local playing = false
local linux_player: string? = nil
local ticks = 0
local gap_ticks = 0
local seeded = false
local agent_state: { [number]: string } = {}
local pane_alert: { [number]: boolean } = {}

local function write_config(cfg: { [string]: any })
	if not tern.fs.exists(DATA) then
		tern.fs.mkdir(DATA)
	end
	tern.fs.write(CONFIG_PATH, tern.json.encode(cfg, true) .. "\n")
end

local function load_config(): { [string]: any }
	local sounds = table.clone(DEFAULTS.sounds :: { [string]: any })
	local merged: { [string]: any } = {
		muted = DEFAULTS.muted,
		only_unfocused = DEFAULTS.only_unfocused,
		min_seconds = DEFAULTS.min_seconds,
		sounds = sounds,
	}
	if not tern.fs.exists(CONFIG_PATH) then
		write_config(merged)
		return merged
	end
	local ok, raw = pcall(function(): any
		return tern.json.decode(tern.fs.read(CONFIG_PATH, 64 * 1024))
	end)
	if not ok or type(raw) ~= "table" then
		tern.log.warn("config.json is not valid JSON, using defaults:", tostring(raw))
		return merged
	end
	local decoded = raw :: { [string]: any }
	if type(decoded.muted) == "boolean" then
		merged.muted = decoded.muted
	end
	if type(decoded.only_unfocused) == "boolean" then
		merged.only_unfocused = decoded.only_unfocused
	end
	local secs = decoded.min_seconds
	if type(secs) == "number" and secs >= 0 then
		merged.min_seconds = secs
	end
	if type(decoded.sounds) == "table" then
		local given = decoded.sounds :: { [string]: any }
		for _, trigger in TRIGGERS do
			if type(given[trigger]) == "string" then
				sounds[trigger] = given[trigger]
			end
		end
	end
	return merged
end

local function sound_id(trigger: string): string?
	local id = (config.sounds :: { [string]: any })[trigger]
	return if type(id) == "string" and id ~= "" then id else nil
end

local function player_argv(path: string): { string }?
	local os_name = tern.runtime.os
	if os_name == "windows" then
		-- wscript is a windowless host, so the SoundPlayer behind it flashes no console.
		return { "wscript.exe", "//Nologo", DIR .. "\\scripts\\play.vbs", path }
	end
	if os_name == "macos" then
		return { "afplay", path }
	end
	local player = linux_player
	if os_name == "linux" and player ~= nil then
		if player == "ffplay" then
			return { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path }
		end
		return { player, path }
	end
	return nil
end

local function play_next()
	if playing then
		return
	end
	local item = table.remove(queue, 1)
	if item == nil then
		return
	end
	local argv = player_argv(item.path)
	if argv == nil then
		tern.log.warn("no audio player for", tern.runtime.os)
		return
	end
	playing = true
	tern.log.info("play", item.trigger, item.path)
	tern.process.run(argv, { timeout_ms = 15000 }, function(result: ProcessResult)
		playing = false
		if result.status ~= 0 then
			tern.log.warn("player exited", result.status, result.stderr)
		end
		play_next()
	end)
end

local function enqueue(trigger: string, path: string)
	if #queue >= QUEUE_MAX then
		return
	end
	table.insert(queue, { trigger = trigger, path = path })
	play_next()
end

local function claim(trigger: string, pane: number): boolean
	local key = trigger .. ":" .. tostring(pane)
	local now = os.time()
	local ok, last = pcall(tern.kv.get, "claim")
	if ok and type(last) == "table" then
		local record = last :: { [string]: any }
		if record.k == key and type(record.t) == "number" and now - (record.t :: number) < CLAIM_WINDOW_S then
			return false
		end
	end
	tern.kv.set("claim", { k = key, t = now })
	return true
end

local function chime(trigger: string, pane: number, focused: boolean)
	if config.muted == true or gap_ticks > 0 then
		return
	end
	if config.only_unfocused == true and focused then
		return
	end
	local id = sound_id(trigger)
	if id == nil then
		return
	end
	local path = SOUNDS .. "/" .. id .. ".wav"
	if not tern.fs.exists(path) then
		tern.log.warn("no such sound:", id)
		return
	end
	if not claim(trigger, pane) then
		return
	end
	gap_ticks = MIN_GAP_TICKS
	enqueue(trigger, path)
end

local function focused_pane(cx: WindowCx, pane: number): boolean
	for _, info in cx.session:panes() do
		if info.pane == pane then
			return info.focused == true
		end
	end
	return false
end

local function tick_body(cx: WindowCx)
	ticks += 1
	if ticks % CONFIG_EVERY_TICKS == 0 then
		config = load_config()
	end
	if gap_ticks > 0 then
		gap_ticks -= 1
	end

	local focused: { [number]: boolean } = {}
	local alerts: { [number]: boolean } = {}
	local candidate: { [number]: string } = {}
	for _, info in cx.session:panes() do
		local id = info.pane
		local alerted = info.alert == true
		focused[id] = info.focused == true
		alerts[id] = alerted
		if seeded and alerted and not pane_alert[id] then
			candidate[id] = "alert"
		end
	end
	pane_alert = alerts

	local states: { [number]: string } = {}
	for _, agent in cx.agents:list() do
		local id = agent.pane
		states[id] = agent.state
		if agent_state[id] == "working" and (agent.state == "idle" or agent.state == "waiting_input") then
			-- Tern reports a question and a permission prompt the same way.
			if candidate[id] == nil then
				candidate[id] = if agent.state == "waiting_input" then "question" else "done"
			end
		end
	end
	agent_state = states

	for id, trigger in candidate do
		chime(trigger, id, focused[id] == true)
	end
	seeded = true
end

local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	if cx == nil then
		return
	end
	local ok, err = pcall(tick_body, cx :: WindowCx)
	if not ok then
		tern.log.warn("tick failed:", tostring(err))
	end
end

config = load_config()

-- The window entry can run after `window_start`; the loop would never arm.
tern.timer(TICK_MS, tick)

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	if ev.status ~= 0 then
		chime("error", ev.pane, focused_pane(cx, ev.pane))
	elseif ev.took_ms >= (config.min_seconds :: number) * 1000 then
		chime("longrun", ev.pane, focused_pane(cx, ev.pane))
	end
end)

tern.on("window_start", function(cx: WindowCx)
	if tern.runtime.os == "linux" then
		tern.process.run(
			{ "sh", "-c", "for p in paplay aplay ffplay; do command -v $p >/dev/null 2>&1 && { echo $p; exit 0; }; done" },
			function(result: ProcessResult)
				local name = string.match(result.stdout, "^%s*(%S+)")
				if name == nil then
					tern.log.warn("no audio player found; install pipewire-bin, alsa-utils or ffmpeg")
				end
				linux_player = name
			end
		)
	end
end)

tern.command({
	id = "mute",
	title = "Notify sounds: mute or unmute",
	icon = "bell",
	run = function(cx: WindowCx)
		config.muted = not (config.muted == true)
		write_config(config)
		cx:toast("info", "Notify sounds", if config.muted == true then "muted" else "unmuted")
	end,
})

tern.command({
	id = "background",
	title = "Notify sounds: background only",
	icon = "eye-off",
	run = function(cx: WindowCx)
		config.only_unfocused = not (config.only_unfocused == true)
		write_config(config)
		cx:toast("info", "Notify sounds", if config.only_unfocused == true then "background only" else "always")
	end,
})

tern.command({
	id = "test",
	title = "Notify sounds: play every trigger",
	icon = "bell",
	run = function(cx: WindowCx)
		local played = 0
		local heard: { [string]: boolean } = {}
		for _, trigger in TRIGGERS do
			local id = sound_id(trigger)
			if id ~= nil and heard[id] ~= true then
				local path = SOUNDS .. "/" .. id .. ".wav"
				if tern.fs.exists(path) then
					heard[id] = true
					enqueue(trigger, path)
					played += 1
				end
			end
		end
		cx:toast("info", "Notify sounds", "playing " .. tostring(played) .. (if played == 1 then " sound" else " sounds"))
	end,
})

tern.command({
	id = "reload",
	title = "Notify sounds: reload config",
	icon = "refresh",
	run = function(cx: WindowCx)
		config = load_config()
		cx:toast("info", "Notify sounds", "config reloaded")
	end,
})

tern.command({
	id = "config",
	title = "Notify sounds: open config",
	icon = "settings",
	run = function(cx: WindowCx)
		if not tern.fs.exists(CONFIG_PATH) then
			write_config(config)
		end
		cx:open(CONFIG_PATH)
	end,
})
