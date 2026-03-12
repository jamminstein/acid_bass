-- acid_bass
-- norns + grid acid bass line generator
--
-- grid layout:
-- [1,1]  tap tempo
-- [1,2]  generate new acid bass line
-- row 2  octave (cols 1-4)
-- row 3  gate length (cols 1-8: short → long)
-- row 4  swing amount (cols 1-8)
-- row 5  filter cutoff (cols 1-8)
-- row 6  accent probability (cols 1-8)
-- row 7  slide probability (cols 1-8)
-- row 8  step mute toggles (cols 1-16)

engine.name = "PolyPerc"

local g = grid.connect()
local MusicUtil = require "musicutil"

-- ─── state ───────────────────────────────────────────────────────────────────────
local SEQ_LEN = 16
local seq = {}          -- {note, vel, slide, accent, active}
local step = 1

local bpm = 120
local tap_times = {}
local TAP_RESET = 2.0   -- seconds before tap resets

local octave = 2        -- 1-4
local gate_len = 0.5    -- 0.1–0.9
local swing = 0         -- 0–0.5 (added to even steps)
local cutoff = 800
local accent_prob = 0.3
local slide_prob  = 0.2

-- grid LED brightness
local BRI = { dim = 3, mid = 8, hi = 15 }

-- ─── acid generator ──────────────────────────────────────────────────────────
local ACID_ROOTS = {36, 38, 40, 41, 43, 45, 47}  -- C D E F G A B (bass octave)

local function rand_acid_note()
  local root = ACID_ROOTS[math.random(#ACID_ROOTS)] + (octave - 1) * 12
  local intervals = {0, 0, 0, 7, 12, -12, 5, 3, 10}
  return root + intervals[math.random(#intervals)]
end

local function generate_bass_line()
  seq = {}
  for i = 1, SEQ_LEN do
    local active = math.random() < 0.75
    seq[i] = {
      note    = rand_acid_note(),
      vel     = active and (math.random() < accent_prob and 1.0 or 0.6) or 0,
      accent  = math.random() < accent_prob,
      slide   = math.random() < slide_prob,
      active  = active,
    }
  end
  print("acid bass line generated")
end

-- ─── sequencer clock ─────────────────────────────────────────────────────────
local function step_duration()
  return 60 / bpm / 4  -- 16th notes
end

local seq_clock

local function play_step()
  local s = seq[step]
  if s and s.active then
    local hz = MusicUtil.note_num_to_freq(s.note)
    local cf = cutoff * (s.accent and 2 or 1)
    engine.cutoff(math.min(cf, 8000))
    engine.release(gate_len * step_duration())
    engine.amp(s.vel)
    engine.hz(hz)
  end
  step = (step % SEQ_LEN) + 1
  redraw()
  grid_redraw()
end

local function start_clock()
  if seq_clock then clock.cancel(seq_clock) end
  seq_clock = clock.run(function()
    while true do
      local dur = step_duration()
      local sw  = (step % 2 == 0) and (swing * dur) or 0
      clock.sleep(dur + sw)
      play_step()
    end
  end)
end

-- ─── tap tempo ───────────────────────────────────────────────────────────────
local function tap_tempo()
  local now = util.time()
  -- flush old taps
  local fresh = {}
  for _, t in ipairs(tap_times) do
    if now - t < TAP_RESET then table.insert(fresh, t) end
  end
  tap_times = fresh
  table.insert(tap_times, now)

  if #tap_times >= 2 then
    local intervals = {}
    for i = 2, #tap_times do
      table.insert(intervals, tap_times[i] - tap_times[i-1])
    end
    local avg = 0
    for _, v in ipairs(intervals) do avg = avg + v end
    avg = avg / #intervals
    bpm = math.floor(60 / avg + 0.5)
    bpm = util.clamp(bpm, 40, 300)
    params:set("bpm", bpm)
    print("tap bpm: " .. bpm)
    start_clock()
  end
end

-- ─── grid ────────────────────────────────────────────────────────────────────
local muted = {}
for i = 1, SEQ_LEN do muted[i] = false end

local function grid_redraw()
  if not g then return end
  g:all(0)

  -- row 1: tap tempo (col1), generate (col2)
  g:led(1, 1, BRI.hi)
  g:led(2, 1, BRI.mid)

  -- row 2: octave (cols 1-4)
  for c = 1, 4 do
    g:led(c, 2, c == octave and BRI.hi or BRI.dim)
  end

  -- row 3: gate length (cols 1-8, 0.1–0.9)
  local gate_idx = math.floor((gate_len - 0.1) / 0.8 * 7 + 1.5)
  for c = 1, 8 do
    g:led(c, 3, c == gate_idx and BRI.hi or BRI.dim)
  end

  -- row 4: swing (cols 1-8)
  local sw_idx = math.floor(swing / 0.5 * 7 + 1.5)
  for c = 1, 8 do
    g:led(c, 4, c == sw_idx and BRI.hi or BRI.dim)
  end

  -- row 5: filter cutoff (cols 1-8, 200–8000 log)
  local cf_norm = (math.log(cutoff) - math.log(200)) / (math.log(8000) - math.log(200))
  local cf_idx  = math.floor(cf_norm * 7 + 1.5)
  for c = 1, 8 do
    g:led(c, 5, c == cf_idx and BRI.hi or BRI.dim)
  end

  -- row 6: accent probability (cols 1-8)
  local ac_idx = math.floor(accent_prob / 1.0 * 7 + 1.5)
  for c = 1, 8 do
    g:led(c, 6, c == ac_idx and BRI.hi or BRI.dim)
  end

  -- row 7: slide probability
  local sl_idx = math.floor(slide_prob / 1.0 * 7 + 1.5)
  for c = 1, 8 do
    g:led(c, 7, c == sl_idx and BRI.hi or BRI.dim)
  end

  -- row 8: step mutes / playhead
  for c = 1, SEQ_LEN do
    local on_step = (c == step)
    local mute    = muted[c]
    local bri = on_step and BRI.hi or (mute and BRI.dim or BRI.mid)
    g:led(c, 8, bri)
  end

  g:refresh()
end

g.key = function(x, y, z)
  if z == 0 then return end  -- key up, ignore

  if y == 1 then
    if x == 1 then tap_tempo()
    elseif x == 2 then
      generate_bass_line()
      -- re-apply mutes
      for i = 1, SEQ_LEN do
        if muted[i] then seq[i].active = false end
      end
    end

  elseif y == 2 then  -- octave
    if x <= 4 then
      octave = x
      -- retune existing seq
      for i = 1, SEQ_LEN do
        seq[i].note = rand_acid_note()
      end
    end

  elseif y == 3 then  -- gate length
    gate_len = util.linlin(1, 8, 0.1, 0.9, x)

  elseif y == 4 then  -- swing
    swing = util.linlin(1, 8, 0, 0.45, x)

  elseif y == 5 then  -- filter cutoff (log)
    local t = util.linlin(1, 8, 0, 1, x)
    cutoff = math.exp(math.log(200) + t * (math.log(8000) - math.log(200)))
    engine.cutoff(cutoff)

  elseif y == 6 then  -- accent prob
    accent_prob = util.linlin(1, 8, 0.05, 1.0, x)
    -- refresh accents live
    for i = 1, SEQ_LEN do
      seq[i].accent = math.random() < accent_prob
      seq[i].vel    = seq[i].active and (seq[i].accent and 1.0 or 0.6) or 0
    end

  elseif y == 7 then  -- slide prob
    slide_prob = util.linlin(1, 8, 0.0, 1.0, x)
    for i = 1, SEQ_LEN do
      seq[i].slide = math.random() < slide_prob
    end

  elseif y == 8 then  -- step mutes
    if x <= SEQ_LEN then
      muted[x] = not muted[x]
      if seq[x] then seq[x].active = not muted[x] end
    end
  end

  grid_redraw()
end

-- ─── norns params ────────────────────────────────────────────────────────────
local function init_params()
  params:add_number("bpm", "BPM", 40, 300, 120)
  params:set_action("bpm", function(v)
    bpm = v
    start_clock()
  end)

  params:add_number("seq_len", "Seq Length", 1, 16, 16)
  params:set_action("seq_len", function(v) SEQ_LEN = v end)

  params:add_control("engine_cutoff", "Filter", controlspec.new(200, 8000, "exp", 1, 800, "Hz"))
  params:set_action("engine_cutoff", function(v)
    cutoff = v
    engine.cutoff(v)
  end)

  params:add_control("engine_release", "Release", controlspec.new(0.01, 2, "exp", 0.01, 0.1, "s"))
  params:set_action("engine_release", function(v) engine.release(v) end)
end

-- ─── norns screen ────────────────────────────────────────────────────────────
function redraw()
  screen.clear()
  screen.font_size(8)
  screen.move(2, 10)
  screen.text("ACID BASS")
  screen.move(2, 22)
  screen.text("bpm: " .. bpm)
  screen.move(2, 32)
  screen.text("oct: " .. octave .. "  gate: " .. string.format("%.2f", gate_len))
  screen.move(2, 42)
  screen.text("sw: " .. string.format("%.2f", swing))
  screen.move(2, 52)
  screen.text("cf: " .. math.floor(cutoff) .. " Hz")
  -- draw step dots
  for i = 1, SEQ_LEN do
    local sx = (i - 1) * 8 + 2
    local sy = 62
    if seq[i] and seq[i].active then
      screen.level(i == step and 15 or (seq[i].accent and 8 or 4))
      screen.rect(sx, sy - 2, 6, 3)
      screen.fill()
    end
  end
  screen.update()
end

-- ─── encoders ────────────────────────────────────────────────────────────────
function enc(n, d)
  if n == 1 then
    params:delta("bpm", d)
  elseif n == 2 then
    params:delta("engine_cutoff", d * 50)
  elseif n == 3 then
    params:delta("engine_release", d * 0.01)
  end
  redraw()
end

-- ─── init ────────────────────────────────────────────────────────────────────
function init()
  engine.cutoff(cutoff)
  engine.release(0.1)
  engine.amp(0.8)
  init_params()
  generate_bass_line()
  start_clock()
  grid_redraw()
  redraw()
end

function cleanup()
  if seq_clock then clock.cancel(seq_clock) end
end
