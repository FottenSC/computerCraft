-- Minimal terminal surface using pinned CraftOS rendering and paging code.
return function(directory, width, height)
    local function read(name)
        local handle = assert(io.open(directory .. "/" .. name, "rb"))
        local source = handle:read("*a")
        handle:close()
        return source
    end
    local x, y, promptCount, terminate = 1, 1, 0, false
    local rows, history = {}, {}
    for index = 1, height do rows[index] = string.rep(" ", width) end
    local native = {}
    function native.getSize() return width, height end
    function native.getCursorPos() return x, y end
    function native.setCursorPos(nextX, nextY) x, y = nextX, nextY end
    function native.write(value)
        for index = 1, #value do
            local column = x + index - 1
            if column >= 1 and column <= width and y >= 1 and y <= height then
                local row = rows[y]
                rows[y] = row:sub(1, column - 1) .. value:sub(index, index) .. row:sub(column + 1)
            end
        end
        x = x + #value
    end
    function native.scroll(count)
        for _ = 1, count do
            history[#history + 1] = table.remove(rows, 1):gsub(" +$", "")
            rows[#rows + 1] = string.rep(" ", width)
        end
    end
    function native.clearLine() rows[y] = string.rep(" ", width) end
    local current = native
    local terminal = {}
    for name in pairs(native) do
        local method = name
        terminal[method] = function(...) return current[method](...) end
    end
    function terminal.current() return current end
    function terminal.redirect(target) local old = current; current = target; return old end
    local expect = assert(loadfile(directory .. "/expect.lua"))().expect
    local environment = setmetatable({term=terminal, expect=expect, os={pullEvent=function(filter)
        assert(filter == "key" and not _G.__ccpm_write_lock)
        promptCount = promptCount + 1
        if terminate then error("Terminated", 0) end
        return "key", 57
    end}}, {__index=_G})
    local bios = read("bios.lua")
    local rendering = assert(bios:match("(function write%b().-)\nfunction printError"))
    assert(load(rendering, "@upstream-rendering", "t", environment))()
    local textutilsSource = read("textutils.lua")
    local paging = assert(textutilsSource:match("(local function makePagedScroll.-)\nlocal function tabulateCommon"))
    assert(load(paging, "@upstream-paging", "t", environment))()
    return {
        term=terminal, native=native, print=environment.print, pagedPrint=environment.pagedPrint,
        prompts=function() return promptCount end,
        terminateOnPrompt=function() terminate=true end,
        transcript=function()
            local lines = {}
            for _, line in ipairs(history) do lines[#lines + 1] = line end
            for _, line in ipairs(rows) do lines[#lines + 1] = line:gsub(" +$", "") end
            return table.concat(lines, "\n")
        end,
    }
end
