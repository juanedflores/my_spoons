AClock = hs.loadSpoon("AClock")
AClock:show()
Taskwarrior = hs.loadSpoon("Taskwarrior")
Taskwarrior:show()

WhiteBoard = hs.loadSpoon("Whiteboard")
hs.hotkey.bind({"cmd", "shift", "ctrl"}, "W", function()
	WhiteBoard:toggleShow()
end)


