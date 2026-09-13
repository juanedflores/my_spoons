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
  task_uuid = nil,
  task_project = nil,
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

  -- Urgent-task nag settings. A pending task whose Taskwarrior `urgency`
  -- score exceeds this threshold (and that you aren't already working on)
  -- triggers the big attention-grabbing banner. Taskwarrior's own urgency
  -- score already blends priority, due-date proximity, age, etc., so we
  -- lean on it rather than re-deriving our own.
  nag_urgency_threshold = 9,
  nag_hold_seconds = 12,
  _last_urgent_check = 0.0,

  -- Pre-filled bedtime for obj:logSleep's prompt (24h "HH:MM"), so a normal
  -- morning is just the hotkey + Enter. Wake time is always pre-filled with
  -- the current time instead, since that's usually right when you log it.
  sleep_default_bedtime = '23:00',
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

--- Formats an hour-of-day float (e.g. 14.75) as a clock time (e.g. "2:45pm").
local function formatHourOfDay(hour)
  local totalMinutes = math.floor(hour * 60 + 0.5)
  local h24 = math.floor(totalMinutes / 60) % 24
  local m = totalMinutes % 60
  local period = h24 < 12 and 'am' or 'pm'
  local h12 = h24 % 12
  if h12 == 0 then
    h12 = 12
  end
  return string.format('%d:%02d%s', h12, m, period)
end

--- Parses an ISO-8601 duration string (as Taskwarrior emits for `duration`
--- typed UDAs, e.g. "PT15M", "PT1H30M", "P1D") into total minutes.
local function parseISODuration(s)
  if not s then
    return nil
  end
  local datePart, timePart = s:match('^P([^T]*)T?(.*)$')
  if not datePart then
    return nil
  end
  local totalMinutes = 0
  local days = tonumber(datePart:match('(%d+)D')) or 0
  local weeks = tonumber(datePart:match('(%d+)W')) or 0
  totalMinutes = totalMinutes + days * 1440 + weeks * 10080
  local hours = tonumber(timePart:match('(%d+)H')) or 0
  local minutes = tonumber(timePart:match('(%d+)M')) or 0
  totalMinutes = totalMinutes + hours * 60 + minutes
  return totalMinutes
end

--- Formats a minute count as "X hours Y minutes" for display.
local function formatMinutes(totalMinutes)
  if not totalMinutes then
    return nil
  end
  totalMinutes = math.floor(totalMinutes + 0.5)
  local h = math.floor(totalMinutes / 60)
  local m = totalMinutes % 60
  if h > 0 and m > 0 then
    return string.format('%d hour%s %d minute%s', h, h == 1 and '' or 's', m, m == 1 and '' or 's')
  elseif h > 0 then
    return string.format('%d hour%s', h, h == 1 and '' or 's')
  else
    return string.format('%d minute%s', m, m == 1 and '' or 's')
  end
end

--- Builds the "Juan, you should really be doing X right now" nag message
--- for a task exported (via hs.json.decode) from `task export`.
local function buildNagMessage(task)
  local parts = { string.format('Juan, you should really be doing "%s" right now', task.description) }

  local estimateMinutes = parseISODuration(task.estimate)
  if estimateMinutes then
    table.insert(parts, 'it will only take ' .. formatMinutes(estimateMinutes))
  end

  if task.due then
    local dueEpoch = parseTaskTimestamp(task.due)
    if dueEpoch then
      local diff = dueEpoch - os.time()
      if diff < 0 then
        table.insert(parts, 'it is already overdue')
      elseif diff < 24 * 3600 then
        table.insert(parts, 'it is due in ' .. formatMinutes(diff / 60))
      end
    end
  end

  return table.concat(parts, ', ') .. '.'
end

local PIE_COLORS = {
  '#36A3D9',
  '#FF7733',
  '#BBCC52',
  '#F07178',
  '#C792EA',
  '#89DDFF',
  '#F78C6C',
  '#82AAFF',
  '#FFCB6B',
  '#C3E88D',
}

-- WORK, PERSONAL and "no project" always get these exact colors, on every
-- render, forever - not just consistent within one panel like the old
-- first-seen-order assignment was. Assign your Taskwarrior tasks
-- project:WORK or project:PERSONAL to use them.
local FIXED_CATEGORY_COLORS = {
  WORK = '#36A3D9',
  PERSONAL = '#FF7733',
  SLEEP = '#2E2E5E',
  none = '#AAAAAA',
}
local CATEGORY_LABELS = {
  WORK = 'Work',
  PERSONAL = 'Personal',
  SLEEP = 'Sleep',
  none = 'Uncategorized',
}

--- Case-insensitively matches a raw Taskwarrior project name against the
--- fixed categories (WORK/PERSONAL/SLEEP) so project:personal and
--- project:Work land in the same bucket as project:PERSONAL and
--- project:WORK, instead of becoming their own separate lowercase/mixed
--- case category. Anything else passes through unchanged; nil/empty
--- becomes 'none'.
local function canonicalCategory(project)
  if not project or project == '' then
    return 'none'
  end
  local upper = project:upper()
  if FIXED_CATEGORY_COLORS[upper] then
    return upper
  end
  return project
end

--- Returns a color for a project/category name. WORK, PERSONAL and "no
--- project" (see FIXED_CATEGORY_COLORS) always get the same fixed color.
--- Any other project name gets a color deterministically hashed out of the
--- remaining palette, so it's likewise stable across every render/session
--- rather than depending on which projects happen to appear that day.
local function stableColorForProject(project)
  if FIXED_CATEGORY_COLORS[project] then
    return FIXED_CATEGORY_COLORS[project]
  end

  local remaining = {}
  for _, c in ipairs(PIE_COLORS) do
    local isFixed = false
    for _, fixedColor in pairs(FIXED_CATEGORY_COLORS) do
      if c == fixedColor then
        isFixed = true
        break
      end
    end
    if not isFixed then
      table.insert(remaining, c)
    end
  end

  local hash = 0
  for i = 1, #project do
    hash = (hash * 31 + string.byte(project, i)) % 1000000
  end
  return remaining[(hash % #remaining) + 1]
end

--- Display label for a category/project name (e.g. "none" -> "Uncategorized").
local function labelForCategory(category)
  return CATEGORY_LABELS[category] or category
end

--- Parses `timew export <range>` JSON output into total minutes per task
--- description. Taskwarrior's own on-modify.timewarrior hook always puts
--- the task description as the first tag on the Timewarrior interval it
--- creates (see ~/.task/hooks/on-modify.timewarrior), so that's what this
--- correlates on.
local function minutesByDescriptionFromTimewExport(jsonStr)
  local ok, intervals = pcall(hs.json.decode, jsonStr or '[]')
  if not ok or not intervals then
    intervals = {}
  end

  local totals = {}
  for _, iv in ipairs(intervals) do
    local description = iv.tags and iv.tags[1]
    if description and iv.start and iv['end'] then
      local s = parseTaskTimestamp(iv.start)
      local e = parseTaskTimestamp(iv['end'])
      if s and e and e > s then
        totals[description] = (totals[description] or 0) + (e - s) / 60
      end
    end
  end
  return totals
end

--- Groups a day's Timewarrior-tracked minutes (`minutesByDescription`, from
--- minutesByDescriptionFromTimewExport) by project, resolving each
--- description's project via `descToProject` (built from *every*
--- Taskwarrior task regardless of status - see descriptionToProject).
--- Driving this off tracked time rather than off `task export
--- status:completed` means a task that was only started/stopped - never
--- marked done - still shows up here, as long as Timewarrior actually
--- logged time against it that day, not just tasks completed that day.
--- Descriptions with no matching task at all (e.g. the Sleep entries from
--- obj:logSleep, which aren't Taskwarrior tasks) are skipped here; they
--- only ever belong on the timeline, not this "completed tasks" pie.
--- `completedJsonStr` (that day's `status:completed` export) is used only
--- to separately count completed-that-day tasks with no tracked time at
--- all (e.g. added and immediately `task done`d, never `task start`ed) -
--- those can't have a meaningful duration, so they're counted rather than
--- guessed at. Each bucket also keeps its individual tasks (largest first),
--- so buildPieColumn can draw one arc per task instead of one per project -
--- see obj:renderTimelineSelection's pie-arc highlight, which needs a
--- specific task's own arc to point at.
local function bucketizeTasks(minutesByDescription, descToProject, completedJsonStr)
  local totals, order, tasksByProject = {}, {}, {}
  for description, minutes in pairs(minutesByDescription) do
    local proj = descToProject[description]
    if proj then
      if not totals[proj] then
        totals[proj] = 0
        tasksByProject[proj] = {}
        table.insert(order, proj)
      end
      totals[proj] = totals[proj] + minutes
      table.insert(tasksByProject[proj], { description = description, minutes = minutes })
    end
  end

  local buckets = {}
  for _, proj in ipairs(order) do
    table.sort(tasksByProject[proj], function(a, b)
      return a.minutes > b.minutes
    end)
    table.insert(buckets, { project = proj, minutes = totals[proj], tasks = tasksByProject[proj] })
  end
  table.sort(buckets, function(a, b)
    return a.minutes > b.minutes
  end)

  local ok, completedTasks = pcall(hs.json.decode, completedJsonStr)
  if not ok or not completedTasks then
    completedTasks = {}
  end
  local untracked = 0
  for _, t in ipairs(completedTasks) do
    if not minutesByDescription[t.description] then
      untracked = untracked + 1
    end
  end

  return buckets, untracked
end

-- U+25CF BLACK CIRCLE, used as a colored bullet in front of each legend
-- line so the whole line (bullet + text) can be centered as one run,
-- instead of a fixed-position swatch next to left-aligned text (which
-- looked off-center under the pie above it).
local LEGEND_BULLET = '\226\151\143'

--- Appends the canvas elements for one pie (wedges + legend) into
--- `elements`, centered at (centerX, centerY) with the given radius.
--- Returns the y-coordinate of the bottom of everything drawn, so the
--- caller can lay out content (like the timeline) below it. If `arcNavOut`
--- is given, one entry per task's own arc (description, project, center,
--- radius, start/end angle) is appended to it, so obj:renderTimelineSelection
--- can find and highlight the exact arc for whatever task block is
--- currently selected in the timeline below.
local function buildPieColumn(elements, buckets, untracked, centerX, centerY, radius, colorFor, arcNavOut)
  if #buckets == 0 then
    -- Distinguish "genuinely nothing completed" from "completed tasks
    -- exist, but none of them have a start time to measure duration from"
    -- (e.g. added and immediately `task done`d, never `task start`ed) -
    -- otherwise these look identical and the untracked count is lost.
    local message = untracked > 0
        and string.format('%d task%s completed\n(no time tracked)', untracked, untracked == 1 and '' or 's')
      or 'No tracked\ntasks'
    table.insert(elements, {
      type = 'circle',
      center = { x = centerX, y = centerY },
      radius = radius,
      fillColor = { hex = '#2A2A2A' },
      strokeColor = { hex = '#555555' },
      strokeWidth = 2,
    })
    table.insert(elements, {
      type = 'text',
      text = hs.styledtext.new(message, {
        font = { name = 'Helvetica', size = 18 },
        color = { hex = '#999999' },
        paragraphStyle = { alignment = 'center' },
      }),
      frame = { x = centerX - radius, y = centerY - 20, w = radius * 2, h = 70 },
    })
    return centerY + radius + 50
  end

  local totalMinutes = 0
  for _, b in ipairs(buckets) do
    totalMinutes = totalMinutes + b.minutes
  end

  local cumulative = -90 -- start at 12 o'clock instead of 3 o'clock
  for _, b in ipairs(buckets) do
    -- One arc per task (not one per project), so multiple tasks sharing a
    -- category still each get their own slice of that category's arc,
    -- thinly separated - rather than merging into a single indistinguishable
    -- wedge with no way to point back at one specific task.
    for _, t in ipairs(b.tasks) do
      local sliceAngle = (t.minutes / totalMinutes) * 360
      local startAngle, endAngle = cumulative, cumulative + sliceAngle
      if sliceAngle >= 359.99 then
        -- A lone task making up 100% of the pie is still an "arc" from
        -- -90 to 270 underneath, and hs.canvas strokes an arc's start/end
        -- radius even when they coincide - drawing as a plain circle
        -- instead avoids that stray seam line down the middle.
        table.insert(elements, {
          type = 'circle',
          center = { x = centerX, y = centerY },
          radius = radius,
          fillColor = { hex = colorFor(b.project) },
          strokeColor = { hex = '#3A3A3A' },
          strokeWidth = 1,
        })
      else
        table.insert(elements, {
          type = 'arc',
          center = { x = centerX, y = centerY },
          radius = radius,
          startAngle = startAngle,
          endAngle = endAngle,
          fillColor = { hex = colorFor(b.project) },
          strokeColor = { hex = '#3A3A3A' },
          strokeWidth = 1,
        })
      end
      if arcNavOut then
        table.insert(arcNavOut, {
          description = t.description,
          project = b.project,
          centerX = centerX,
          centerY = centerY,
          radius = radius,
          startAngle = startAngle,
          endAngle = endAngle,
        })
      end
      cumulative = endAngle
    end
  end

  -- Wider than the pie itself (radius*2): a long category name like
  -- "Uncategorized" plus a multi-unit duration and percentage easily
  -- exceeds that width, wrapped to a second line, and got silently clipped
  -- by the single-line frame height below - the percentage (and sometimes
  -- the duration's minutes) would just vanish rather than truncate visibly.
  -- The two pies' centers are panelW*0.46 apart, so this still leaves a
  -- comfortable gap between them at their closest.
  local legendLineW = 380
  local legendY = centerY + radius + 24
  for _, b in ipairs(buckets) do
    local pct = math.floor(b.minutes / totalMinutes * 100 + 0.5)
    local label = string.format('%s - %s (%d%%)', labelForCategory(b.project), formatMinutes(b.minutes), pct)
    local line = hs.styledtext
      .new(LEGEND_BULLET .. '  ' .. label, {
        font = { name = 'Helvetica', size = 16 },
        color = { hex = '#EEEEEE' },
        paragraphStyle = { alignment = 'center' },
      })
      :setStyle({ color = { hex = colorFor(b.project) } }, 0, #LEGEND_BULLET)
    table.insert(elements, {
      type = 'text',
      text = line,
      frame = { x = centerX - legendLineW / 2, y = legendY, w = legendLineW, h = 20 },
    })
    legendY = legendY + 24
  end

  if untracked > 0 then
    table.insert(elements, {
      type = 'text',
      text = hs.styledtext.new(
        string.format('+ %d task%s with no tracked time', untracked, untracked == 1 and '' or 's'),
        {
          font = { name = 'Helvetica', size = 13 },
          color = { hex = '#888888' },
          paragraphStyle = { alignment = 'center' },
        }
      ),
      frame = { x = centerX - legendLineW / 2, y = legendY + 4, w = legendLineW, h = 20 },
    })
    legendY = legendY + 24
  end

  return legendY
end

--- Maps task description -> project, from a `task ... export` JSON array.
--- Used to color timeline segments consistently with the pie charts, even
--- though Timewarrior intervals only carry the description as a tag.
local function descriptionToProject(jsonStr)
  local ok, tasks = pcall(hs.json.decode, jsonStr)
  if not ok or not tasks then
    tasks = {}
  end
  local map = {}
  for _, t in ipairs(tasks) do
    map[t.description] = canonicalCategory(t.project)
  end
  return map
end

--- Converts `timew export` JSON into a list of {startHour, endHour, project}
--- segments clipped to the [0, 24) window of the calendar day starting at
--- dayStartEpoch. Unlike the pie charts (completed tasks only), this shows
--- everything worked on that day, whether or not it was ever completed.
local function timewIntervalsToSegments(timewJson, dayStartEpoch, descToProject)
  local ok, intervals = pcall(hs.json.decode, timewJson or '[]')
  if not ok or not intervals then
    intervals = {}
  end

  local segments = {}
  for _, iv in ipairs(intervals) do
    if iv.start then
      -- Timewarrior omits `end` entirely for the currently-running interval
      -- (if any); treat it as running through right now so an in-progress
      -- task actually shows up instead of being skipped for lacking an end.
      local active = iv['end'] == nil
      local s = parseTaskTimestamp(iv.start)
      local e = active and os.time() or parseTaskTimestamp(iv['end'])
      if s and e and e > s then
        local startHour = math.max(0, math.min(24, (s - dayStartEpoch) / 3600))
        local endHour = math.max(0, math.min(24, (e - dayStartEpoch) / 3600))
        if endHour > startHour then
          local tags = iv.tags or {}
          local description, project
          -- Timewarrior's export sorts a tag list alphabetically rather
          -- than preserving insertion order, so a plain tags[1]/tags[2]
          -- positional read can't reliably spot the Sleep entries logged by
          -- obj:logSleep (which uses a single SLEEP tag) - check by value
          -- instead.
          if tags[1] == 'SLEEP' or tags[2] == 'SLEEP' then
            description, project = 'Sleep', 'SLEEP'
          else
            description = tags[1]
            project = canonicalCategory((description and descToProject[description]) or tags[2])
          end
          table.insert(segments, {
            startHour = startHour,
            endHour = endHour,
            project = project,
            description = description or 'Unknown task',
            active = active,
          })
        end
      end
    end
  end
  return segments
end

--- Appends the canvas elements for one 24-hour timeline bar (sleep blocks +
--- worked-task blocks + hour gridlines) into `elements`, spanning the full
--- width [x, x+w] at vertical position y. Returns the y-coordinate of the
--- bottom of everything drawn, plus a list of {frame, description, project,
--- startHour, endHour} for each task block, in chronological order, for
--- arrow-key navigation/inspection (see obj:_navMove).
local function buildTimelineBar(elements, label, segments, x, y, w, barH, colorFor, showNowMarker)
  local navEntries = {}
  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new(label, {
      font = { name = 'Impact', size = 16 },
      color = { hex = '#CCCCCC' },
    }),
    frame = { x = x, y = y, w = 200, h = 20 },
  })
  local barY = y + 22

  table.insert(elements, {
    type = 'rectangle',
    fillColor = { hex = '#242424' },
    strokeColor = { hex = '#3A3A3A' },
    strokeWidth = 1,
    frame = { x = x, y = barY, w = w, h = barH },
  })

  local function hourToX(hour)
    return x + (hour / 24) * w
  end

  -- Sleep blocks: only ever real logged sleep (see obj:logSleep), which
  -- comes through as a normal segment below, tagged project SLEEP - no
  -- placeholder is drawn for days without a real entry.
  for _, seg in ipairs(segments) do
    local sx = hourToX(seg.startHour)
    local segW = math.max(2, hourToX(seg.endHour) - sx) -- keep short tasks visible
    local frame = { x = sx, y = barY, w = segW, h = barH }
    table.insert(elements, {
      type = 'rectangle',
      fillColor = { hex = colorFor(seg.project) },
      -- A still-running task (see timewIntervalsToSegments's `active`) gets
      -- a bright outline instead of the usual thin dark one, so it reads as
      -- "ongoing" rather than a completed block.
      strokeColor = seg.active and { hex = '#FFFFFF' } or { hex = '#141414' },
      strokeWidth = seg.active and 2 or 1,
      frame = frame,
    })
    table.insert(navEntries, {
      frame = frame,
      description = seg.description,
      project = seg.project,
      startHour = seg.startHour,
      endHour = seg.endHour,
      active = seg.active,
    })
  end

  -- Hour gridlines + labels every 4 hours.
  local hourLabels = { '12a', '4a', '8a', '12p', '4p', '8p', '12a' }
  for i = 0, 6 do
    local hx = hourToX(i * 4)
    table.insert(elements, {
      type = 'segments',
      coordinates = { { x = hx, y = barY }, { x = hx, y = barY + barH } },
      strokeColor = { hex = '#555555', alpha = 0.6 },
      strokeWidth = 1,
    })
    table.insert(elements, {
      type = 'text',
      text = hs.styledtext.new(hourLabels[i + 1], { font = { name = 'Helvetica', size = 11 }, color = { hex = '#888888' } }),
      frame = { x = hx - 15, y = barY + barH + 3, w = 30, h = 16 },
    })
  end

  if showNowMarker then
    local nowHour = tonumber(os.date('%H')) + tonumber(os.date('%M')) / 60
    local nx = hourToX(nowHour)
    table.insert(elements, {
      type = 'rectangle',
      fillColor = { hex = '#FF3B30' },
      frame = { x = nx - 1, y = barY - 4, w = 2, h = barH + 8 },
    })
  end

  return barY + barH + 22, navEntries
end

--- Appends a shared color-key legend (category name only, no time/%) into
--- `elements`, spanning [x, x+w] at vertical position y. This is what
--- labels the colors used in the timeline bars above it (which otherwise
--- have no legend of their own), and always includes Work/Personal/No
--- Project as fixed reference points even when they have no time logged
--- today or yesterday, plus any other project actually seen. Returns the
--- y-coordinate of the bottom of everything drawn.
local function buildColorKey(elements, categories, x, y, w)
  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new('Categories', {
      font = { name = 'Impact', size = 16 },
      color = { hex = '#CCCCCC' },
    }),
    frame = { x = x, y = y, w = w, h = 20 },
  })

  local rowY = y + 26
  local itemW = 220
  local perRow = math.max(1, math.floor(w / itemW))
  for i, category in ipairs(categories) do
    local col = (i - 1) % perRow
    local row = math.floor((i - 1) / perRow)
    local line = hs.styledtext
      .new(LEGEND_BULLET .. '  ' .. labelForCategory(category), {
        font = { name = 'Helvetica', size = 14 },
        color = { hex = '#DDDDDD' },
      })
      :setStyle({ color = { hex = stableColorForProject(category) } }, 0, #LEGEND_BULLET)
    table.insert(elements, {
      type = 'text',
      text = line,
      frame = { x = x + col * itemW, y = rowY + row * 22, w = itemW - 10, h = 20 },
    })
  end

  local totalRows = math.ceil(#categories / perRow)
  return rowY + totalRows * 22
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

    local ok, tasks = pcall(hs.json.decode, stdOut)
    if not ok or not tasks then
      tasks = {}
    end
    local active = tasks[1] -- this Spoon only tracks a single "current" task

    if not active then
      if obj.taskStarted then
        -- A task just stopped or completed: enter break mode and reset the
        -- break timer so it starts counting from zero, not from wherever it
        -- last was. (Time-spent tracking for the pie chart is handled by
        -- Timewarrior's own Taskwarrior hook, not by this Spoon.)
        obj.taskStarted = false
        obj.task_name = ''
        obj.task_uuid = nil
        obj.task_project = nil
        obj.task_start_epoch = nil
        obj.break_start_epoch = os.time()
      elseif not obj.break_start_epoch then
        obj.break_start_epoch = os.time()
      end
      return
    end

    local startEpoch = active.start and parseTaskTimestamp(active.start)

    if not obj.taskStarted or obj.task_uuid ~= active.uuid or obj.task_start_epoch ~= startEpoch then
      -- A (new) task started, or the active task switched: reset the
      -- "time elapsed since start" timer to the task's real start time.
      obj.task_start_epoch = startEpoch
    end
    obj.taskStarted = true
    obj.task_name = active.description or ''
    obj.task_uuid = active.uuid
    obj.task_project = active.project
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

--- Slides the big nag banner in from the left edge of the screen, holds it
--- for `nag_hold_seconds`, then slides it back out and hides it.
function obj:showNag(text)
  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()

  if self._nag_timer then
    self._nag_timer:stop()
    self._nag_timer = nil
  end

  local boxW = math.min(mainRes.w * 0.7, 1400)
  local boxH = 220
  local targetX = (mainRes.w - boxW) / 2
  local targetY = (mainRes.h - boxH) / 2
  local startX = -boxW - 40

  if not self.nag_canvas then
    self.nag_canvas = hs.canvas.new({ x = 0, y = 0, w = 0, h = 0 })
    self.nag_canvas:level(hs.canvas.windowLevels.floating)
  end

  self.nag_canvas:frame({ x = startX, y = targetY, w = boxW, h = boxH })
  self.nag_canvas[1] = {
    type = 'rectangle',
    fillColor = { hex = '#141414', alpha = 0.93 },
    strokeColor = { hex = '#FF7733', alpha = 1.0 },
    strokeWidth = 5,
    roundedRectRadii = { xRadius = 18, yRadius = 18 },
  }
  self.nag_canvas[2] = {
    type = 'text',
    text = hs.styledtext.new(text, {
      font = { name = 'Impact', size = 40 },
      color = { hex = '#FFFFFF' },
      paragraphStyle = { alignment = 'center', lineBreakMode = 'wordWrap' },
    }),
    frame = { x = 28, y = 20, w = boxW - 56, h = boxH - 40 },
  }
  self.nag_canvas:show()
  self.nag_canvas:bringToFront(true)

  local duration, steps, i = 0.6, 30, 0
  self._nag_timer = hs.timer.doEvery(duration / steps, function()
    i = i + 1
    local t = 1 - (1 - i / steps) ^ 2 -- ease-out
    self.nag_canvas:frame({ x = startX + (targetX - startX) * t, y = targetY, w = boxW, h = boxH })
    if i >= steps then
      self._nag_timer:stop()
      self._nag_timer = hs.timer.doAfter(self.nag_hold_seconds, function()
        self:hideNag()
      end)
    end
  end)
end

--- Slides the nag banner back out to the left and hides it.
function obj:hideNag()
  if not self.nag_canvas then
    return
  end
  if self._nag_timer then
    self._nag_timer:stop()
    self._nag_timer = nil
  end

  local f = self.nag_canvas:frame()
  local startX, endX = f.x, -f.w - 40
  local duration, steps, i = 0.5, 25, 0
  self._nag_timer = hs.timer.doEvery(duration / steps, function()
    i = i + 1
    local t = (i / steps) ^ 2 -- ease-in
    self.nag_canvas:frame({ x = startX + (endX - startX) * t, y = f.y, w = f.w, h = f.h })
    if i >= steps then
      self._nag_timer:stop()
      self._nag_timer = nil
      self.nag_canvas:hide()
      self._nag_task_uuid = nil
    end
  end)
end

--- Scans pending tasks for the highest-urgency one you aren't already
--- working on, and shows the nag banner if it clears the threshold.
function obj:checkUrgentTask()
  hs.task
    .new('/opt/homebrew/bin/task', function(exitCode, stdOut, stdErr)
      if exitCode ~= 0 then
        logger.e('task export status:pending failed: ' .. tostring(stdErr))
        return
      end

      local tasks = hs.json.decode(stdOut)
      if not tasks then
        return
      end

      local best = nil
      for _, t in ipairs(tasks) do
        if t.urgency and t.urgency > self.nag_urgency_threshold and (not best or t.urgency > best.urgency) then
          best = t
        end
      end

      if not best then
        return
      end
      if self.taskStarted and self.task_name == best.description then
        return -- already working on the most urgent task
      end
      if self._nag_timer and self._nag_task_uuid == best.uuid then
        return -- already nagging about this exact task
      end

      self._nag_task_uuid = best.uuid
      self:showNag(buildNagMessage(best))
    end, { 'status:pending', 'export' })
    :start()
end

--- Draws the two-pie "completed today / completed yesterday" panel from
--- the raw JSON export of that day's completed tasks (used only to count
--- untracked completed tasks - see bucketizeTasks), an unfiltered export of
--- every task regardless of status (used to resolve any tracked
--- description's project, completed or not), plus the matching
--- `timew export` JSON for each day (time-spent source; see
--- minutesByDescriptionFromTimewExport above).
function obj:drawPieChart(todayJson, yesterdayJson, todayTimewJson, yesterdayTimewJson, allTasksJson)
  local allDescToProject = descriptionToProject(allTasksJson)
  local todayBuckets, todayUntracked =
    bucketizeTasks(minutesByDescriptionFromTimewExport(todayTimewJson), allDescToProject, todayJson)
  local yestBuckets, yestUntracked =
    bucketizeTasks(minutesByDescriptionFromTimewExport(yesterdayTimewJson), allDescToProject, yesterdayJson)

  local todayMidnight = os.time({
    year = tonumber(os.date('%Y')),
    month = tonumber(os.date('%m')),
    day = tonumber(os.date('%d')),
    hour = 0,
    min = 0,
    sec = 0,
  })
  local todaySegments = timewIntervalsToSegments(todayTimewJson, todayMidnight, allDescToProject)
  local yestSegments = timewIntervalsToSegments(yesterdayTimewJson, todayMidnight - 86400, allDescToProject)

  local colorFor = stableColorForProject

  -- Work/Personal/Sleep/Uncategorized always appear in the color key, even
  -- with nothing logged today or yesterday, so it's a stable reference
  -- rather than a list that only shows whatever happened to be used. Any
  -- other actual project gets added too, alphabetically.
  local categorySet = { WORK = true, PERSONAL = true, SLEEP = true, none = true }
  for _, b in ipairs(todayBuckets) do
    categorySet[b.project] = true
  end
  for _, b in ipairs(yestBuckets) do
    categorySet[b.project] = true
  end
  for _, seg in ipairs(todaySegments) do
    categorySet[seg.project] = true
  end
  for _, seg in ipairs(yestSegments) do
    categorySet[seg.project] = true
  end
  local categories = { 'WORK', 'PERSONAL', 'SLEEP', 'none' }
  local otherCategories = {}
  for category in pairs(categorySet) do
    if category ~= 'WORK' and category ~= 'PERSONAL' and category ~= 'SLEEP' and category ~= 'none' then
      table.insert(otherCategories, category)
    end
  end
  table.sort(otherCategories)
  for _, category in ipairs(otherCategories) do
    table.insert(categories, category)
  end

  local panelW = 1300
  -- Shared with the "Yesterday"/"Today" header labels below, so their text
  -- is centered on the actual pie beneath it rather than on an even
  -- half-panel split (which drifted from the pies' own off-center 0.27/0.73
  -- placement).
  local yestCenterX, todayCenterX = panelW * 0.27, panelW * 0.73
  local pieElements, pieBottom = {}, 0
  local todayArcs, yestArcs = {}, {}
  do
    local radius = 110
    local cy = 260
    pieBottom = math.max(
      buildPieColumn(pieElements, yestBuckets, yestUntracked, yestCenterX, cy, radius, colorFor, yestArcs),
      buildPieColumn(pieElements, todayBuckets, todayUntracked, todayCenterX, cy, radius, colorFor, todayArcs)
    )
  end

  local timelineElements = {}
  local timelineTop = pieBottom + 30
  local timelineMargin = 60
  local timelineW = panelW - 2 * timelineMargin
  local barBottom, todayNav = buildTimelineBar(
    timelineElements,
    'Today',
    todaySegments,
    timelineMargin,
    timelineTop,
    timelineW,
    36,
    colorFor,
    true
  )
  local yestNav
  barBottom, yestNav = buildTimelineBar(
    timelineElements,
    'Yesterday',
    yestSegments,
    timelineMargin,
    barBottom + 14,
    timelineW,
    36,
    colorFor,
    false
  )

  -- Arrow-key navigation state: left/right move within the current day's
  -- task blocks, up/down switch day. See obj:_navMove and
  -- obj:renderTimelineSelection, wired up by obj:togglePieChart.
  self._navRows = { Today = todayNav, Yesterday = yestNav }
  -- Per-task pie arcs (see buildPieColumn), keyed the same way, so
  -- obj:renderTimelineSelection can find and highlight the arc matching
  -- whatever timeline block is currently selected.
  self._pieArcs = { Today = todayArcs, Yesterday = yestArcs }
  self._navRowKey = 'Today'
  self._navIndex = nil

  local keyBottom = buildColorKey(timelineElements, categories, timelineMargin, barBottom + 20, timelineW)

  self._infoTextFrame = { x = 0, y = keyBottom + 14, w = panelW, h = 22 }
  local panelH = self._infoTextFrame.y + self._infoTextFrame.h + 36
  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()
  local x = (mainRes.w - panelW) / 2
  local y = (mainRes.h - panelH) / 2

  if self.pie_canvas then
    self.pie_canvas:delete()
  end
  self.pie_canvas = hs.canvas.new({ x = x, y = y, w = panelW, h = panelH })
  self.pie_canvas:level(hs.canvas.windowLevels.floating)

  local elements = {}
  table.insert(elements, {
    type = 'rectangle',
    fillColor = { hex = '#141414', alpha = 0.95 },
    strokeColor = { hex = '#36A3D9' },
    strokeWidth = 4,
    roundedRectRadii = { xRadius = 20, yRadius = 20 },
    frame = { x = 0, y = 0, w = panelW, h = panelH },
  })
  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new('Tracked Tasks', {
      font = { name = 'Impact', size = 32 },
      color = { hex = '#FFFFFF' },
      paragraphStyle = { alignment = 'center' },
    }),
    frame = { x = 0, y = 20, w = panelW, h = 50 },
  })
  local headerLabelW = panelW / 2
  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new('Yesterday', {
      font = { name = 'Impact', size = 24 },
      color = { hex = '#DDDDDD' },
      paragraphStyle = { alignment = 'center' },
    }),
    frame = { x = yestCenterX - headerLabelW / 2, y = 80, w = headerLabelW, h = 36 },
  })
  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new('Today', {
      font = { name = 'Impact', size = 24 },
      color = { hex = '#DDDDDD' },
      paragraphStyle = { alignment = 'center' },
    }),
    frame = { x = todayCenterX - headerLabelW / 2, y = 80, w = headerLabelW, h = 36 },
  })

  for _, el in ipairs(pieElements) do
    table.insert(elements, el)
  end
  for _, el in ipairs(timelineElements) do
    table.insert(elements, el)
  end

  -- Reserve three trailing element slots for the pie-arc highlight,
  -- timeline highlight, and info text, populated by
  -- renderTimelineSelection(). Kept at fixed indices so arrow-key
  -- navigation can update just these elements instead of rebuilding the
  -- whole panel on every keypress.
  self._baseElementCount = #elements
  table.insert(elements, { type = 'arc', radius = 1, startAngle = 0, endAngle = 0, strokeColor = { alpha = 0 } })
  table.insert(elements, { type = 'rectangle', fillColor = { alpha = 0 }, strokeColor = { alpha = 0 } })
  table.insert(elements, { type = 'text', text = '' })

  table.insert(elements, {
    type = 'text',
    text = hs.styledtext.new('hyper+P to close - hyper+arrows to inspect a task block', {
      font = { name = 'Helvetica', size = 13 },
      color = { hex = '#777777' },
      paragraphStyle = { alignment = 'center' },
    }),
    frame = { x = 0, y = panelH - 26, w = panelW, h = 20 },
  })

  for i, el in ipairs(elements) do
    self.pie_canvas[i] = el
  end
  self.pie_canvas:show(0.25)
  self:renderTimelineSelection()
end

-- An invisible placeholder for the pie-arc highlight slot, used whenever
-- nothing is selected or the selected block has no matching pie arc (e.g.
-- Sleep, or an in-progress task not yet in the completed-task pie).
local BLANK_PIE_ARC_HIGHLIGHT = { type = 'arc', radius = 1, startAngle = 0, endAngle = 0, strokeColor = { alpha = 0 } }

--- Redraws just the pie-arc highlight, timeline highlight, and info text (at
--- the three trailing element slots reserved in drawPieChart) for the
--- currently selected timeline block, or a usage hint when nothing is
--- selected yet.
function obj:renderTimelineSelection()
  if not self.pie_canvas or not self._baseElementCount then
    return
  end

  local rows = self._navRows[self._navRowKey] or {}
  local entry = self._navIndex and rows[self._navIndex]
  local pieArcIdx = self._baseElementCount + 1
  local highlightIdx = self._baseElementCount + 2
  local infoIdx = self._baseElementCount + 3

  if entry then
    -- Highlight the exact pie arc for this task, if it has one - a Sleep
    -- block or a still-active task (not yet in the completed-task pie)
    -- simply has none, so the highlight is cleared instead.
    local matchedArc
    for _, arc in ipairs(self._pieArcs[self._navRowKey] or {}) do
      if arc.description == entry.description then
        matchedArc = arc
        break
      end
    end
    if matchedArc then
      -- Same full-circle case as buildPieColumn: an arc spanning all 360
      -- degrees still strokes a seam down its start/end radius, so outline
      -- a plain circle instead when this task is the pie's only slice.
      if matchedArc.endAngle - matchedArc.startAngle >= 359.99 then
        self.pie_canvas[pieArcIdx] = {
          type = 'circle',
          center = { x = matchedArc.centerX, y = matchedArc.centerY },
          radius = matchedArc.radius,
          fillColor = { alpha = 0 },
          strokeColor = { hex = '#FFFFFF' },
          strokeWidth = 3,
        }
      else
        self.pie_canvas[pieArcIdx] = {
          type = 'arc',
          center = { x = matchedArc.centerX, y = matchedArc.centerY },
          radius = matchedArc.radius,
          startAngle = matchedArc.startAngle,
          endAngle = matchedArc.endAngle,
          fillColor = { alpha = 0 },
          strokeColor = { hex = '#FFFFFF' },
          strokeWidth = 3,
        }
      end
    else
      self.pie_canvas[pieArcIdx] = BLANK_PIE_ARC_HIGHLIGHT
    end

    self.pie_canvas[highlightIdx] = {
      type = 'rectangle',
      fillColor = { alpha = 0 },
      strokeColor = { hex = '#FFFFFF' },
      strokeWidth = 3,
      frame = entry.frame,
    }
    local timeRange = formatHourOfDay(entry.startHour) .. ' - ' .. (entry.active and 'now' or formatHourOfDay(entry.endHour))
    local duration = formatMinutes((entry.endHour - entry.startHour) * 60)
    local text = string.format(
      '%s: "%s"  -  %s (%s%s)  -  %s',
      self._navRowKey,
      entry.description,
      timeRange,
      duration,
      entry.active and ' so far, in progress' or '',
      labelForCategory(entry.project)
    )
    self.pie_canvas[infoIdx] = {
      type = 'text',
      text = hs.styledtext.new(text, {
        font = { name = 'Helvetica', size = 15 },
        color = { hex = stableColorForProject(entry.project) },
        paragraphStyle = { alignment = 'center' },
      }),
      frame = self._infoTextFrame,
    }
  else
    self.pie_canvas[pieArcIdx] = BLANK_PIE_ARC_HIGHLIGHT
    self.pie_canvas[highlightIdx] = { type = 'rectangle', fillColor = { alpha = 0 }, strokeColor = { alpha = 0 } }
    local hint = #rows == 0 and (self._navRowKey .. ': no tracked task blocks')
      or 'Use hyper+left/right to inspect a task block (hyper+up/down to switch day)'
    self.pie_canvas[infoIdx] = {
      type = 'text',
      text = hs.styledtext.new(hint, {
        font = { name = 'Helvetica', size = 13 },
        color = { hex = '#888888' },
        paragraphStyle = { alignment = 'center' },
      }),
      frame = self._infoTextFrame,
    }
  end
end

--- Moves the timeline selection: dx = -1/1 steps left/right within the
--- current day's task blocks, dy = -1/1 switches between Today/Yesterday.
--- Bound to the arrow keys while the pie chart panel is open.
function obj:_navMove(dx, dy)
  if dy ~= 0 then
    self._navRowKey = self._navRowKey == 'Today' and 'Yesterday' or 'Today'
    local rows = self._navRows[self._navRowKey] or {}
    self._navIndex = #rows > 0 and 1 or nil
  elseif dx ~= 0 then
    local rows = self._navRows[self._navRowKey] or {}
    if #rows == 0 then
      self._navIndex = nil
    elseif not self._navIndex then
      self._navIndex = 1
    else
      self._navIndex = ((self._navIndex - 1 + dx) % #rows) + 1
    end
  end
  self:renderTimelineSelection()
end

--- Prompts for last night's bed/wake times and records them as a
--- Timewarrior interval tagged SLEEP, so it shows up in the pie-chart
--- timeline (see buildTimelineBar and timewIntervalsToSegments's SLEEP
--- special-case) instead of no sleep block at all.
--- Bound to a hotkey in ~/.hammerspoon/init.lua; meant to be pressed right
--- after waking up. The prompt is pre-filled with sleep_default_bedtime and
--- the current time, so a normal morning is just the hotkey + Enter -
--- editing is only needed on nights that didn't match the default.
function obj:logSleep()
  local now = os.date('*t')
  local wakeDefault = string.format('%02d:%02d', now.hour, now.min)
  local bedDefault = self.sleep_default_bedtime or '23:00'

  local button, text = hs.dialog.textPrompt(
    'Log Sleep',
    'Bedtime - wake time, 24h HH:MM-HH:MM:',
    bedDefault .. '-' .. wakeDefault,
    'Log',
    'Cancel'
  )
  if button ~= 'Log' then
    return
  end

  local bedStr, wakeStr = text:match('^%s*(%d%d?:%d%d)%s*-%s*(%d%d?:%d%d)%s*$')
  if not bedStr then
    hs.alert.show('Could not parse "HH:MM-HH:MM" - sleep not logged')
    return
  end

  local function toEpoch(hhmm, dayOffset)
    local h, m = hhmm:match('(%d%d?):(%d%d)')
    local base = os.date('*t')
    return os.time({
      year = base.year,
      month = base.month,
      day = base.day + dayOffset,
      hour = tonumber(h),
      min = tonumber(m),
      sec = 0,
    })
  end

  local wakeEpoch = toEpoch(wakeStr, 0)
  -- Bedtime is virtually always the night before wake time (e.g. 23:00 ->
  -- 07:00 next day). The same-day interpretation only wins for the unusual
  -- case of a same-day nap, where bedtime's clock time already falls before
  -- wake time's on today's date.
  local bedSameDay = toEpoch(bedStr, 0)
  local bedEpoch = bedSameDay < wakeEpoch and bedSameDay or toEpoch(bedStr, -1)

  if bedEpoch >= wakeEpoch then
    hs.alert.show('Bedtime must be before wake time - sleep not logged')
    return
  end

  hs.task
    .new('/opt/homebrew/bin/timew', function(exitCode, _, stdErr)
      if exitCode ~= 0 then
        logger.e('timew track (sleep) failed: ' .. tostring(stdErr))
        hs.alert.show('Failed to log sleep - see Hammerspoon console')
        return
      end
      hs.alert.show(string.format('Logged sleep: %s -> %s', bedStr, wakeStr))
    end, {
      'track',
      os.date('%Y-%m-%dT%H:%M:%S', bedEpoch),
      '-',
      os.date('%Y-%m-%dT%H:%M:%S', wakeEpoch),
      'SLEEP',
    })
    :start()
end

--- Shows (fetching fresh data) or hides the completed-tasks pie chart
--- panel. Bound to a hotkey in ~/.hammerspoon/init.lua.
function obj:togglePieChart()
  if self.pie_canvas then
    self.pie_canvas:delete()
    self.pie_canvas = nil
    if self._nav_hotkeys then
      for _, hotkey in ipairs(self._nav_hotkeys) do
        hotkey:delete()
      end
      self._nav_hotkeys = nil
    end
    return
  end

  -- Chained rather than parallel to keep this simple; it only runs once per
  -- hotkey press, so the extra ~latency of sequential subprocesses doesn't
  -- matter.
  local function runTask(args, label, cb)
    hs.task
      .new('/opt/homebrew/bin/task', function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
          logger.e('task ' .. label .. ' failed: ' .. tostring(stdErr))
          cb(nil)
          return
        end
        cb(stdOut)
      end, args)
      :start()
  end

  local function runTimew(args, label, cb)
    hs.task
      .new('/opt/homebrew/bin/timew', function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
          logger.e('timew ' .. label .. ' failed: ' .. tostring(stdErr))
          cb(nil)
          return
        end
        cb(stdOut)
      end, args)
      :start()
  end

  runTask({ 'end.after:today', 'status:completed', 'export' }, 'export (today completed)', function(todayJson)
    runTask(
      { 'end.after:yesterday', 'end.before:today', 'status:completed', 'export' },
      'export (yesterday completed)',
      function(yestJson)
        runTimew({ 'export', 'today' }, 'export today', function(todayTimewJson)
          runTimew({ 'export', 'yesterday' }, 'export yesterday', function(yestTimewJson)
            -- Unfiltered - every task regardless of status, so a task
            -- that's only been started/stopped (never completed) still
            -- resolves to its real project instead of being invisible to
            -- the pie/timeline (see obj:drawPieChart, bucketizeTasks).
            runTask({ 'export' }, 'export (all tasks)', function(allTasksJson)
              self:drawPieChart(todayJson, yestJson, todayTimewJson, yestTimewJson, allTasksJson)
              -- Bound only while the panel is open (and removed the moment
              -- it closes, above). Uses the same hyper modifier
              -- (cmd+alt+shift) as your other bindings rather than bare
              -- arrow keys - bare arrows would hijack normal arrow-key use
              -- in every other app (scrolling a terminal, moving a text
              -- cursor, etc.) for as long as the panel stays open.
              local hyper = { 'cmd', 'alt', 'shift' }
              self._nav_hotkeys = {
                hs.hotkey.bind(hyper, 'left', function()
                  self:_navMove(-1, 0)
                end),
                hs.hotkey.bind(hyper, 'right', function()
                  self:_navMove(1, 0)
                end),
                hs.hotkey.bind(hyper, 'up', function()
                  self:_navMove(0, -1)
                end),
                hs.hotkey.bind(hyper, 'down', function()
                  self:_navMove(0, 1)
                end),
              }
            end)
          end)
        end)
      end
    )
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

    self:checkUrgentTask()
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
