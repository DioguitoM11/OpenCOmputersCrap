-- ╔══════════════════════════════════════════════╗
-- ║         RAID-NET CLIENT  v1.0                ║
-- ║   Run on any computer with a modem           ║
-- ║   Requires: modem, gpu, screen, keyboard     ║
-- ╚══════════════════════════════════════════════╝

local component = require("component")
local event     = require("event")
local fs        = require("filesystem")
local serial    = require("serialization")
local keyboard  = require("keyboard")
local term      = require("term")

local gpu   = component.gpu
local modem = component.modem
modem.setStrength(400)

-- ── CONFIG ─────────────────────────────────────────────────────────────────
local PORT    = 1337
local TIMEOUT = 6
local DL_DIR  = "/home/downloads/"
-- ───────────────────────────────────────────────────────────────────────────

local W, H = gpu.getResolution()

local C = {
  bg        = 0x070712,
  panel     = 0x0C0C22,
  border    = 0x1A2A4A,
  accent    = 0x0077FF,
  accentDim = 0x003388,
  cyan      = 0x00EEFF,
  green     = 0x00FF88,
  yellow    = 0xFFCC00,
  orange    = 0xFF8800,
  red       = 0xFF3355,
  white     = 0xEEEEFF,
  gray      = 0x556677,
  darkgray  = 0x141428,
  selected  = 0x002255,
  selText   = 0x88DDFF,
}

-- Layout constants
local SIDEBAR_X  = nil  -- computed after W known
local SIDEBAR_W  = 26
local LIST_X     = 2
local LIST_Y     = 8    -- file list starts here
local LIST_H     = nil  -- computed
local STATUS_Y   = nil  -- bottom bar

-- State
local SERVER = nil

local state = {
  path      = "",
  files     = {},
  display   = {},   -- merged: ".." + files
  cursor    = 1,
  scroll    = 0,
  stats     = nil,
  status    = "Connecting...",
  statusOK  = true,
  mode      = "browse",  -- browse | logs | confirm | input
  logs      = {},
  logScroll = 0,
  confirmMsg  = "",
  confirmCB   = nil,
  inputPrompt = "",
  inputCB     = nil,
  inputBuf    = "",
}

-- ── Compute layout ─────────────────────────────────────────────────────────

SIDEBAR_X = W - SIDEBAR_W + 1
LIST_H    = H - LIST_Y - 3
STATUS_Y  = H - 1

-- ── Net helpers ────────────────────────────────────────────────────────────

local function sendCmd(cmd, ...)
  modem.send(SERVER, PORT, cmd, ...)
  local deadline = require("computer").uptime() + TIMEOUT
  repeat
    local rem = deadline - require("computer").uptime()
    if rem <= 0 then break end
    local ev, _, from, port2, _, resp, data = event.pull(rem, "modem_message")
    if ev and from == SERVER and port2 == PORT then
      return resp == "OK", data
    end
  until false
  return false, "Timeout"
end

-- ── Format helpers ─────────────────────────────────────────────────────────

local function fmt(bytes)
  if bytes >= 1073741824 then return string.format("%.1fG", bytes/1073741824)
  elseif bytes >= 1048576 then return string.format("%.1fM", bytes/1048576)
  elseif bytes >= 1024    then return string.format("%.1fK", bytes/1024)
  else                         return bytes.."B"
  end
end

local function padR(s, n)
  s = tostring(s)
  if #s >= n then return s:sub(1, n) end
  return s .. string.rep(" ", n - #s)
end

local function padL(s, n)
  s = tostring(s)
  if #s >= n then return s:sub(1, n) end
  return string.rep(" ", n - #s) .. s
end

-- ── Draw primitives ────────────────────────────────────────────────────────

local function clr(x, y, w, h, bgc)
  gpu.setBackground(bgc or C.bg)
  gpu.fill(x, y, w, h, " ")
end

local function put(x, y, text, fgc, bgc)
  if fgc then gpu.setForeground(fgc) end
  if bgc then gpu.setBackground(bgc) end
  gpu.set(x, y, text)
end

local function hline(y, fgc, bgc)
  gpu.setForeground(fgc or C.border)
  gpu.setBackground(bgc or C.bg)
  gpu.fill(1, y, W, 1, "─")
end

-- ── Header ─────────────────────────────────────────────────────────────────

local function drawHeader()
  -- Row 1: black bar
  clr(1, 1, W, 1, C.darkgray)
  put(2, 1, "RAID-NET", C.accent, C.darkgray)
  put(11,1, "remote access interface for distributed storage", C.gray, C.darkgray)

  local srvShort = SERVER and SERVER:sub(1,8) or "N/A"
  put(W - 17, 1, "SRV:" .. srvShort, C.yellow, C.darkgray)

  -- Row 2-3: path + info
  clr(1, 2, W, 2, C.panel)
  local pathStr = "/" .. state.path
  put(2, 2, "PATH  ", C.gray, C.panel)
  put(8, 2, pathStr, C.cyan, C.panel)

  -- Stats brief
  if state.stats then
    local s = state.stats
    local pct = math.floor(s.used / s.total * 100)
    local barW = 20
    local filled = math.floor(barW * pct / 100)
    local bar = string.rep("█", filled) .. string.rep("░", barW - filled)
    put(2, 3, "DISK  ", C.gray, C.panel)
    put(8, 3, bar, C.accent, C.panel)
    put(8 + barW + 1, 3, pct.."%  free:"..fmt(s.free), C.gray, C.panel)
  else
    put(2, 3, "DISK  loading...", C.gray, C.panel)
  end

  -- Separator
  hline(4)

  -- Column headers
  clr(1, 5, W, 1, C.bg)
  local fileW = SIDEBAR_X - LIST_X - 12
  put(LIST_X, 5, padR("NAME", fileW), C.gray, C.bg)
  put(LIST_X + fileW + 1, 5, padL("SIZE", 8), C.gray, C.bg)
  put(LIST_X + fileW + 10, 5, "TYPE", C.gray, C.bg)

  hline(6)

  -- Sidebar header
  clr(SIDEBAR_X - 1, 4, 1, H - 4, C.bg)
  gpu.setForeground(C.border)
  gpu.setBackground(C.bg)
  for row = 4, H - 2 do gpu.set(SIDEBAR_X - 1, row, "│") end

  clr(SIDEBAR_X, 4, SIDEBAR_W, 1, C.darkgray)
  put(SIDEBAR_X + 1, 4, "  ACTIONS  ", C.accent, C.darkgray)
  hline(5)  -- not ideal but works
  -- Re-draw sidebar column separator
  gpu.setForeground(C.border)
  gpu.setBackground(C.bg)
  for row = 5, H - 2 do gpu.set(SIDEBAR_X - 1, row, "│") end
end

-- ── Sidebar ────────────────────────────────────────────────────────────────

local MENU = {
  {"↑↓",  "Navigate"},
  {"ENT",  "Open/Download"},
  {"BSP",  "Go up"},
  {"",     ""},
  {"U",    "Upload"},
  {"M",    "New folder"},
  {"X",    "Delete"},
  {"R",    "Refresh"},
  {"L",    "View logs"},
  {"",     ""},
  {"Q",    "Quit"},
}

local function drawSidebar()
  clr(SIDEBAR_X, 5, SIDEBAR_W, H - 6, C.panel)

  for i, item in ipairs(MENU) do
    local y = 5 + i
    if y > H - 2 then break end
    if item[1] == "" then
      -- spacer / divider
      gpu.setForeground(C.border)
      gpu.setBackground(C.panel)
      gpu.fill(SIDEBAR_X, y, SIDEBAR_W, 1, "─")
    else
      put(SIDEBAR_X + 1, y, "["..item[1].."]", C.yellow, C.panel)
      put(SIDEBAR_X + 6, y, item[2],  C.white,  C.panel)
    end
  end

  -- Uptime / client info
  local infoY = H - 3
  put(SIDEBAR_X, infoY, string.rep("─", SIDEBAR_W), C.border, C.panel)
  put(SIDEBAR_X + 1, infoY + 1, "OC RAID-NET v1.0", C.gray, C.panel)
end

-- ── File list ──────────────────────────────────────────────────────────────

local function buildDisplay()
  state.display = {}
  if state.path ~= "" then
    table.insert(state.display, {name="..", isDir=true, size=0, up=true})
  end
  for _, f in ipairs(state.files) do
    table.insert(state.display, f)
  end
end

local function clampCursor()
  local n = #state.display
  state.cursor = math.max(1, math.min(state.cursor, math.max(1, n)))
  if state.cursor - state.scroll > LIST_H then
    state.scroll = state.cursor - LIST_H
  end
  if state.cursor - state.scroll < 1 then
    state.scroll = state.cursor - 1
  end
end

local function drawFileList()
  local fileW = SIDEBAR_X - LIST_X - 12
  clr(1, LIST_Y, SIDEBAR_X - 2, LIST_H + 1, C.bg)

  clampCursor()

  for row = 1, LIST_H do
    local idx = row + state.scroll
    local f   = state.display[idx]
    local y   = LIST_Y + row - 1
    local sel = (idx == state.cursor)

    if f then
      local bgc = sel and C.selected or C.bg
      clr(1, y, SIDEBAR_X - 2, 1, bgc)

      local icon, nameColor
      if f.up then
        icon = "← "; nameColor = C.gray
      elseif f.isDir then
        icon = "▸ "; nameColor = sel and C.selText or C.cyan
      else
        icon = "  "; nameColor = sel and C.selText or C.white
      end

      -- Name (truncated)
      local maxName = fileW - 2
      local display = f.name
      if #display > maxName then display = display:sub(1, maxName - 1) .. "…" end
      put(LIST_X,     y, icon,              nameColor, bgc)
      put(LIST_X + 2, y, padR(display, maxName), nameColor, bgc)

      -- Size
      if not f.isDir then
        local sz = padL(fmt(f.size), 7)
        put(LIST_X + fileW + 1, y, sz, sel and C.gray or C.gray, bgc)
      end

      -- Type badge
      if not f.up then
        local badge, badgeC
        if f.isDir then
          badge = "DIR "; badgeC = C.accentDim
        else
          local ext = f.name:match("%.([^%.]+)$") or "---"
          badge = padR(ext:upper(), 4); badgeC = C.darkgray
        end
        put(LIST_X + fileW + 9, y, badge, C.gray, bgc)
      end
    else
      clr(1, y, SIDEBAR_X - 2, 1, C.bg)
    end
  end

  -- Scrollbar
  if #state.display > LIST_H then
    local trackH = LIST_H
    local thumbH = math.max(1, math.floor(trackH * LIST_H / #state.display))
    local thumbY = math.floor((state.scroll / (#state.display - LIST_H)) * (trackH - thumbH))
    for i = 0, trackH - 1 do
      local ch = (i >= thumbY and i < thumbY + thumbH) and "█" or "░"
      gpu.setForeground(i >= thumbY and i < thumbY + thumbH and C.accent or C.border)
      gpu.setBackground(C.bg)
      gpu.set(SIDEBAR_X - 2, LIST_Y + i, ch)
    end
  end
end

-- ── Status bar ─────────────────────────────────────────────────────────────

local function drawStatus(msg, ok)
  if msg ~= nil then state.status = msg; state.statusOK = (ok ~= false) end
  clr(1, STATUS_Y, W, 1, C.darkgray)
  local dot = state.statusOK and "●" or "✖"
  local dotC = state.statusOK and C.green or C.red
  put(2, STATUS_Y, dot .. " " .. state.status, dotC, C.darkgray)
  -- item count
  local cnt = #state.display .. " items"
  put(W - #cnt - 1, STATUS_Y, cnt, C.gray, C.darkgray)
end

-- ── Log viewer ─────────────────────────────────────────────────────────────

local function drawLogs()
  clr(1, 4, W, H - 4, C.bg)
  clr(1, 4, W, 1, C.darkgray)
  put(2, 4, " ╔═ ACCESS LOGS ═╗  [ESC or L to close]  [↑↓ scroll]", C.cyan, C.darkgray)
  hline(5)

  local viewH = H - 6
  for row = 1, viewH do
    local idx = row + state.logScroll
    local y   = 5 + row
    clr(1, y, W, 1, C.bg)
    local line = state.logs[idx]
    if line then
      local ts, addr, action, detail = line:match("^(%[.-%]) (%S+) | (%S+)%s*| (.*)$")
      if ts then
        local x = 2
        put(x, y, ts,     C.gray,   C.bg); x = x + #ts + 1
        put(x, y, addr,   C.yellow, C.bg); x = x + 10
        put(x, y, padR(action,8), C.cyan, C.bg); x = x + 9
        local maxD = W - x - 1
        if detail and #detail > 0 then
          if #detail > maxD then detail = detail:sub(1, maxD-1).."…" end
          put(x, y, detail, C.white, C.bg)
        end
      else
        put(2, y, line:sub(1, W-3), C.gray, C.bg)
      end
    end
  end
end

-- ── Confirm dialog ─────────────────────────────────────────────────────────

local function drawConfirm()
  local bw, bh = 52, 9
  local bx = math.floor((W - bw) / 2) + 1
  local by = math.floor((H - bh) / 2) + 1

  clr(bx, by, bw, bh, C.panel)
  clr(bx, by, bw, 1, C.red)
  put(bx + 2, by, "⚠  CONFIRM ACTION", C.white, C.red)

  gpu.setForeground(C.border)
  gpu.setBackground(C.panel)
  for i = 0, bh-1 do
    gpu.set(bx, by+i, "│")
    gpu.set(bx+bw-1, by+i, "│")
  end
  gpu.fill(bx, by, bw, 1, " ")
  gpu.fill(bx, by+bh-1, bw, 1, "─")
  put(bx + 2, by, "⚠  CONFIRM ACTION", C.white, C.red)

  local lines = {}
  for line in state.confirmMsg:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  for i, line in ipairs(lines) do
    put(bx + 2, by + 1 + i, line, C.white, C.panel)
  end

  put(bx + 5,      by + bh - 2, "[ Y ]  Yes, do it", C.green,  C.panel)
  put(bx + bw - 20, by + bh - 2, "[ N ]  Cancel",     C.red,    C.panel)
end

-- ── Input prompt ───────────────────────────────────────────────────────────

local function drawInput()
  clr(1, STATUS_Y, W, 1, C.accent)
  put(2, STATUS_Y, state.inputPrompt .. ": " .. state.inputBuf .. "█", C.white, C.accent)
end

-- ── Full redraw ────────────────────────────────────────────────────────────

local function redraw()
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")

  if state.mode == "logs" then
    drawLogs()
    drawStatus()
    return
  end

  drawHeader()
  drawFileList()
  drawSidebar()

  if state.mode == "confirm" then
    drawConfirm()
  elseif state.mode == "input" then
    drawInput()
  else
    drawStatus()
  end
end

-- ── Actions ────────────────────────────────────────────────────────────────

local function setStatus(msg, ok)
  state.status = msg
  state.statusOK = (ok ~= false)
  drawStatus()
end

local function refreshFiles()
  setStatus("Loading directory...")
  local ok, data = sendCmd("LIST", state.path)
  if ok then
    state.files = serial.unserialize(data) or {}
    buildDisplay()
    clampCursor()
    setStatus("Ready  — /" .. state.path .. "  (" .. #state.files .. " items)")
  else
    setStatus("Error: " .. (data or "LIST failed"), false)
  end
end

local function refreshStats()
  local ok, data = sendCmd("STAT")
  if ok then state.stats = serial.unserialize(data) end
end

local function fullRefresh()
  refreshFiles()
  refreshStats()
  redraw()
end

local function openSelected()
  local f = state.display[state.cursor]
  if not f then return end
  if f.up then
    local parts = {}
    for p in state.path:gmatch("[^/]+") do table.insert(parts, p) end
    table.remove(parts)
    state.path = table.concat(parts, "/")
    state.cursor = 1; state.scroll = 0
    refreshFiles(); redraw()
  elseif f.isDir then
    state.path = state.path == "" and f.name or (state.path .. "/" .. f.name)
    state.cursor = 1; state.scroll = 0
    refreshFiles(); redraw()
  else
    -- Download
    local rel = state.path == "" and f.name or (state.path .. "/" .. f.name)
    setStatus("Downloading " .. f.name .. "...")
    local ok, data = sendCmd("READ", rel)
    if ok then
      if not fs.exists(DL_DIR) then fs.makeDirectory(DL_DIR) end
      local file = io.open(DL_DIR .. f.name, "wb")
      if file then
        file:write(data); file:close()
        setStatus("Downloaded → " .. DL_DIR .. f.name)
      else
        setStatus("Error: cannot write locally", false)
      end
    else
      setStatus("Download failed: " .. (data or ""), false)
    end
  end
end

local function promptInput(prompt, cb)
  state.mode = "input"
  state.inputPrompt = prompt
  state.inputBuf = ""
  state.inputCB = cb
  drawInput()
end

local function promptConfirm(msg, cb)
  state.mode = "confirm"
  state.confirmMsg = msg
  state.confirmCB = cb
  redraw()
end

local function doDelete()
  local f = state.display[state.cursor]
  if not f or f.up then return end
  local rel = state.path == "" and f.name or (state.path .. "/" .. f.name)
  promptConfirm(
    "Delete: " .. rel .. "\n\nThis action cannot be undone!",
    function()
      setStatus("Deleting...")
      local ok, data = sendCmd("DELETE", rel)
      if ok then
        setStatus("Deleted: " .. f.name)
        fullRefresh()
      else
        setStatus("Delete failed: " .. (data or ""), false)
        redraw()
      end
    end
  )
end

local function doMkdir()
  promptInput("New folder name", function(name)
    if not name or not name:match("%S") then
      state.mode = "browse"; drawStatus(); return
    end
    name = name:gsub("%s+$","")
    local rel = state.path == "" and name or (state.path .. "/" .. name)
    local ok, data = sendCmd("MKDIR", rel)
    if ok then
      setStatus("Created: " .. name)
      fullRefresh()
    else
      setStatus("Mkdir failed: " .. (data or ""), false)
      state.mode = "browse"; redraw()
    end
  end)
end

local function doUpload()
  promptInput("Local file path to upload", function(path)
    if not path or not path:match("%S") then
      state.mode = "browse"; drawStatus(); return
    end
    path = path:gsub("%s+$","")
    local f = io.open(path, "rb")
    if not f then
      setStatus("Cannot open: " .. path, false)
      state.mode = "browse"; redraw(); return
    end
    local data = f:read("*a"); f:close()
    local fname = path:match("[^/\\]+$") or "file"
    local rel = state.path == "" and fname or (state.path .. "/" .. fname)
    setStatus("Uploading " .. fname .. " (" .. fmt(#data) .. ")...")
    state.mode = "browse"
    redraw()
    local ok, resp = sendCmd("WRITE", rel, data)
    if ok then
      setStatus("Uploaded: " .. fname)
      fullRefresh()
    else
      setStatus("Upload failed: " .. (resp or ""), false)
      redraw()
    end
  end)
end

local function doLogs()
  setStatus("Fetching logs...")
  local ok, data = sendCmd("LOGS", "150")
  if ok then
    state.logs = serial.unserialize(data) or {}
    state.logScroll = math.max(0, #state.logs - (H - 7))
    state.mode = "logs"
    redraw()
    drawStatus("Showing " .. #state.logs .. " log entries")
  else
    setStatus("Logs fetch failed: " .. (data or ""), false)
  end
end

-- ── Input handler for text input mode ─────────────────────────────────────

local function handleInputKey(char, code)
  if code == keyboard.keys.enter then
    local val = state.inputBuf
    state.mode = "browse"
    if state.inputCB then state.inputCB(val) end
  elseif code == keyboard.keys.escape then
    state.mode = "browse"
    state.inputBuf = ""
    drawStatus("Cancelled")
    redraw()
  elseif code == keyboard.keys.back then
    if #state.inputBuf > 0 then
      state.inputBuf = state.inputBuf:sub(1, -2)
      drawInput()
    end
  elseif char and char >= 32 and char < 256 then
    state.inputBuf = state.inputBuf .. string.char(char)
    drawInput()
  end
end

-- ── Connect screen ─────────────────────────────────────────────────────────

local function showConnect(msg)
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")
  local cy = math.floor(H / 2)

  put(math.floor((W - 16) / 2), cy - 2, "┌──────────────┐", C.border, C.bg)
  put(math.floor((W - 16) / 2), cy - 1, "│  RAID-NET    │", C.accent, C.bg)
  put(math.floor((W - 16) / 2), cy,     "│  Connecting  │", C.gray,   C.bg)
  put(math.floor((W - 16) / 2), cy + 1, "└──────────────┘", C.border, C.bg)

  put(math.floor((W - #msg) / 2), cy + 3, msg, C.yellow, C.bg)
end

-- ── Boot ───────────────────────────────────────────────────────────────────

modem.open(PORT)

-- Try broadcast discovery
showConnect("Broadcasting discovery...")
modem.broadcast(PORT, "PING")
local _, _, from, port2, _, resp = event.pull(TIMEOUT, "modem_message")
if resp == "PONG" and port2 == PORT then
  SERVER = from
  showConnect("Found server: " .. SERVER:sub(1,8))
  os.sleep(0.5)
else
  showConnect("No server found. Enter server address:")
  gpu.setForeground(C.white)
  gpu.setBackground(C.bg)
  term.setCursor(math.floor(W/2) - 15, math.floor(H/2) + 5)
  local input = term.read()
  if input then SERVER = input:gsub("%s+", "") end
end

if not SERVER or #SERVER < 5 then
  gpu.setBackground(C.bg); gpu.fill(1,1,W,H," ")
  put(2, H/2, "No server address. Exiting.", C.red, C.bg)
  os.sleep(2)
  modem.close(PORT)
  return
end

-- Initial load
refreshFiles()
refreshStats()
redraw()

-- ── Main event loop ────────────────────────────────────────────────────────

local running = true
while running do
  local ev, _, char, code = event.pull("key_down")
  if ev == "key_down" then

    if state.mode == "input" then
      handleInputKey(char, code)

    elseif state.mode == "confirm" then
      if char == string.byte("y") or char == string.byte("Y") then
        local cb = state.confirmCB
        state.mode = "browse"
        if cb then cb() end
      else
        state.mode = "browse"
        setStatus("Cancelled")
        redraw()
      end

    elseif state.mode == "logs" then
      if code == keyboard.keys.up then
        state.logScroll = math.max(0, state.logScroll - 1)
        drawLogs()
      elseif code == keyboard.keys.down then
        state.logScroll = math.min(math.max(0, #state.logs - (H-7)), state.logScroll + 1)
        drawLogs()
      elseif code == keyboard.keys.escape
          or char == string.byte("l") or char == string.byte("L") then
        state.mode = "browse"
        redraw()
      end

    else  -- browse mode
      if code == keyboard.keys.up then
        state.cursor = math.max(1, state.cursor - 1)
        drawFileList(); drawStatus()
      elseif code == keyboard.keys.down then
        state.cursor = math.min(#state.display, state.cursor + 1)
        drawFileList(); drawStatus()
      elseif code == keyboard.keys.enter then
        openSelected()
      elseif code == keyboard.keys.back then
        if state.path ~= "" then
          local parts = {}
          for p in state.path:gmatch("[^/]+") do table.insert(parts, p) end
          table.remove(parts)
          state.path = table.concat(parts, "/")
          state.cursor = 1; state.scroll = 0
          refreshFiles(); redraw()
        end
      elseif char == string.byte("r") or char == string.byte("R") then
        fullRefresh()
      elseif char == string.byte("l") or char == string.byte("L") then
        doLogs()
      elseif char == string.byte("x") or char == string.byte("X") then
        doDelete()
      elseif char == string.byte("m") or char == string.byte("M") then
        doMkdir()
      elseif char == string.byte("u") or char == string.byte("U") then
        doUpload()
      elseif char == string.byte("q") or char == string.byte("Q") then
        running = false
      end
    end
  end
end

-- Cleanup
modem.close(PORT)
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
gpu.fill(1, 1, W, H, " ")
gpu.set(2, 2, "RAID-NET disconnected.")
