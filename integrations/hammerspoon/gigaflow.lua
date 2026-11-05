-- Add to your init.lua with dofile(); keep the returned module in a global.
-- Only Forward (raw button 4) is handled, and only while GigaFlow is running.
local module = {}
local bundleID = "local.arseniy.gigaflow"
local sender = "org.hammerspoon.Hammerspoon"
local forwardButton = 4 -- Change this if your mouse uses a different button.
local pressed = false
local consumed = false

local function running()
  return hs.application.get(bundleID) ~= nil
end

local function notify(action)
  hs.distributednotifications.post(bundleID .. "." .. action, sender, {})
end

module.tap = hs.eventtap.new({
  hs.eventtap.event.types.otherMouseDown,
  hs.eventtap.event.types.otherMouseUp,
}, function(event)
  if event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber) ~= forwardButton then
    return false
  end
  if event:getType() == hs.eventtap.event.types.otherMouseDown then
    if pressed then return consumed end
    pressed = true
    consumed = running()
    if consumed then notify("toggle") end
    return consumed
  end
  local handled = consumed
  pressed, consumed = false, false
  return handled
end):start()

function module.stop()
  if module.tap then module.tap:stop() end
  if running() then notify("stop") end
  pressed, consumed = false, false
end

local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  module.stop()
  if type(previousShutdown) == "function" then previousShutdown() end
end

return module
