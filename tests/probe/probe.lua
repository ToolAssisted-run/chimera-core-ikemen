-- The Ikemen GO core's probe (tests/run-gate.sh): every frame it prints what
-- the game learns from the machine - the frame, the date and time, a random
-- number from the engine's generator, and the buttons each player pressed
-- that frame - as one line starting "probe". At the start it reports what is
-- in save/ and writes save/probe.txt.
local tokens = {'U', 'D', 'L', 'R', 'a', 'b', 'c', 'x', 'y', 'z', 's', 'd', 'w', 'm'}

-- the players' command lists, as the engine's own menus make them
setPlayers()

local function readAll(path)
	local f = io.open(path, 'rb')
	if f == nil then return '' end
	local s = f:read('*a')
	f:close()
	return s
end

print('probe start date=' .. os.date('!%Y-%m-%dT%H:%M:%S') .. ' seed=[' .. readAll('save/seed.txt') .. ']')
local out = io.open('save/probe.txt', 'wb')
out:write('written on ' .. os.date('!%Y-%m-%d'))
out:close()

local f = 0
while true do
	local held = {}
	for p = 1, 4 do
		for _, t in ipairs(tokens) do
			if getInput(p, t) then
				held[#held + 1] = 'P' .. p .. t
			end
		end
	end
	if esc() then
		held[#held + 1] = 'Esc'
		esc(false)
	end
	print(string.format('probe f=%d date=%s rnd=%d in=%s', f, os.date('!%H:%M:%S'), getRandom(), table.concat(held, ',')))
	refresh()
	f = f + 1
end
