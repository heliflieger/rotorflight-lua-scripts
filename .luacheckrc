std = "lua54"

-- EdgeTX/OpenTX Ethos Environment Globals
globals = {
  -- Scripting Engine
  "loadScript",
  "loadModuleChunk",
  "registerTelemetry",
  "registerForm",
  "registerGadget",
  
  -- System/Time/Model
  "getTime",
  "getUsage",
  "system",
  "model",
  "getVersion",
  "getField",
  "setField",
  "getFieldInfo",

  -- Filesystem
  "fstat",

  -- Telemetry/Sensors
  "getValue",
  "getSensor",
  
  -- Display/LCD
  "lcd",
  "lvgl",
  "LCD_W",
  "LCD_H",
  
  -- Colors
  "WHITE",
  "BLACK",
  "RED",
  "GREEN",
  "YELLOW",
  "BLUE",
  "MAGENTA",
  "CYAN",
  "COLOR_THEME_PRIMARY1",
  "COLOR_THEME_PRIMARY2",
  "COLOR_THEME_PRIMARY3",
  "COLOR_THEME_SECONDARY1",
  "COLOR_THEME_SECONDARY2",
  "COLOR_THEME_SECONDARY3",
  "COLOR_THEME_WARNING",
  "COLOR_THEME_DISABLED",
  "COLOR_THEME_FOCUS",
  "COLOR_THEME_ACTIVE",
  "COLOR_THEME_EDIT",
  
  -- Font sizes
  "DBLSIZE",
  "MIDSIZE",
  "SMLSIZE",
  "XXLSIZE",
  
  -- Alignment
  "CENTER",
  "LEFT",
  "RIGHT",
  "TOP",
  "BOTTOM",
  
  -- Bit operations
  "bit32",
  
  -- Global state (RF2/Ethos)
  "rfsuite",
  "Rf2Runtime",
  "_G",
}

-- Dashboard objects hand their value closures to lvgl.build, and the firmware's reactive
-- sweep then runs them per frame on the refresh's leftover budget, outside any pcall -- so
-- they read the precomputed `state.derived` snapshot and never probe. A probe re-introduced
-- into an object fails here instead of waiting for a reviewer's eye. `common.lua` is
-- exempt: it defines mapTelemetrySource, which widgets/dashboard/derived.lua calls from
-- the widget pass, where probing is legal.
local probe_globals = {
  ["model"] = true, ["getValue"] = true, ["getSensor"] = true, ["getFieldInfo"] = true,
  -- Reading the card is a probe like any other: derived.lua stats /IMAGES/ for the model
  -- picture, and an object doing the same would do it once per frame.
  ["fstat"] = true,
}
local object_globals = {}
for _, g in ipairs(globals) do
  if not probe_globals[g] then
    object_globals[#object_globals + 1] = g
  end
end
-- `new_globals` rather than `globals`: a per-path `globals` is MERGED with the one above it,
-- so a shortened list handed to a path adds nothing and takes nothing away. `new_globals`
-- replaces, which is what a restriction has to do.
files["src/rfsuite/widgets/dashboard/objects"] = { new_globals = object_globals }
files["src/rfsuite/widgets/dashboard/objects/common.lua"] = { new_globals = globals }

-- Code style rules
max_line_length = 140
max_code_line_length = 140

-- Allow unused arguments in functions (common in callbacks)
unused_args = false
unused_secondaries = false