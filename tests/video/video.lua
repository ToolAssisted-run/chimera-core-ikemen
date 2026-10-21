-- The Ikemen GO core's video probe (tests/run-gate.sh): plays video.def, a
-- storyboard whose background is two videos, one with sound, and prints a
-- line on each frame it runs.
local s = loadStoryboard('video.def')
print('video start loaded=' .. tostring(s ~= nil))
local f = 0
while runStoryboard() do
	print('video f=' .. f)
	refresh()
	f = f + 1
end
print('video end f=' .. f)
while true do
	refresh()
end
