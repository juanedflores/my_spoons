local _store = {}
local obj = {}

-- Only these keys represent *layout/config* settings. Changing one of them
-- should rebuild the canvas. Everything else (timers, task name, elapsed
-- time, etc.) changes many times per second and must NOT rebuild the canvas,
-- or the canvas gets torn down/recreated 3x/sec, which was silently
-- swallowing the "pending tasks" flash and could cause missed/late redraws.
local CONFIG_KEYS = {
  width = true,
  height = true,
  voice = true,
  mainres = true,
  blink_max = true,
}

setmetatable(obj, {
  __index = function(_, k)
    return _store[k]
  end,
  __newindex = function(t, k, v)
    rawset(_store, k, v)
    if t._init_done and CONFIG_KEYS[k] then
      t:init()
    end
  end,
})
obj.__index = obj

-- Metadata
obj.name = 'TaskWarrior'
obj.version = '1.0'
obj.author = 'juanedflores <juanedflores@gmail.com>'
obj.homepage = 'https://github.com/juanedflores/my_spoons'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

local logger = hs.logger.new('TaskWarrior')
obj.logger = logger

obj.pending_tasks = {}

-- Defaults
obj._attribs = {
  task_name = '',
  taskStarted = false,
  task_start_epoch = nil, -- epoch seconds when the current task was started
  break_start_epoch = nil, -- epoch seconds when the current break started
  total_time = 0.0,
  _last_check_time = 0.0,
  _last_move_time = 0.0,
  width = 1000,
  height = 400,
  voice = nil,
  mainres = 0,
  blink_max = 12,
}

local front = false
local ranY = 0
local spaces = 0
local myWatcher = nil

local textattrbs = {
  font = { name = 'Impact', size = 24 },
  paragraphStyle = { lineHeightMultiple = 1.1, linebreak = clip },
}
local blue_col = { color = { hex = '#36A3D9' } }
local orange_col = { color = { hex = '#FF7733' } }
local green_col = { color = { hex = '#BBCC52' } }
local red_col = { color = { hex = '#F07178' } }

local display_text = hs.styledtext.new('break time', textattrbs):setStyle(blue_col, 0, 11)

for k, v in pairs(obj._attribs) do
  obj[k] = v
end

--- Converts a Taskwarrior UTC timestamp (e.g. "20260912T183000Z") into a
--- local epoch time. Taskwarrior always reports timestamps in UTC/Zulu time;
--- the old implementation hard-coded a "+1 hour" DST fudge factor which was
--- applied inconsistently between code paths, producing elapsed times that
--- were off by an hour depending on which branch ran. This computes the
--- local UTC offset dynamically (so it's always correct, DST included).
local function parseTaskTimestamp(s)
  local y, mo, d, h, mi, se = s:match('(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)')
  if not y then
    return nil
  end
  local naiveAsLocal = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
    isdst = false,
  })
  local now = os.time()
  local nowUtcTbl = os.date('!*t', now)
  nowUtcTbl.isdst = false
  local utcOffset = now - os.time(nowUtcTbl)
  return naiveAsLocal + utcOffset
end

--- Formats a duration in seconds as hours/minutes/seconds components.
local function formatElapsed(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60
  return hours, minutes, secs
end

--- TaskWarrior:init()
--- Method
--- init.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TaskWarrior object
function obj:init()
  if not self.canvas then
    self.canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
  end

  self.canvas[1] =
    { type = 'rectangle', fillColor = { hex = '#000000', alpha = 0.0 }, strokeColor = { hex = '#000000', alpha = 0.0 } }
  self.canvas[2] = {
    type = 'text',
    text = display_text,
  }
  -- `floating` sits above normal app windows so the marquee actually stays
  -- visible over whatever you're working in. The previous `desktopIcon`
  -- level is one of the *lowest* levels (roughly where Finder desktop icons
  -- sit) and would get hidden behind any regular window.
  self.canvas:level(hs.canvas.windowLevels.floating)
  self.canvas:bringToFront()

  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()
  self.canvas:frame({
    x = 0,
    y = ranY,
    w = mainRes.w,
    h = 40,
  })

  self._init_done = true
  return self
end

--- Runs `task export active` (throttled) and updates obj's task/break state.
--- This is the single source of truth for task/break transitions; it is
--- called both by the pathwatcher (for near-instant updates) and by the
--- animation tick (as a polling fallback, in case a filesystem event is
--- ever missed) so state never gets stuck.
local function checkTasks2()
  if obj.total_time <= obj._last_check_time + 2 then
    return
  end
  obj._last_check_time = obj.total_time

  local function taskCallback(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      logger.e('task export active failed: ' .. tostring(stdErr))
      return
    end

    local result = stdOut
    local hasActiveTask = result ~= '[\n]\n'

    if not hasActiveTask then
      if obj.taskStarted then
        -- A task just stopped or completed: enter break mode and reset the
        -- break timer so it starts counting from zero, not from wherever it
        -- last was.
        obj.taskStarted = false
        obj.task_name = ''
        obj.task_start_epoch = nil
        obj.break_start_epoch = os.time()
      elseif not obj.break_start_epoch then
        obj.break_start_epoch = os.time()
      end
      return
    end

    local _, descEnd = string.find(result, 'description')
    local descSub = string.sub(result, descEnd + 2)
    local nameMatch = string.match(descSub, '%b""')
    local name = nameMatch and string.gsub(nameMatch, '"', '') or ''

    local _, startEnd = string.find(result, 'start')
    local startSub = string.sub(result, startEnd + 2)
    local startMatch = string.match(startSub, '%b""')
    local startStr = startMatch and string.gsub(startMatch, '"', '')

    local startEpoch = startStr and parseTaskTimestamp(startStr)

    if not obj.taskStarted or obj.task_name ~= name or obj.task_start_epoch ~= startEpoch then
      -- A (new) task just started, or the active task switched: reset the
      -- "time elapsed since start" timer to the task's real start time.
      obj.task_start_epoch = startEpoch
    end
    obj.taskStarted = true
    obj.task_name = name
  end

  hs.task.new('/opt/homebrew/bin/task', taskCallback, { 'export', 'active' }):start()
end

function obj:tick_timer_animate()
  return hs.timer.doEvery(0.3, function()
    obj.total_time = obj.total_time + 0.3
    spaces = spaces + 1
    if spaces >= 600 then
      spaces = 0
    end

    local mainScreen = hs.screen.primaryScreen()
    local mainRes = mainScreen:fullFrame()
    if spaces == 550 and obj.total_time > obj._last_move_time + 1 then
      obj._last_move_time = obj.total_time
      ranY = math.random(0, mainRes.h)
      self.canvas:frame({ x = 0, y = ranY, w = mainRes.w, h = 40 })
      if front == false then
        front = true
        self.canvas:bringToFront()
      end
    end

    local spaces_string = string.rep(' ', spaces)

    if self.taskStarted and self.task_start_epoch then
      local h, m, s = formatElapsed(os.time() - self.task_start_epoch)
      local time_text = string.format('%d hours %d minutes %d seconds', h, m, s)

      local prefix = spaces_string .. 'current task: '
      local nameStart = #prefix
      local nameEnd = nameStart + #self.task_name
      local full = prefix .. self.task_name .. ' | elapsed: ' .. time_text

      display_text = hs.styledtext
        .new(full, textattrbs)
        :setStyle(green_col, 0, nameStart)
        :setStyle(orange_col, nameStart, nameEnd)
        :setStyle(red_col, nameEnd, #full)
    else
      local h, m, s = formatElapsed(os.time() - (self.break_start_epoch or os.time()))
      local full = spaces_string .. string.format('break time. elapsed time: %d hours %d minutes %d seconds', h, m, s)
      display_text = hs.styledtext.new(full, textattrbs):setStyle(blue_col, 0, #full)
    end

    self.canvas[2].text = display_text

    -- Polling fallback: checkTasks2() self-throttles to at most once every
    -- ~2 seconds, so calling it every tick is cheap and guarantees state
    -- eventually catches up even if a pathwatcher event is ever missed.
    checkTasks2()
  end)
end

function obj:tick_timer_fn()
  return hs.timer.doEvery(60, function()
    if not self.taskStarted then
      local myTask = hs.task.new('/opt/homebrew/bin/task', function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
          hs.alert.show('There are ' .. string.gsub(stdOut, '%D', '') .. ' Tasks Pending')
        else
          hs.alert.show('Task failed with exit code: ' .. exitCode)
        end
      end, { 'status:pending', 'count' })

      local breakMinutes = math.floor((os.time() - (self.break_start_epoch or os.time())) / 60)
      if breakMinutes % 2 == 0 then
        myTask:start()
      end
    end
  end)
end

--- TaskWarriorTwo:show()
--- Method
--- Show TaskWarrior
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TaskWarriorTwo object
function obj:show()
  if not self.break_start_epoch and not self.taskStarted then
    self.break_start_epoch = os.time()
  end

  -- show the canvas
  self.canvas:show()
  self.tick_timer = self:tick_timer_fn()
  -- timer for animating the canvas every 0.3 seconds
  self.animate_timer = self:tick_timer_animate()

  -- Watch the directory (not the single db file) and filter for the
  -- taskchampion db by name. Watching a single file is a known-flaky
  -- pattern in Hammerspoon/FSEvents when the underlying inode gets
  -- replaced; watching the containing directory is more robust. This is
  -- belt-and-suspenders alongside the polling fallback in the animate tick.
  myWatcher = hs.pathwatcher
    .new(os.getenv('HOME') .. '/.task/', function(files)
      for _, f in ipairs(files) do
        if f:find('taskchampion%.sqlite3') then
          checkTasks2()
          break
        end
      end
    end)
    :start()

  return self
end

return obj
