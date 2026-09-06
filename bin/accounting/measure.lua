-- Offline instruction accounting for the dashboard and service widget passes.
--
-- Runs the shipped sources against the stubs in stubs/ under debug.sethook(..., "count") --
-- the mechanism the firmware bills a widget call with -- and checks every measured row
-- against the table in budgets.lua. See README.md for why the gate is off-radio.
--
--   lua5.3 bin/accounting/measure.lua              report only
--   lua5.3 bin/accounting/measure.lua --check      gate: non-zero exit on any breach
--   lua5.3 bin/accounting/measure.lua --self-test  proves the gate can go red
--
-- Nothing here reads a wall clock, and no pcall swallows a failure: a stub that is missing
-- or a source that raises fails the run, because in a measurement a silence is a zero that
-- reads as "cheap".

local ROOT = "."
local HERE = "bin/accounting"

do
  local this = arg and arg[0]
  if type(this) == "string" then
    local dir = string.match(this, "^(.*)[/\\][^/\\]*$")
    if dir then
      HERE = dir
      ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]accounting$") or (dir .. "/../..")
    end
  end
end

local Stubs = assert(loadfile(HERE .. "/stubs/edgetx.lua"))()
local FC = assert(loadfile(HERE .. "/stubs/fc.lua"))()
local Budgets = assert(loadfile(HERE .. "/budgets.lua"))()

local API_DIR = ROOT .. "/src/rfsuite/tasks/msp/api"
local THEMES_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/themes"
local OBJECTS_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/objects"

local ZONE = { x = 0, y = 0, w = 800, h = 458 }

-- ---------------------------------------------------------------------------
-- Directory listing. `ls -1` is the one external call in here; everything else
-- is the interpreter. Sorted, because two hosts must enumerate in one order.
-- ---------------------------------------------------------------------------
local function listDir(path)
  local pipe = io.popen("ls -1 " .. path .. " 2>/dev/null")
  if not pipe then error("accounting: cannot list " .. path) end
  local names = {}
  for name in pipe:lines() do names[#names + 1] = name end
  pipe:close()
  table.sort(names)
  return names
end

local function listLuaFiles(path)
  local out = {}
  for _, name in ipairs(listDir(path)) do
    if string.match(name, "%.lua$") then out[#out + 1] = name end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The counter.
-- ---------------------------------------------------------------------------

--- Instructions billed to one call.
--
-- The collector is stopped across the measured section: the events runtime runs a full
-- collection when the connect chain finishes, and a GC step would land in the count
-- wherever the allocator happens to be. The firmware's own incremental collection is part
-- of what the budget margin covers.
local function count(fn, ...)
  local n = 0
  collectgarbage("collect")
  collectgarbage("stop")
  debug.sethook(function() n = n + 1 end, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  collectgarbage("restart")
  if not ok then error(err, 0) end
  return n
end

--- What one call of an empty closure costs through the loop the sweep is replayed in.
--
-- The firmware walks LVGL's reactive references in C; this check calls the collected
-- function fields in a plain Lua loop, and the loop is not free. Measured here, subtracted
-- from every sweep row, and compared against budgets.lua -- a run whose control has
-- drifted is measuring something else, and every sweep row it prints is wrong by that
-- difference.
local function sweepControl(iterations)
  local refs = {}
  local empty = function() end
  for i = 1, iterations do refs[i] = empty end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return total / iterations
end

--- Call every reactive reference in `refs` once, with the loop's own cost taken back out.
local function sweepCost(refs, control)
  if #refs == 0 then return 0, 0 end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return math.max(0, math.floor(total - control * #refs + 0.5)), #refs
end

--- Collect every function field of a node tree, the way the lvgl stub does at build time.
local function collectRefs(node, refs)
  for _, v in pairs(node) do
    if type(v) == "function" then
      refs[#refs + 1] = v
    elseif type(v) == "table" then
      collectRefs(v, refs)
    end
  end
  return refs
end

-- ---------------------------------------------------------------------------
-- The world, rebuilt per scenario so no measurement inherits another's caches.
-- ---------------------------------------------------------------------------

-- The sensor set a settled dashboard reads, under the four-character names
-- lib/sensors.lua searches for. Values are a helicopter idling on the bench: they only
-- have to be plausible and constant, because a value that moved would move the render key
-- and put a rebuild into a pass being measured for something else.
local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74,
  ["SmFt"] = 74, ["SmCp"] = 850, ["Cel#"] = 6,
  ["Hspd"] = 1750, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45,
  ["Vbec"] = 8.1, ["EscT"] = 48, ["Tmcu"] = 39, ["Thr%"] = 12,
  ["PID#"] = 1, ["RTE#"] = 1, ["BatP"] = 1, ["ARM"] = 0, ["ARMD"] = 0,
  ["Gov"] = 4, ["Alt"] = 1.5, ["Ptch"] = 0, ["Roll"] = 0, ["Yaw"] = 0,
}

local World = { sensorIds = {} }

function World.reset()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
end

function World.require(path)
  return _G.rfsuite.require(path)
end

-- One custom telemetry frame carrying the full sensor set, built from the repository's own
-- decoder table so the byte walk a pass pays for is the walk the firmware sends.
local function buildTelemetryFrame(frameId, sensorIds)
  local frame = { 0xEA, 0xC8, frameId & 0xFF }
  for _, sid in ipairs(sensorIds) do
    frame[#frame + 1] = (sid >> 8) & 0xFF
    frame[#frame + 1] = sid & 0xFF
    frame[#frame + 1] = 0x01
    frame[#frame + 1] = 0x00
  end
  return frame
end

-- What "the allowance fully drawn" means for a STATE pass: the drain finds a full backlog
-- waiting and decodes its cap out of it, and the MSP poll loop finds a reply on every poll
-- instead of running out of work early. tasks.lua pops at most POP_CAP per wakeup.
local FRAME_BACKLOG = 15

local function feedLink(sensorIds, frameId)
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(frameId + i, sensorIds))
  end
end

-- ---------------------------------------------------------------------------
-- Pass classification. The dispatcher in widgets/dashboard/runtime.lua decides what a
-- pass does from the job slot BEFORE the call, so that is where the class is read.
-- ---------------------------------------------------------------------------
local function passClass(widget)
  local job = widget._job
  if not job then return "state" end
  if job.kind == "splash" then return "splash" end
  if job.kind == "menu" then return "menu" end
  if job.swap then return "swap" end
  if job.build then return "build" end
  return "prepare"
end

--- Drive a dashboard widget until it has settled: link up, connect chain done, scene built.
--
-- Everything before that is the cold start, which loads several dozen modules and is
-- reported as a row of its own rather than folded into the steady-state numbers.
--
-- The tail also has to outlast the one-time announcements a fresh connection makes.
-- Those are spaced by their own cooldowns, so how many passes after the swap the last
-- of them lands depends on which of them ran at all. With a tail of 20, silencing one
-- moves a later one into the first measured pass, where it reads as +2892 instructions
-- of steady-state cost that no pass on a radio pays: on an otherwise untouched tree,
-- forcing the initial fuel announcement off takes pass.state from 11460 to 14352 at a
-- tail of 20, and leaves it at 10706 once the tail is long enough to cover it. A tail
-- of 31 is the first that clears it, so 40 keeps ten passes of margin.
local SETTLE_TAIL = 40

local function settle(widget, sensorIds, maxPasses)
  local coldWorst = 0
  local startupWorst = {}
  local swapAt = nil
  for i = 1, maxPasses do
    feedLink(sensorIds, i)
    local before = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > coldWorst then coldWorst = n end
    if n > (startupWorst[before] or 0) then startupWorst[before] = n end
    if before == "swap" then swapAt = swapAt or i end
    -- The first scene on screen, plus a tail: the pass after a swap still carries the
    -- module loads the first build pulled in, and those belong to the cold start.
    if swapAt and i >= swapAt + SETTLE_TAIL then return coldWorst, i, startupWorst end
  end
  error("accounting: the dashboard never settled in " .. maxPasses .. " passes")
end

--- Force the next STATE pass to enqueue a scene build: a render key that has moved.
local function invalidate(widget)
  widget._cachedRenderKey = nil
  widget.renderKey = nil
  widget._lastUIRefresh = 0
  widget.built = false
end

--- Run one scenario: a widget on `themePath`, settled, then `passes` measured passes.
local function runScenario(themePath, passes)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  local coldWorst, settlePasses, startupWorst = settle(widget, sensorIds, 400)

  local worst = {}
  for i = 1, passes do
    feedLink(sensorIds, i)
    -- Every third pass, move the render key so the build and swap classes keep occurring.
    if i % 3 == 0 then invalidate(widget) end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  return {
    theme = themePath,
    worst = worst,
    coldWorst = coldWorst,
    settlePasses = settlePasses,
    startupWorst = startupWorst,
    refs = Stubs.lvgl.refs,
    widget = widget,
  }
end

-- ---------------------------------------------------------------------------
-- Report and gate
-- ---------------------------------------------------------------------------

local rows = {}
local rowIndex = {}
local notes = {}

local function addRow(name, measured, extra)
  if rowIndex[name] then error("accounting: duplicate row " .. name) end
  rowIndex[name] = true
  rows[#rows + 1] = { name = name, measured = measured, extra = extra }
end

local function note(fmt, ...)
  notes[#notes + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local args = {}
for _, a in ipairs(arg or {}) do args[a] = true end
local checking = args["--check"] == true
local selfTest = args["--self-test"] == true

------------------------------------------------------------------------------
-- Inventory: what the gate has to cover, read off the tree rather than a list.
------------------------------------------------------------------------------
World.reset()

local apiFiles = listLuaFiles(API_DIR)
local indexed = FC.loadReplies(API_DIR, apiFiles)

local themes = {}
for _, name in ipairs(listDir(THEMES_DIR)) do
  local probe = io.open(THEMES_DIR .. "/" .. name .. "/init.lua", "r")
  if probe then
    probe:close()
    themes[#themes + 1] = name
  end
end
if #themes == 0 then error("accounting: no shipped theme found under " .. THEMES_DIR) end

-- Object modules on disk: objects/<type>.lua, and objects/<type>/<subtype>.lua where the
-- type has a folder of its own.
local objectFiles = listLuaFiles(OBJECTS_DIR)

-- The sensor id list the telemetry frames carry, from the repository's own decoder table.
local RFSensors = World.require("lib/rf2tlm_sensors.lua")
if type(RFSensors) ~= "table" then error("accounting: lib/rf2tlm_sensors.lua did not load") end
local sensorIds = {}
for sid in pairs(RFSensors) do
  if type(sid) == "number" then sensorIds[#sensorIds + 1] = sid end
end
table.sort(sensorIds)
if #sensorIds == 0 then error("accounting: no sensor decoders found") end
World.sensorIds = sensorIds

local control = sweepControl(2000)

------------------------------------------------------------------------------
-- Pass classes, on the reference theme.
------------------------------------------------------------------------------
local reference = "system/default"
local base = runScenario(reference, 240)

addRow("pass.state", base.worst.state or 0)
addRow("pass.job.prepare", base.worst.prepare or 0)
addRow("pass.job.build", base.worst.build or 0)
addRow("pass.swap", base.worst.swap or 0)
-- The splash pass only ever happens while the widget is NOT ready, so its only home is
-- the startup window. A row measured on a window where the class never occurs would be a
-- zero that reads as free.
addRow("pass.splash", base.startupWorst.splash or base.worst.splash or 0)
addRow("pass.startup.worst", base.coldWorst, base.settlePasses .. " passes to settle")

-- The background half of a STATE pass, as the widget calls it: the onconnect runner, the
-- custom-telemetry drain and the arm/disarm edges in one. It is the largest single term in
-- a STATE pass, so it gets a row of its own rather than being visible only as the
-- difference between two other rows. Measured on the world the reference scenario left
-- standing, which is the only one with a settled link in it.
do
  local Events = World.require("tasks/events/runtime.lua")
  local session = _G.rfsuite.session
  local worst = 0
  for i = 1, 120 do
    feedLink(World.sensorIds, 5000 + i)
    session.event_context = "widget"
    local n = count(Events.wakeup)
    session.event_context = nil
    if n > worst then worst = n end
  end
  addRow("unit.events.wakeup", worst)
end

------------------------------------------------------------------------------
-- Every shipped theme: worst pass plus the full sweep of the tree it leaves.
------------------------------------------------------------------------------
local boxTypes = {}
local boxFixtures = {}

local function harvestBoxes(run)
  local Utils = World.require("widgets/dashboard/objects/common.lua")
  local themeModule = run.widget.theme
  if type(themeModule) ~= "table" then return end
  local boxes = Utils.resolveValue(themeModule.boxes, nil, run.widget.state)
  local headerBoxes = Utils.resolveValue(themeModule.header_boxes, nil, run.widget.state)
  for _, list in ipairs({ boxes, headerBoxes }) do
    if type(list) == "table" then
      for _, box in ipairs(list) do
        local typ = box.type or "text"
        local sub = box.subtype
        local key = (sub ~= nil) and (typ .. "/" .. tostring(sub)) or typ
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = { box = box, from = run.theme }
        end
      end
    end
  end
end

for _, theme in ipairs(themes) do
  local run = (theme == "default") and base or runScenario("system/" .. theme, 160)
  local worstPass = 0
  for _, n in pairs(run.worst) do
    if n > worstPass then worstPass = n end
  end
  local sweep, refCount = sweepCost(run.refs, control)
  addRow("theme." .. theme, worstPass + sweep,
    string.format("worst pass %d + sweep %d over %d refs", worstPass, sweep, refCount))
  harvestBoxes(run)
end

-- Every object module on disk that no shipped theme happens to declare still needs a row:
-- it is shipped, so it can be reached.
for _, file in ipairs(objectFiles) do
  local typ = string.gsub(file, "%.lua$", "")
  if typ ~= "common" then
    local subdir = OBJECTS_DIR .. "/" .. typ
    local subtypes = listLuaFiles(subdir)
    if #subtypes > 0 then
      for _, sub in ipairs(subtypes) do
        local key = typ .. "/" .. string.gsub(sub, "%.lua$", "")
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = {}
        end
      end
    elseif boxFixtures[typ] == nil then
      boxTypes[#boxTypes + 1] = typ
      boxFixtures[typ] = {}
    end
  end
end
table.sort(boxTypes)

------------------------------------------------------------------------------
-- Per box type: one render, and one sweep of what that render collected.
------------------------------------------------------------------------------
World.reset()
do
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  local Engine = World.require("widgets/dashboard/engine.lua")
  local Derived = World.require("widgets/dashboard/derived.lua")
  local state = widget.state
  Derived.build(state, widget.boxSources)

  for _, key in ipairs(boxTypes) do
    local fixture = boxFixtures[key]
    local box = fixture.box
    if box == nil then
      local typ, sub = string.match(key, "^([^/]+)/(.+)$")
      box = { col = 1, row = 1, colspan = 1, rowspan = 1, type = typ or key, subtype = sub }
      note("box type %s is declared by no shipped theme; measured on a minimal fixture", key)
    end
    local theme = { layout = { cols = 1, rows = 1, padding = 0 }, boxes = { box } }
    -- Warm the object wrapper first: loading its module is a cold-start cost, not a render.
    Engine.build(ZONE, state, theme)
    local build = Engine.beginBuild(ZONE, state, theme)
    addRow("box." .. key, count(Engine.stepBuild, build, state, 1))

    local refs = collectRefs(build.nodes, {})
    local sweep = sweepCost(refs, control)
    addRow("sweep." .. key, sweep, #refs .. " refs")
  end
end

------------------------------------------------------------------------------
-- Per unit: the telemetry drain, the MSP poll quantum, the largest parse.
------------------------------------------------------------------------------
World.reset()
do
  local Events = World.require("tasks/events/telemetry_bg/tasks.lua")
  -- Warm the module's own lazy loads; they are a cold-start cost, not a drain.
  Events.wakeup()
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  addRow("unit.telemetry.drain", count(Events.wakeup),
    FRAME_BACKLOG .. " frames queued, " .. #sensorIds .. " sensors per frame")
end

World.reset()
do
  local Msp = World.require("tasks/msp/runtime.lua")
  Msp.attach("accounting")
  for _ = 1, 20 do Msp.tick() end
  addRow("unit.msp.pump", count(Msp.pump))
end

do
  local widest, widestFile = nil, nil
  for _, file in ipairs(apiFiles) do
    local mod = assert(loadfile(API_DIR .. "/" .. file))()
    if type(mod) == "table" and type(mod.simulatorResponse) == "table"
      and type(mod.parse) == "function" then
      if widest == nil or #mod.simulatorResponse > #widest.simulatorResponse then
        widest, widestFile = mod, file
      end
    end
  end
  if widest == nil then error("accounting: no API module carries both a payload and a parser") end
  addRow("unit.msp.parse.max", count(widest.parse, widest.simulatorResponse),
    widestFile .. ", " .. #widest.simulatorResponse .. " bytes")
end

------------------------------------------------------------------------------
-- The service widget's background pass: the pure background half, no build.
------------------------------------------------------------------------------
World.reset()
do
  local Service = World.require("widgets/service/runtime.lua")
  local widget = Service.new({ x = 0, y = 0, w = 200, h = 100 }, {})
  local worst = 0
  for i = 1, 200 do
    feedLink(World.sensorIds, i)
    local n = count(widget.background, widget)
    if i > 60 and n > worst then worst = n end
  end
  addRow("pass.service", worst)
end

------------------------------------------------------------------------------
-- Check and report.
------------------------------------------------------------------------------
local unanswered = {}
for cmd, n in pairs(FC.unanswered) do
  unanswered[#unanswered + 1] = string.format("%d(x%d)", cmd, n)
end
table.sort(unanswered)

local collisions = {}
for cmd, files in pairs(FC.collisions) do
  collisions[#collisions + 1] = string.format("%d(%s)", cmd, table.concat(files, ","))
end
table.sort(collisions)

print("offline instruction accounting")
print(string.format("  interpreter        %s, count hook at 1 instruction", _VERSION))
print(string.format("  sweep control      %.3f instructions per reference (budgets.lua %.3f)",
  control, Budgets.sweepControl))
print(string.format("  api replies        %d of %d modules indexed", indexed, #apiFiles))
print(string.format("  themes             %d: %s", #themes, table.concat(themes, " ")))
print(string.format("  box types          %d", #boxTypes))
if #unanswered > 0 then
  print("  answered empty     " .. table.concat(unanswered, " "))
end
if #collisions > 0 then
  print("  command claimed by more than one module, first wins: " .. table.concat(collisions, " "))
end
for _, n in ipairs(notes) do print("  note               " .. n) end
print("")

local failures = {}
local warnings = {}

if math.abs(control - Budgets.sweepControl) > Budgets.sweepControlTolerance then
  failures[#failures + 1] = string.format(
    "sweep control %.3f is outside %.3f +/- %.3f: this run is measuring itself differently",
    control, Budgets.sweepControl, Budgets.sweepControlTolerance)
end

-- The self-test drives BOTH ways the check can go red -- a row over its target and a row
-- with no budget at all -- because a gate never seen red is a loop that never ran with a
-- badge on it. It fails unless both mechanisms fire.
local poisoned = selfTest and rows[1] and rows[1].name or nil
local hidden = selfTest and rows[2] and rows[2].name or nil
if hidden then Budgets.rows[hidden] = nil end

print(string.format("  %-32s %9s %9s %7s", "row", "measured", "target", "margin"))
for _, row in ipairs(rows) do
  local budget = Budgets.rows[row.name]
  local target = budget and budget.target
  if poisoned == row.name then target = 1 end
  local marginText = "-"
  if target and target > 0 then
    marginText = string.format("%.0f%%", 100 * (target - row.measured) / target)
  end
  -- A target that was moved off the figure first written down says so on every run.
  -- Otherwise a re-apportioned budget reads exactly like the original one.
  local extra = row.extra
  if budget and budget.proposed and budget.proposed ~= target then
    local moved = string.format("re-apportioned from %d", budget.proposed)
    extra = extra and (moved .. ", " .. extra) or moved
  end
  print(string.format("  %-32s %9d %9s %7s%s",
    row.name, row.measured, target and tostring(target) or "MISSING", marginText,
    extra and ("   " .. extra) or ""))
  if target == nil then
    failures[#failures + 1] = row.name .. " has no row in budgets.lua"
  elseif row.measured > target then
    failures[#failures + 1] = string.format("%s: %d instructions over a target of %d",
      row.name, row.measured, target)
  elseif row.measured > target * 0.9 then
    -- A flag to widen the row, not a build failure: the row is still inside its ceiling,
    -- and turning a thin margin into a red build would make the honest answer -- write
    -- down what it costs -- the expensive one.
    warnings[#warnings + 1] = string.format(
      "%s: %d is within 10%% of its target of %d, so this is a margin to widen, not a pass to celebrate",
      row.name, row.measured, target)
  end
end

-- The other half of the coverage rule: a row nothing measures is a target nothing
-- enforces, and a removed box type or theme leaves exactly that behind.
local orphans = {}
for name in pairs(Budgets.rows) do
  if not rowIndex[name] then orphans[#orphans + 1] = name end
end
table.sort(orphans)
for _, name in ipairs(orphans) do
  failures[#failures + 1] = name .. " has a budget row but nothing measured it"
end

-- A PR that adds a box type or a theme needs its cost row, and the number in it has to be
-- a measurement rather than a guess. This prints the table body ready to paste; the
-- targets it suggests carry the same margin the rows above are read with.
if args["--emit"] then
  print("")
  print("-- budgets.lua rows, emitted from this run")
  print(string.format("sweepControl = %.3f,", control))
  print("rows = {")
  for _, row in ipairs(rows) do
    local budget = Budgets.rows[row.name]
    local target = (budget and budget.target) or (math.ceil(row.measured / 0.8 / 50) * 50)
    print(string.format("  [%q] = { target = %d, measured = %d },", row.name, target, row.measured))
  end
  print("}")
end

print("")
for _, w in ipairs(warnings) do print("WARN: " .. w) end
if selfTest then
  local sawPoisoned, sawHidden = false, false
  for _, f in ipairs(failures) do
    if poisoned and string.find(f, poisoned, 1, true)
      and string.find(f, "over a target", 1, true) then
      sawPoisoned = true
    end
    if hidden and string.find(f, hidden, 1, true)
      and string.find(f, "no row in budgets.lua", 1, true) then
      sawHidden = true
    end
  end
  for _, f in ipairs(failures) do print("(self-test) " .. f) end
  if not sawPoisoned then
    print("SELF-TEST FAILED: a target poisoned to 1 did not turn the check red")
    os.exit(1)
  end
  if not sawHidden then
    print("SELF-TEST FAILED: a row with its budget removed did not turn the check red")
    os.exit(1)
  end
  print("SELF-TEST PASSED: both a breached target and a missing budget row turn the check red")
  os.exit(0)
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d row(s) over budget or unaccounted", #failures))
  if checking then os.exit(1) end
else
  print(string.format("%d rows, 0 failures", #rows))
end
