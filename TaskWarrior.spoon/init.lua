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
obj.name = "TaskWarrior"
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
textattrbs = {
  font = {name = "Impact", size = 70},
  color = {hex="#36A3D9"}
}
pendingattrbs = {
  font = {name = "Impact", size = 24},
  paragraphStyle = { alignment="right" },
  color = {hex="#ffffff"}
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

--   if self.canvas then
--     hs.alert.show("canvas found")
--   end

  self.canvas[1] = {
      type = "rectangle",
      fillColor = { hex = { "#000000" } }
  }
  self.canvas[2] = {
      type = "text",
      text = hs.styledtext.new("break time", textattrbs)
  }
  self.canvas[3] = {
      type = "text",
      text = hs.styledtext.new("", textattrbs)
  }
  self.canvas:level(hs.canvas.windowLevels.desktopIcon)

  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()
  self.canvas:frame({
    x = mainRes.w,
    y = (mainRes.h-50) - mainRes.h/4,
    w = mainRes.w,
    h = self.height,
  })
  self._init_done = true
  return self
end


function checkTasks(files)
    foundtask = false
    taskname = ""
    obj.elapsed_minutes = 0
    obj.elapsed_hours = 0
    line_index = 0
    for _,file in pairs(files) do
      if file:sub(-12) == "pending.data" then
        for line in io.lines(file) do
          -- collect all pending tasks
          -- taskname = string.match(line, 'description:"([^"]*)"')
          -- duedate = string.match(line, 'due:"([^"]*)"')
          -- if not duedate then
          --   duedate = "none"
          -- end
          -- if not taskname then
          --   duedate = "none"
          -- end
          -- newtask = {task=taskname, due=duedate}
          -- self.pending_tasks[line_index] = newtask

          if (string.match(line, "start")) then
            taskname = string.match(line, "description." .. '"' .. '(.*)' .. '"%sdue')
            foundtask = true
          end
        end
      end
      line_index = line_index + 1
    end
    if foundtask then
      obj.taskStarted = true
      obj.task_name = taskname
      obj.canvas[2].text = hs.styledtext.new("current task:\n" .. taskname, textattrbs):setStyle(orange_col, 0, 13):setStyle(green_col, 14, 14+string.len(taskname))
    else 
      obj.taskStarted = false
      obj.canvas[2].text = hs.styledtext.new("break time", textattrbs)
    end

    for index, value in pairs(obj.pending_tasks) do
      obj.canvas[3].text = obj.canvas[3].text .. hs.styledtext.new(value["task"] .. "\n", pendingattrbs)
    end
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
      styledText = hs.styledtext.new("current task:\n" .. self.task_name .. "\nelapsed time:  " ..  time_text, textattrbs)
      styledText = styledText:setStyle(orange_col, 0, 13)
      styledText = styledText:setStyle(green_col, 14, 14+string.len(self.task_name))
      styledText = styledText:setStyle(red_col, 14+string.len(self.task_name)+1, -1)
      self.canvas[2].text = styledText
    else
      self.canvas[2].text = hs.styledtext.new("break time\n" .. "elapsed time: " .. time_text, textattrbs):setStyle(red_col, 11, -1)
    end


  end)
end

function obj:checkIfTaskStarted()
  local f = io.open(os.getenv("HOME") .. "/.task/pending.data", "rb")
  lines = f:lines()
  line_index = 0
  for line in lines do
    -- collect all pending tasks
    -- taskname = string.match(line, 'description:"([^"]*)"')
    -- duedate = string.match(line, 'due:"([^"]*)"')
    -- if not duedate then
    --   duedate = "none"
    -- end
    -- newtask = {task=taskname, due=duedate}
    -- self.pending_tasks[line_index] = newtask


    if (string.match(line, "start")) then
      self.taskStarted = true
      taskname = string.match(line, "description." .. '"' .. '(.*)' .. '"%sdue')
      self.task_name = taskname
      self.canvas[2].text = hs.styledtext.new("current task:\n" .. taskname, textattrbs):setStyle(orange_col, 0, 13):setStyle(green_col, 14, 14+string.len(taskname))
    else 
      obj.canvas[2].text = hs.styledtext.new("break time", textattrbs)
    end
    line_index = line_index + 1
  end
end


function obj:showPendingTasks()
  -- for index, value in pairs(self.pending_tasks) do
  --   self.canvas[3].text = self.canvas[3].text .. hs.styledtext.new(value["task"] .. "\n", pendingattrbs)
  -- end
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
    myWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.task/pending.data", checkTasks):start()
    self:checkIfTaskStarted()
    self:showPendingTasks()
    return self
end


return obj
