-- ╔══════════════════════════════════════════════╗
-- ║         RAID-NET SERVER  v1.0                ║
-- ║   Place this on your RAID machine            ║
-- ║   Requires: modem, gpu, screen               ║
-- ╚══════════════════════════════════════════════╝

local component = require("component")
local event     = require("event")
local fs        = require("filesystem")
local serial    = require("serialization")
local computer  = require("computer")
local term      = require("term")

local modem = component.modem
modem.setStrength(400)
local gpu   = component.isAvailable("gpu") and component.gpu or nil

-- ── CONFIG ─────────────────────────────────────────────────────────────────
local PORT      = 1337
local RAID_PATH = "/mnt/"         -- browse all mounted RAID volumes
local LOG_FILE  = "/var/raidnet.log"
local MAX_CHUNK = 32000           -- max bytes per modem packet
-- ───────────────────────────────────────────────────────────────────────────

local W, H = gpu and gpu.getResolution() or 80, 25

local C = {
  bg       = 0x050510,
  panel    = 0x0A0A20,
  accent   = 0x0066FF,
  cyan     = 0x00EEFF,
  green    = 0x00FF88,
  yellow   = 0xFFCC00,
  red      = 0xFF3355,
  white    = 0xEEEEFF,
  gray     = 0x556677,
  darkgray = 0x1A2030,
  border   = 0x223355,
}

-- Track connected clients and activity
local clients   = {}   -- addr -> {lastSeen, reqCount, name}
local logLines  = {}   -- in-memory log ring buffer
local reqTotal  = 0

-- ── Helpers ────────────────────────────────────────────────────────────────

local function fg(c) if gpu then gpu.setForeground(c) end end
local function bg(c) if gpu then gpu.setBackground(c) end end

local function writeAt(x, y, text, fgc, bgc)
  if not gpu then return end
  if fgc then gpu.setForeground(fgc) end
  if bgc then gpu.setBackground(bgc) end
  gpu.set(x, y, text)
end

local function fillRow(y, ch, fgc, bgc)
  if not gpu then return end
  if fgc then gpu.setForeground(fgc) end
  if bgc then gpu.setBackground(bgc) end
  gpu.fill(1, y, W, 1, ch or " ")
end

local function formatSize(bytes)
  if bytes >= 1073741824 then return string.format("%.2f GB", bytes/1073741824)
  elseif bytes >= 1048576 then return string.format("%.1f MB",  bytes/1048576)
  elseif bytes >= 1024    then return string.format("%.1f KB",  bytes/1024)
  else                         return bytes .. " B"
  end
end

local function timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

-- ── Logging ────────────────────────────────────────────────────────────────

local function writeLog(addr, action, detail)
  local short = addr:sub(1, 8)
  local entry = string.format("[%s] %s | %-8s | %s",
    timestamp(), short, action, detail or "")

  -- Append to file
  local f = io.open(LOG_FILE, "a")
  if f then f:write(entry .. "\n"); f:close() end

  -- In-memory buffer (keep last 200)
  table.insert(logLines, entry)
  if #logLines > 200 then table.remove(logLines, 1) end

  return entry
end

local function getLogs(count)
  count = math.min(count or 100, 500)
  -- Read from file, return last N lines
  local lines = {}
  local f = io.open(LOG_FILE, "r")
  if f then
    for line in f:lines() do table.insert(lines, line) end
    f:close()
  end
  local out = {}
  local start = math.max(1, #lines - count + 1)
  for i = start, #lines do table.insert(out, lines[i]) end
  return out
end

-- ── UI ─────────────────────────────────────────────────────────────────────

local logPanelY = 10  -- where the scrolling log starts

local function drawStatic()
  if not gpu then return end
  -- Full clear
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")

  -- Top border
  fillRow(1, "─", C.border, C.bg)

  -- Header
  gpu.setBackground(C.panel)
  gpu.fill(1, 2, W, 2, " ")
  writeAt(3,  2, "▓▓ RAID-NET SERVER", C.cyan,   C.panel)
  writeAt(3,  3, "v1.0  |  PORT: " .. PORT, C.gray, C.panel)

  -- Server address
  local addr = modem.address:sub(1, 16) .. "..."
  writeAt(W - 22, 2, "ADDR: " .. modem.address:sub(1,8), C.yellow, C.panel)

  -- RAID path
  writeAt(W - 22, 3, "RAID: " .. RAID_PATH, C.gray, C.panel)

  fillRow(4, "─", C.border, C.bg)

  -- Stats row labels
  writeAt(2,  5, "Requests:", C.gray,  C.bg)
  writeAt(2,  6, "Clients:",  C.gray,  C.bg)
  writeAt(2,  7, "Space:",    C.gray,  C.bg)
  writeAt(2,  8, "Uptime:",   C.gray,  C.bg)

  fillRow(9, "─", C.border, C.bg)

  -- Log panel header
  writeAt(2, logPanelY, "[ ACCESS LOG ]", C.accent, C.bg)
  fillRow(logPanelY + 1, "─", C.darkgray, C.bg)
end

local startTime = computer.uptime()

local function updateStats()
  if not gpu then return end
  -- Requests
  writeAt(14, 5, tostring(reqTotal) .. "     ", C.green, C.bg)

  -- Clients
  writeAt(14, 6, tostring(#clients) .. "     ", C.yellow, C.bg)

  -- Space: sum all filesystem components
  local total, used = 0, 0
  for addr, _ in component.list("filesystem") do
    pcall(function()
      local sp = component.invoke(addr, "spaceTotal")
      local su = component.invoke(addr, "spaceUsed")
      if sp and sp > 0 then
        total = total + sp
        used  = used  + (su or 0)
      end
    end)
  end
  if total > 0 then
    local pct = math.floor((used / total) * 100)
    local info = formatSize(used) .. " / " .. formatSize(total) .. "  (" .. pct .. "% used)"
    writeAt(14, 7, info .. string.rep(" ", 20), C.white, C.bg)
  else
    writeAt(14, 7, "N/A (no filesystems found)    ", C.red, C.bg)
  end

  -- Uptime
  local up = math.floor(computer.uptime() - startTime)
  local h  = math.floor(up / 3600)
  local m  = math.floor((up % 3600) / 60)
  local s  = up % 60
  writeAt(14, 8, string.format("%02d:%02d:%02d", h, m, s) .. "    ", C.cyan, C.bg)
end

local scrollLog = {}   -- what's displayed in log panel

local function pushLogLine(line)
  table.insert(scrollLog, line)
  local maxRows = H - logPanelY - 2
  if #scrollLog > maxRows then table.remove(scrollLog, 1) end
  if not gpu then return end

  -- Redraw log area
  for i, ln in ipairs(scrollLog) do
    local y = logPanelY + 1 + i
    gpu.setBackground(C.bg)
    gpu.fill(1, y, W, 1, " ")

    -- Colorize: timestamp gray, addr yellow, action cyan, rest white
    local ts, addr, action, detail = ln:match("^(%[.-%]) (%S+) | (%S+)%s*| (.*)$")
    if ts then
      local x = 2
      writeAt(x, y, ts,     C.gray,   C.bg); x = x + #ts + 1
      writeAt(x, y, addr,   C.yellow, C.bg); x = x + #addr + 3
      writeAt(x, y, action, C.cyan,   C.bg); x = x + 9
      if detail and #detail > 0 then
        -- Truncate if needed
        local maxW = W - x - 1
        if #detail > maxW then detail = detail:sub(1, maxW - 1) .. "…" end
        writeAt(x, y, detail, C.white, C.bg)
      end
    else
      writeAt(2, y, ln:sub(1, W - 3), C.gray, C.bg)
    end
  end
end

-- ── File Ops ───────────────────────────────────────────────────────────────

local function safePath(rel)
  -- Prevent path traversal
  local full = RAID_PATH .. (rel or "")
  if not full:sub(1, #RAID_PATH) == RAID_PATH then return nil end
  return full
end

local function listDir(path)
  local full = safePath(path)
  if not full or not fs.isDirectory(full) then return nil, "Not a directory" end
  local out = {}
  for name in fs.list(full) do
    local fp = full .. name
    local isDir = fs.isDirectory(fp)
    local size  = isDir and 0 or (fs.size(fp) or 0)
    table.insert(out, {name=name, isDir=isDir, size=size})
  end
  table.sort(out, function(a,b)
    if a.isDir ~= b.isDir then return a.isDir end
    return a.name < b.name
  end)
  return out
end

-- ── Request Handler ────────────────────────────────────────────────────────

local function handleMsg(_, _, from, port, _, cmd, ...)
  if port ~= PORT then return end
  local args = {...}

  -- Track client
  if not clients[from] then
    clients[from] = {lastSeen=0, reqCount=0}
  end
  clients[from].lastSeen = computer.uptime()
  clients[from].reqCount = clients[from].reqCount + 1
  reqTotal = reqTotal + 1

  local function reply(status, data)
    modem.send(from, PORT, status, data or "")
  end

  -- Rebuild clients list (remove stale > 5min)
  local fresh = {}
  for addr, info in pairs(clients) do
    if computer.uptime() - info.lastSeen < 300 then
      fresh[addr] = info
    end
  end
  clients = fresh

  updateStats()

  -- ── Commands ──
  if cmd == "PING" then
    reply("PONG", "RAID-NET Online")
    local line = writeLog(from, "PING", "")
    pushLogLine(line)

  elseif cmd == "LIST" then
    local path = args[1] or ""
    local files, err = listDir(path)
    if files then
      reply("OK", serial.serialize(files))
      local line = writeLog(from, "LIST", "/" .. path .. "  (" .. #files .. " items)")
      pushLogLine(line)
    else
      reply("ERR", err)
      local line = writeLog(from, "LIST", "FAILED: " .. (err or ""))
      pushLogLine(line)
    end

  elseif cmd == "READ" then
    local rel  = args[1] or ""
    local full = safePath(rel)
    if full and fs.exists(full) and not fs.isDirectory(full) then
      local f = io.open(full, "rb")
      if f then
        local data = f:read("*a"); f:close()
        reply("OK", data)
        local line = writeLog(from, "READ", rel .. "  (" .. formatSize(#data) .. ")")
        pushLogLine(line)
      else
        reply("ERR", "Cannot open file")
      end
    else
      reply("ERR", "File not found: " .. rel)
      local line = writeLog(from, "READ", "FAIL: " .. rel)
      pushLogLine(line)
    end

  elseif cmd == "WRITE" then
    local rel  = args[1] or ""
    local data = args[2] or ""
    local full = safePath(rel)
    if not full then reply("ERR", "Bad path"); return end
    -- Ensure parent dir exists
    local dir = fs.path(full)
    if not fs.exists(dir) then fs.makeDirectory(dir) end
    local f = io.open(full, "wb")
    if f then
      f:write(data); f:close()
      reply("OK", "Written " .. formatSize(#data))
      local line = writeLog(from, "WRITE", rel .. "  (" .. formatSize(#data) .. ")")
      pushLogLine(line)
      updateStats()
    else
      reply("ERR", "Cannot write")
      local line = writeLog(from, "WRITE", "FAIL: " .. rel)
      pushLogLine(line)
    end

  elseif cmd == "DELETE" then
    local rel  = args[1] or ""
    local full = safePath(rel)
    if full and fs.exists(full) then
      local ok = fs.remove(full)
      if ok then
        reply("OK", "Deleted")
        local line = writeLog(from, "DELETE", rel)
        pushLogLine(line)
        updateStats()
      else
        reply("ERR", "Delete failed (directory not empty?)")
      end
    else
      reply("ERR", "Not found: " .. rel)
    end

  elseif cmd == "MKDIR" then
    local rel  = args[1] or ""
    local full = safePath(rel)
    if full then
      local ok = fs.makeDirectory(full)
      if ok then
        reply("OK", "Created")
        local line = writeLog(from, "MKDIR", rel)
        pushLogLine(line)
      else
        reply("ERR", "Cannot create directory")
      end
    else
      reply("ERR", "Bad path")
    end

  elseif cmd == "STAT" then
    local total, used = 0, 0
    for addr, _ in component.list("filesystem") do
      pcall(function()
        local sp = component.invoke(addr, "spaceTotal")
        local su = component.invoke(addr, "spaceUsed")
        if sp and sp > 0 then
          total = total + sp
          used  = used  + (su or 0)
        end
      end)
    end
    reply("OK", serial.serialize({
      total = total,
      used  = used,
      free  = total - used,
    }))
    local line = writeLog(from, "STAT", "")
    pushLogLine(line)

  elseif cmd == "LOGS" then
    local count = tonumber(args[1]) or 100
    local logs = getLogs(count)
    reply("OK", serial.serialize(logs))
    local line = writeLog(from, "LOGS", "requested " .. count)
    pushLogLine(line)

  else
    reply("ERR", "Unknown command: " .. tostring(cmd))
    local line = writeLog(from, "UNKNOWN", tostring(cmd))
    pushLogLine(line)
  end
end

-- ── Boot ───────────────────────────────────────────────────────────────────

-- Ensure dirs
if not fs.exists("/var") then fs.makeDirectory("/var") end
if not fs.exists(RAID_PATH) then
  fs.makeDirectory(RAID_PATH)
end

modem.open(PORT)
drawStatic()
updateStats()

local bootLine = writeLog("SYSTEM", "START", "Server started on port " .. PORT)
pushLogLine(bootLine)

event.listen("modem_message", handleMsg)

-- Update stats every 5 seconds
local function tick()
  while true do
    os.sleep(5)
    updateStats()
  end
end

-- Run ticker in background via coroutine via event timer
local timer = event.timer(5, function() updateStats() end, math.huge)

print() -- cursor below UI
-- Keep alive
while true do
  os.sleep(1)
end
