local log = {}

local function write(level, message)
    local time = textutils.formatTime(os.time(), true)
    print(("[%s] %-5s %s"):format(time, level, tostring(message)))
end

function log.info(message)
    write("INFO", message)
end

function log.warn(message)
    write("WARN", message)
end

function log.error(message)
    write("ERROR", message)
end

return log
