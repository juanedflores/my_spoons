local obj={}
local _store = {}
setmetatable(obj,
             { __index = function(_, k) return _store[k] end,
               __newindex = function(t, k, v)
                 rawset(_store, k, v)
                 if t._init_done then
                   if t._attribs[k] then t:init() end
                 end
               end })
obj.__index = obj

-- Metadata
obj.name = "TaskWarriorTwo"
obj.version = "1.0"
obj.author = "juanedflores <juanedflores@gmail.com>"
obj.homepage = "https://github.com/juanedflores/my_spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local logger = hs.logger.new("TaskWarrior")
obj.logger = logger

obj.pending_tasks = {}

-- Defaults
obj._attribs = {
  task_name = "",
  speech_synth = hs.speech.new("Alex"),
  elapsed_minutes = 0,
  taskStarted = false,
  elapsed_hours = 0,
  width = 1000,
  height = 400,
}
textattrbsB = {
  font = {name = "Impact", size = 30},
  paragraphStyle = {lineHeightMultiple = 0.7, linebreak = clip},
  color = {hex="#ffffff"}
}
blue_col = {
  color = {hex="#36A3D9"}
}
orange_col = {
  color = {hex="#FF7733"}
}
green_col = {
  color = {hex="#BBCC52"}
}
red_col = {
  color = {hex="#F07178"}
}
rawtext = ""
display_text = hs.styledtext.new("break time", textattrbsB)
spaces = 0
spaces_string = ""

for k, v in pairs(obj._attribs) do obj[k] = v end

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
  if not self.canvas then self.canvas = hs.canvas.new({x=0, y=0, w=0, h=0}) end

  self.canvas[1] = {type = "rectangle", fillColor = {hex="#000000"}}
  self.canvas[2] = {
      type = "text",
      text = display_text
  }
  self.canvas:level(hs.canvas.windowLevels.desktopIcon)

  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()
  self.canvas:frame({
    x = 0,
    y = mainRes.h-30,
    w = mainRes.w,
    h = 30,
  })
  self._init_done = true
  return self
end


function checkTasks(files)
    foundtask = false
    taskname = ""
    obj.elapsed_minutes = 0
    obj.elapsed_hours = 0
    for _,file in pairs(files) do
      if file:sub(-12) == "pending.data" then
        -- check for a started task
        for line in io.lines(file) do
          if (string.match(line, "start")) then
            taskname = string.match(line, '"' .. '([a-zA-Z%s]*)' .. '"')
            foundtask = true
          end
        end
      end
    end
    if foundtask then
      obj.taskStarted = true
      obj.task_name = taskname
      rawtext = "current task: " .. taskname
    else 
      obj.taskStarted = false
      rawtext = "break time"
    end
end

function obj:tick_timer_animate()
  return hs.timer.doEvery(0.3, function() 
    spaces = spaces + 1
    spaces_string = ""
    for i=0,spaces do
      spaces_string = spaces_string .. " "
    end
    totalstring = spaces_string .. rawtext 
    print(spaces)
    -- hard coded number of spaces to restart text animation from left side
    if (spaces == 874) then
      spaces = 0
    end
    if (rawtext == "break time") then
    display_text = display_text:setString(spaces_string .. rawtext)
      :setStyle(blue_col, 0, spaces+11)
    else
    display_text = display_text:setString(spaces_string .. rawtext)
      :setStyle(green_col, 0, spaces+16)
      :setStyle(orange_col, spaces+16, spaces+16+string.len(taskname))
      :setStyle(red_col, spaces+16+string.len(taskname), spaces+16+string.len(taskname)+30)
    end
    self.canvas[2].text = display_text 
  end)
end

function obj:tick_timer_fn()
  return hs.timer.doEvery(60, function() 

    -- keep track of time
    self.elapsed_minutes = self.elapsed_minutes + 1
    if self.elapsed_minutes % 60 == 0 then
      self.elapsed_hours = self.elapsed_hours + 1
      -- if in break time, let me know when an hour passes
      if self.taskStarted == false then
        self.speech_synth:speak(self.elapsed_hours .. "hours have passed")
      end
    end

    -- determine text to display for time 
    time_text = ""
    if self.elapsed_minutes < 60 then
      time_text = self.elapsed_minutes .. " minutes"
    elseif self.elapsed_minutes > 60 then
      minutes_remainder = self.elapsed_minutes % 60
      time_text = self.elapsed_hours ..  " hours " .. minutes_remainder .. " minutes"
    end

    if self.taskStarted then
      styledText = hs.styledtext.new("current task: " .. self.task_name .. " elapsed time:  " ..  time_text, textattrbsB)
      styledText = styledText:setStyle(orange_col, 0, 13)
      styledText = styledText:setStyle(green_col, 14, 14+string.len(self.task_name))
      styledText = styledText:setStyle(red_col, 14+string.len(self.task_name)+1, -1)
      rawtext = styledText:getString()
    else
      rawtext = "break time. " .. "elapsed time: " .. time_text
    end


  end)
end

function obj:checkIfTaskStarted()
  local f = io.open(os.getenv("HOME") .. "/.task/pending.data", "rb")
  lines = f:lines()
  for line in lines do

    if (string.match(line, "start")) then
      self.taskStarted = true
      -- taskname = string.match(line, 'description:' .. '"' .. '(.*)' .. '"')
      taskname = string.match(line, '"' .. '([a-zA-Z%s]*)' .. '"')
      self.task_name = taskname
      rawtext = "current task: " .. taskname
      self.canvas[2].text = display_text
    else 
      rawtext = "break time"
      display_text = display_text:setString(spaces_string .. rawtext)
        :setStyle(blue_col, 0, spaces+11)
      obj.canvas[2].text = display_text
    end
  end
end

--- AClock:show()
--- Method
--- Show TaskWarrior
---
--- Parameters:
---  * None
---
--- Returns:
---  * The TaskWarrior object
function obj:show()
    self.canvas:show()
    self.tick_timer = self:tick_timer_fn()
    self.animate_timer = self:tick_timer_animate()
    myWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.task/pending.data", checkTasks):start()
    self:checkIfTaskStarted()
    return self
end


return obj
