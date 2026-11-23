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

assert(#arg == 3, "must pass an input device, a key code & a flag file")
local device = arg[1]
local key_code = tonumber(arg[2])
local flag_file = arg[3]

local EV_KEY = 1
local KEY_PRESSED = 1

local fd = C.open(device, bor(C.O_RDONLY, C.O_CLOEXEC))
assert(fd ~= -1, "cannot open " .. device)

local event = ffi.new("struct input_event[1]")
local event_size = ffi.sizeof("struct input_event")
local errors = 0

while true do
    local nread = C.read(fd, event, event_size)
    if nread == event_size then
        errors = 0
        if event[0].type == EV_KEY and event[0].code == key_code and event[0].value == KEY_PRESSED then
            local flag = assert(io.open(flag_file, "w"))
            flag:write(key_code, "\n")
            flag:close()
            break
        end
    else
        -- a thaw after suspend can cut a read short, so do not give up on the
        -- first one, but do not spin forever on a device that has gone away
        errors = errors + 1
        if errors > 100 then
            break
        end
    end
end

C.close(fd)
