-- For the frontend test (run-frontend.sh): the game's properties through
-- Chimera's Lua library. Runs the project to the frame asked for (in the
-- fight), reads properties by name, sets player 1's life and player 2's
-- power, runs one more frame and reads them again.
--
-- The job comes from the file named by MINIHAWK_JOB:
--   frames=<how many frames to advance first>
--   meta=<path to write the result (text)>

local jobPath = os.getenv("MINIHAWK_JOB")
if jobPath == nil then
	error("MINIHAWK_JOB env var not set")
end
local job = {}
for line in io.lines(jobPath) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end

local out = {}
local function put(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
local function finish(status)
	put("status", status)
	local f = assert(io.open(job.meta, "wb"))
	f:write(table.concat(out, "\n") .. "\n")
	f:close()
	client.exit()
end

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

local frames = tonumber(job.frames) or 120
while emu.framecount() < frames do
	emu.frameadvance()
end

local names = game.list()
put("count", #names)
for _, n in ipairs({ "Match.Round", "Match.Round State", "Player.Present[1]", "Player.Present[3]",
	"Player.Life[1]", "Player.Life Max[1]", "Player.Power[2]", "Player.X[1]", "Player.X[2]", "Player.Facing[2]" }) do
	put("get." .. n, game.get(n))
end
put("set.life", game.set("Player.Life[1]", 123))
put("set.power", game.set("Player.Power[2]", 2500))
put("set.max", game.set("Player.Life Max[1]", 5))
emu.frameadvance()
put("after.Player.Life[1]", game.get("Player.Life[1]"))
put("after.Player.Power[2]", game.get("Player.Power[2]"))
put("after.Player.Life Max[1]", game.get("Player.Life Max[1]"))
finish("OK")
