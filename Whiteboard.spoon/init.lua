--- === Whiteboard ===
---
--- Just draws a white rectangle for my drawing
--  app that draws on screen.

local obj={}
obj.__index = obj


-- Metadata
obj.name = "Whiteboard"
obj.version = "1.0"
obj.license = "MIT - https://opensource.org/licenses/MIT"

obj.logger = hs.logger.new('Whiteboard')

obj.activate_apps = {}

function obj:init()
	obj.canvas = hs.canvas.new({x=0, y=0, w=0, h=0})
	obj.canvas[1] = {
			type = "rectangle",
			action = "fill",
			fillColor = {hex="#000000"}
	}

  self.canvas:level(hs.canvas.windowLevels.desktop)

	local mainScreen = hs.screen.primaryScreen()
	local mainRes = mainScreen:fullFrame()
	obj.canvas:frame({ w = mainRes.w, h = mainRes.h })

	return self
end

function obj:hideApps()
	t_index = 1

	kitty = hs.application.find("kitty")
	if kitty then
		kitty:hide()
		obj.activate_apps[t_index] = kitty 
		t_index = t_index + 1
	end

	firefox = hs.application.find("Firefox")
	if firefox then
		firefox:hide()
		obj.activate_apps[t_index] = firefox 
		t_index = t_index + 1
	end

	finder = hs.application.find("Finder")
	hs.timer.delayed.new(0.3, function()
		finder:hide()
		obj.activate_apps[t_index] = finder
		t_index = t_index + 1
	end):start()

	local w = hs.window.visibleWindows()
	for i,t in ipairs(w) do
		app = w[i]:application()

		if app:name() ~= "Finder" and app:name() ~= "Firefox" and app:name() ~= "kitty" then
			app:hide()
			obj.activate_apps[t_index] = app
			t_index = t_index + 1
		end
	end
end

function obj:showApps()
	-- unhide all apps that we hid earlier
	kitty_found = 0
	for i,t in ipairs(obj.activate_apps) do
		if obj.activate_apps[i]:name() == "kitty" then
			kitty_found = true
		else 
			obj.activate_apps[i]:unhide()
		end
	end
	-- I usually have kitty on the right side and
	-- app must be unhidden last in order to be there.
	if kitty_found then
		kitty = hs.application.find("kitty")
		kitty:unhide()
	end
	-- empty table
	for k in pairs (obj.activate_apps) do
    obj.activate_apps[k] = nil
	end
end

function obj:show()
	obj:hideApps()
	obj.canvas:show()

	-- open Ultimate Pen App
	hs.application.open("/Applications/Ultimate Pen.app")

	return self
end

function obj:hide()
  obj.canvas:hide()

	obj:showApps()

	-- kill Ultimate Pen App if open
	pen = hs.application.find("Ultimate Pen")
	pen:kill()
end

function obj:isShowing()
  return obj.canvas:isShowing()
end

function obj:toggleShow()
  if self:isShowing() then
    self:hide()
  else
    self:show()
  end
end

return obj
