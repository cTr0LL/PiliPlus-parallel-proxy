-- Seeks around a file repeatedly, then quits CLEANLY.
--
-- Clean shutdown matters: cutting mpv off with --frames/--length leaves a
-- partial packet in the demuxer and prints "Invalid NAL unit size", which looks
-- exactly like stream corruption but is not. Quitting via mp.commandv("quit")
-- avoids that, so anything printed here is real.
--
--   mpv --no-config --vo=null --ao=null --script=tool/seek_stress.lua <url>

local targets = {10, 150, 40, 185, 75, 120, 5}
local i = 1

mp.add_periodic_timer(2.0, function()
    if i > #targets then
        mp.msg.info("seek stress: completed " .. #targets .. " seeks")
        mp.commandv("quit")
        return
    end
    mp.msg.info("seek -> " .. targets[i] .. "s")
    mp.commandv("seek", targets[i], "absolute")
    i = i + 1
end)
