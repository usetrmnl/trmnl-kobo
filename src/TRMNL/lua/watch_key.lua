-- Block on an input device until a key is pressed, then drop a flag file, so a
-- shell script can react to a button without polling. Reading blocks, so this
-- costs no CPU while it waits, and it is frozen along with everything else
-- while the device is suspended.

local ffi = require("ffi")
local bor = bit.bor
local C = ffi.C

require("ffi/posix_h")

-- 16 bytes here: struct timeval is two longs on 32 bit arm, then the u16 type
-- and code and the s32 value
ffi.cdef [[
struct input_event {
    long tv_sec;
    long tv_usec;
    unsigned short type;
    unsigned short code;
    int value;
};
]]

assert(#arg == 3 or #arg == 4, "must pass an input device, a key code, a flag file & optionally a minimum hold in ms")
local device = arg[1]
local key_code = tonumber(arg[2])
local flag_file = arg[3]
-- On a device with no key of its own, the exit key is also the wake key, so a
-- plain press cannot mean "stop" (every scheduled wake presses it too). A
-- minimum hold turns this into "hold to exit", which a scheduled wake never
-- does; 0 (the default) keeps the original fire-on-press behaviour.
local min_hold_ms = tonumber(arg[4]) or 0

local EV_KEY = 1
local KEY_DOWN = 1
local KEY_UP = 0

local fd = C.open(device, bor(C.O_RDONLY, C.O_CLOEXEC))
assert(fd ~= -1, "cannot open " .. device)

local event = ffi.new("struct input_event[1]")
local event_size = ffi.sizeof("struct input_event")
local errors = 0

-- Blocks for the next event on our key, returning its (type, value, ms) or
-- nil once the device is gone for good. Frozen along with everything else
-- while suspended, so this costs no CPU while waiting.
local function next_key_event()
    while true do
        local nread = C.read(fd, event, event_size)
        if nread == event_size then
            errors = 0
            if event[0].type == EV_KEY and event[0].code == key_code then
                return event[0].value, event[0].tv_sec * 1000 + event[0].tv_usec / 1000
            end
        else
            -- a thaw after suspend can cut a read short, so do not give up on
            -- the first one, but do not spin forever on a device that has
            -- gone away
            errors = errors + 1
            if errors > 100 then
                return nil
            end
        end
    end
end

while true do
    local value, pressed_at = next_key_event()
    if value == nil then
        break
    end
    if value == KEY_DOWN then
        if min_hold_ms <= 0 then
            local flag = assert(io.open(flag_file, "w"))
            flag:write(key_code, "\n")
            flag:close()
            break
        end
        -- Wait out the release to measure the hold; a short tap (a wake) is
        -- silently ignored and we go back to watching for the next press.
        local up_value, released_at = next_key_event()
        if up_value == nil then
            break
        end
        if up_value == KEY_UP and (released_at - pressed_at) >= min_hold_ms then
            local flag = assert(io.open(flag_file, "w"))
            flag:write(key_code, "\n")
            flag:close()
            break
        end
    end
end

C.close(fd)
