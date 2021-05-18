--- === AClock ===
---
--- Just another clock, floating above all.
--- 
--- Configurable properties (with default values):
---     format = "%H:%M",
---     textFont = "Impact",
---     textSize = 135,
---     textColor = {hex="#1891C3"},
---     width = 320,
---     height = 230,
---     showDuration = 4,  -- seconds
---     hotkey = 'escape',
---     hotkeyMods = {},
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/AClock.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/AClock.spoon.zip)

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
obj.name = "AClock"
obj.version = "1.0"
obj.author = "ashfinal <ashfinal@gmail.com>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local logger = hs.logger.new("AClock")
obj.logger = logger

-- Defaults
obj._attribs = {
  format = "%H:%M:%S",
  textFont = "Impact",
  textSize = 150,
  width = 620,
  height = 230,
  showDuration = 4,  -- seconds
  hotkey = 'escape',
  hotkeyMods = {},
}
textSize = 150
hours = {
  font = {name = "Impact", size = textSize},
  color = {hex="#a32525"},
}
minutes = {
  font = {name = "Impact", size = textSize},
  color = {hex="#afab36"},
}
seconds = {
  font = {name = "Impact", size = textSize},
  color = {hex="#2c4693"},
}
colon = {
  font = {name = "Impact", size = textSize},
  color = {hex="#ffffff"},
}
for k, v in pairs(obj._attribs) do obj[k] = v end

--- AClock:init()
--- Method
--- init.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The AClock object
colontext = hs.styledtext.new(":", colon)
function obj:init()
  if not self.canvas then self.canvas = hs.canvas.new({x=0, y=0, w=0, h=0}) end
  self.canvas[1] = {
    type = "rectangle",
    fillColor = {hex="#000000"}
  }
  self.canvas[2] = {
    type = "text",
    text = "",
    textFont = self.textFont,
    textSize = self.textSize,
    textColor = self.HColor,
    textAlignment = "center",
  }

  self.canvas:level(hs.canvas.windowLevels.desktopIcon)
  
  local mainScreen = hs.screen.primaryScreen()
  local mainRes = mainScreen:fullFrame()
  self.canvas:frame({
    x = mainRes.w,
    y = 0,
    w = self.width,
    h = self.height,
  })
  self._init_done = true
  return self
end

function obj:tick_timer_fn()
  return hs.timer.doEvery(1, function() 
    self.canvas[1] = {type = "rectangle", fillColor = {hex="#000000"}}
    self.canvas[2].text = hs.styledtext.new(os.date(" %H"), hours) .. colontext .. hs.styledtext.new(os.date("%M"), minutes) .. colontext .. hs.styledtext.new(os.date("%S "), seconds)
  end)
end

function obj:isShowing()
  return self.canvas:isShowing()
end

--- AClock:show()
--- Method
--- Show AClock.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The AClock object
function obj:show()
  self.canvas:show()
  self.tick_timer = self:tick_timer_fn()
  -- if self.hotkey then
  --   self.cancel_hotkey = hs.hotkey.bind(self.hotkeyMods, self.hotkey, function() self:hide() end)
  -- end
  return self
end

--- AClock:hide()
--- Method
--- Hide AClock.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The AClock object
function obj:hide()
  if self.cancel_hotkey then self.cancel_hotkey:delete() end
  -- hotkey first, if anything goes wrong we don't want the hotkey stuck
  self.canvas:hide()
  if self.tick_timer then self.tick_timer:stop(); self.tick_timer = nil end
end

--- AClock:toggleShow()
--- Method
--- Show AClock for 4 seconds. If already showing, hide it.
function obj:toggleShow()
  if self:isShowing() then
    self:hide()
    if self.show_timer then
      self.show_timer:stop()
      self.show_timer = nil
    end
  else
    self:show()
    self.show_timer = hs.timer.doAfter(self.showDuration, function()
      self:hide()
      self.show_timer = nil
    end)
  end
end

--- AClock:toggleShowPersistent()
--- Method
--- Show AClock. If already showing, hide it.
function obj:toggleShowPersistent()
  if self:isShowing() then
    self:hide()
  else
    self:show()
  end
end

return obj
