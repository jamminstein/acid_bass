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
--
-- K1+K2: save pattern to next empty slot
-- E3 with alt held: morph between patterns

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

-- Pattern memory: store up to 8 patterns
local patterns = {}
local pattern_slot = 1
local num_slots = 8
for i = 1, num_slots do
  patterns[i] = {}
end

-- Screen state
local beat_phase = 0        -- 0.0–1.0 for pulse animation
local popup_param = nil     -- current param in popup (from enc)
local popup_val = nil       -- value to display
local popup_time = 0        -- time remaining for popup (0 = hidden)
local screen_clock_running = false

-- Pattern morphing state
local morph_active = false
local morph_target_slot = nil
local morph_amount = 0      -- 0.0–1.0

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

-- ─── pattern memory ──────────────────────────────────────────────────────────
local function save_pattern(slot)
  patterns[slot] = {}
  for i = 1, SEQ_LEN do
    patterns[slot][i] = {
      note = seq[i].note,
      vel = seq[i].vel,
      accent = seq[i].accent,
      slide = seq[i].slide,
      active = seq[i].active,
    }
  end
  print("pattern saved to slot " .. slot)
end

local function load_pattern(slot)
  if not patterns[slot] or #patterns[slot] == 0 then return end
  seq = {}
  for i = 1, SEQ_LEN do
    seq[i] = {
      note = patterns[slot][i].note,
      vel = patterns[slot][i].vel,
      accent = patterns[slot][i].accent,
      slide = patterns[slot][i].slide,
      active = patterns[slot][i].active,
    }
  end
  print("pattern loaded from slot " .. slot)
end

local function find_empty_slot()
  for i = 1, num_slots do
    if not patterns[i] or #patterns[i] == 0 then
      return i
    end
  end
  return nil
end

-- ─── pattern morphing ────────────────────────────────────────────────────────
local function morph_patterns(pattern_a, pattern_b, amount)
  -- amount: 0 = fully pattern_a, 1 = fully pattern_b
  local morphed = {}
  for i = 1, SEQ_LEN do
    local a = pattern_a[i]
    local b = pattern_b[i]
    local blend = amount
    
    morphed[i] = {
      note = math.floor(a.note * (1 - blend) + b.note * blend),
      vel = math.floor(a.vel * (1 - blend) + b.vel * blend),
      accent = math.random() < (a.accent and (1 - blend) or 0) + (b.accent and blend or 0),
      slide = math.random() < (a.slide and (1 - blend) or 0) + (b.slide and blend or 0),
      active = math.random() < (a.active and (1 - blend) or 0) + (b.active and blend or 0),
    }
  end
  return morphed
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
  beat_phase = 0  -- reset pulse at step
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

  params:add_number("pattern_slot", "Pattern Slot", 1, 8, 1)
  params:set_action("pattern_slot", function(v)
    pattern_slot = v
    load_pattern(v)
    redraw()
  end)
end

-- ─── screen drawing zones ────────────────────────────────────────────────────
-- Calculate normalized note position (0.0–1.0 vertically based on note range)
local function note_to_y(note)
  if not note or note == 0 then return nil end
  -- Map note range: 24 (low) to 72 (high) → normalized position
  local min_note = 24
  local max_note = 72
  return util.clamp((note - min_note) / (max_note - min_note), 0, 1)
end

-- Draw status strip (y 0-8)
local function draw_status_strip()
  screen.level(4)
  screen.font_size(8)
  screen.move(2, 7)
  screen.text("ACID")
  
  screen.level(8)
  screen.move(114, 7)
  screen.text("P" .. pattern_slot)
  
  -- Beat pulse dot at x=124
  local pulse_brightness = 4 + math.floor(beat_phase * 11)
  screen.level(pulse_brightness)
  screen.circle(124, 4, 2)
  screen.fill()
end

-- Draw live zone (y 9-52): 16-step contour with connections
local function draw_live_zone()
  local zone_top = 9
  local zone_height = 44
  local zone_left = 2
  local zone_width = 126
  
  -- Step width
  local step_width = zone_width / SEQ_LEN
  
  -- Draw morph target pattern if active
  if morph_active and morph_target_slot and patterns[morph_target_slot] then
    local target = patterns[morph_target_slot]
    local morph_bri = math.floor(3 + morph_amount * 2)
    screen.level(morph_bri)
    
    -- Draw target contour
    local prev_x, prev_y = nil, nil
    for i = 1, SEQ_LEN do
      local step_note = target[i] and target[i].note or nil
      local norm_y = note_to_y(step_note)
      
      if norm_y then
        local x = zone_left + (i - 0.5) * step_width
        local y = zone_top + zone_height - (norm_y * zone_height)
        
        if prev_x and prev_y then
          screen.aa(1)
          screen.move(prev_x, prev_y)
          screen.line(x, y)
          screen.stroke()
        end
        prev_x, prev_y = x, y
      else
        prev_x, prev_y = nil, nil
      end
    end
  end
  
  -- Draw current pattern contour
  local prev_x, prev_y = nil, nil
  
  for i = 1, SEQ_LEN do
    local s = seq[i]
    if not s then goto continue_live end
    
    local norm_y = note_to_y(s.note)
    if not norm_y then
      prev_x, prev_y = nil, nil
      goto continue_live
    end
    
    local x = zone_left + (i - 0.5) * step_width
    local y = zone_top + zone_height - (norm_y * zone_height)
    
    -- Draw connecting line from previous step
    if prev_x and prev_y then
      screen.aa(1)
      if s.slide then
        -- Slide line: brighter
        screen.level(10)
      else
        -- Regular line: medium brightness
        screen.level(8)
      end
      screen.move(prev_x, prev_y)
      screen.line(x, y)
      screen.stroke()
    end
    
    -- Draw step circle
    if s.active then
      if i == step then
        -- Active, current step: brightest filled circle
        screen.level(15)
        screen.circle(x, y, 3)
        screen.fill()
      elseif s.accent then
        -- Active, accented: larger brighter circle
        screen.level(15)
        screen.circle(x, y, 2.5)
        screen.fill()
      else
        -- Active, normal: regular filled circle
        screen.level(12)
        screen.circle(x, y, 2)
        screen.fill()
      end
    else
      -- Inactive: hollow circle at dim level
      screen.level(4)
      screen.circle(x, y, 1.5)
      screen.stroke()
    end
    
    prev_x, prev_y = x, y
    
    ::continue_live::
  end
  
  -- Playhead thin vertical line at current step
  if step >= 1 and step <= SEQ_LEN then
    local ph_x = zone_left + (step - 0.5) * step_width
    screen.level(15)
    screen.move(ph_x, zone_top)
    screen.line(ph_x, zone_top + zone_height)
    screen.stroke()
    
    -- Thin background line at level 3
    screen.level(3)
    screen.move(ph_x - 1, zone_top)
    screen.line(ph_x - 1, zone_top + zone_height)
    screen.stroke()
  end
end

-- Draw context bar (y 53-58)
local function draw_context_bar()
  screen.level(6)
  screen.font_size(8)
  
  -- DENS + density value
  screen.move(2, 58)
  screen.text("DENS " .. string.format("%.2f", 1.0))  -- could add density param later
  
  -- Cutoff value
  screen.move(40, 58)
  screen.text("CF " .. math.floor(cutoff) .. "Hz")
  
  -- Current pattern slot
  screen.level(8)
  screen.move(80, 58)
  screen.text("P" .. pattern_slot)
  
  -- Morph target if active
  if morph_active and morph_target_slot then
    screen.level(4)
    screen.move(100, 58)
    screen.text("→P" .. morph_target_slot)
  end
end

-- Draw transient parameter popup (0.8s)
local function draw_popup()
  if popup_time <= 0 or not popup_param then return end
  
  -- Popup box background
  screen.level(1)
  screen.rect(30, 15, 70, 30)
  screen.fill()
  
  -- Border
  screen.level(15)
  screen.rect(30, 15, 70, 30)
  screen.stroke()
  
  -- Param name
  screen.level(15)
  screen.font_size(8)
  screen.move(35, 25)
  screen.text(popup_param)
  
  -- Value
  screen.level(15)
  screen.font_size(10)
  screen.move(35, 40)
  screen.text(popup_val or "")
end

-- ─── norns screen ────────────────────────────────────────────────────────────
function redraw()
  screen.clear()
  screen.aa(1)
  
  draw_status_strip()
  draw_live_zone()
  draw_context_bar()
  draw_popup()
  
  screen.update()
end

-- ─── screen update clock (10fps) ──────────────────────────────────────────────
local function start_screen_clock()
  if screen_clock_running then return end
  screen_clock_running = true
  
  clock.run(function()
    while screen_clock_running do
      -- Advance beat phase
      beat_phase = beat_phase + 0.1
      if beat_phase > 1.0 then beat_phase = 0 end
      
      -- Decay popup timer
      if popup_time > 0 then
        popup_time = popup_time - 0.1
        if popup_time <= 0 then
          popup_time = 0
          popup_param = nil
          popup_val = nil
        end
      end
      
      redraw()
      clock.sleep(0.1)
    end
  end)
end

-- ─── encoders ────────────────────────────────────────────────────────────────
function enc(n, d)
  if n == 1 then
    params:delta("bpm", d)
    popup_param = "BPM"
    popup_val = tostring(bpm)
    popup_time = 0.8
  elseif n == 2 then
    params:delta("engine_cutoff", d * 50)
    popup_param = "CUTOFF"
    popup_val = math.floor(cutoff) .. "Hz"
    popup_time = 0.8
  elseif n == 3 then
    params:delta("engine_release", d * 0.01)
    popup_param = "RELEASE"
    popup_val = string.format("%.3f", params:get("engine_release")) .. "s"
    popup_time = 0.8
  end
  redraw()
end

-- ─── keys ────────────────────────────────────────────────────────────────────
function key(n, z)
  if z == 1 then
    if n == 2 then
      -- K2: toggle play/stop (handled by main app)
    elseif n == 3 then
      -- K1+K2: save pattern
    end
  end
end

-- ─── init ────────────────────────────────────────────────────────────────────
function init()
  engine.cutoff(cutoff)
  engine.release(0.1)
  engine.amp(0.8)
  init_params()
  generate_bass_line()
  save_pattern(1)
  start_clock()
  start_screen_clock()
  grid_redraw()
  redraw()
end

function cleanup()
  if seq_clock then clock.cancel(seq_clock) end
  screen_clock_running = false
end
