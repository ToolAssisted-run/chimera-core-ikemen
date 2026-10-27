-- For the window test (run-frontend.sh): run the project inside Chimera for
-- a fixed number of frames, then save the picture. The script compares that
-- picture with the one the native reference draws at the same frame.
--
-- The job comes from the file named by the MINIHAWK_JOB environment variable:
--   frames=<how many frames to advance>
--   meta=<path to write the result (text)>
--   shot=<optional path to write a screenshot>

local function writeAll(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

local meta = {}
local function finish(status, detail)
	local lines = {
		"status=" .. status,
		"detail=" .. (detail or ""),
		"frames=" .. (meta.frames or 0),
		"lag=" .. (meta.lag or 0),
		"width=" .. (meta.width or 0),
		"height=" .. (meta.height or 0),
	}
	if meta.metaPath then
		writeAll(meta.metaPath, table.concat(lines, "\n") .. "\n")
	end
	client.exit()
end

local jobPath = os.getenv("MINIHAWK_JOB")
if jobPath == nil then
	error("MINIHAWK_JOB env var not set")
end
local job = {}
for line in io.lines(jobPath) do
	local k, v = line:match("^([^=]+)=(.*)$")
	if k then job[k] = v end
end
meta.metaPath = job.meta

if emu.getsystemid() ~= "IkemenGO" then
	finish("ERROR", "wrong system id: " .. tostring(emu.getsystemid()))
end

pcall(function() client.speedmode(6400) end)
pcall(function() client.invisibleemulation(true) end)

-- a project may open a frame or two in; run to the frame asked for
local frames = tonumber(job.frames) or 120
while emu.framecount() < frames do
	-- the last frame is drawn, so the screenshot below is of it (in the
	-- window frames run undrawn while invisibleemulation is on)
	if emu.framecount() == frames - 1 then pcall(function() client.invisibleemulation(false) end) end
	emu.frameadvance()
end

meta.frames = emu.framecount()
meta.lag = emu.lagcount()
meta.height = client.bufferheight()
meta.width = client.bufferwidth()

if job.shot ~= nil and job.shot ~= "" then
	client.screenshot(job.shot)
end

finish("OK", "")
