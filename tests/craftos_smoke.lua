-- Real emulator smoke. The host runner supplies a disposable filesystem and
-- fixture HTTP server; GitHub URLs are routed through the real HTTP transport.
local mode = ...
local function read(path)
    local h = assert(fs.open(path, "r")); local body = h.readAll(); h.close(); return body
end
local function write(path, body)
    fs.makeDir(fs.getDir(path))
    local h = assert(fs.open(path, "w")); h.write(body); h.close()
end
local config = textutils.unserializeJSON(read("/smoke-config.json"))
local function finish(ok, reason)
    write("/smoke-result.json", textutils.serializeJSON({phase=config.phase, ok=ok, error=tostring(reason or ""), platform=_HOST}))
    -- Drain queued paging keys before returning control to the host renderer.
    os.queueEvent("ccpm_smoke_finished")
    repeat local event = os.pullEventRaw() until event == "ccpm_smoke_finished"
    -- Standards mode intentionally keeps powered-off computers open. Disable
    -- that emulator-only behavior after assertions so CI can exit normally.
    _G.config.set("standardsMode", false)
    os.shutdown(ok and 0 or 1)
end
local function ccpm(...)
    for _ = 1, 80 do os.queueEvent("key", keys.space) end
    assert(shell.run("/ccpm.lua", ...), "ccpm command failed")
end
local function state() return textutils.unserializeJSON(read("/.ccpm/state.json")) end

if mode == "--verify" then
    local ok, reason = pcall(function()
        assert(read("/user-startup-ran") == "preserved", "user startup did not run")
        if config.phase == "uninstall" then
            assert(not fs.exists("/ccpm.lua") and not fs.exists("/startup/10-ccpm.lua"))
            assert(fs.exists("/.ccpm/state.json"), "uninstall deleted cache state")
            return
        end
        local expected = (config.phase == "install" or config.phase == "recover") and config.first or config.second
        assert(read("/last-run") == expected, "wrong program ran at boot")
        assert(state().roots.smoke.resolved == expected, "wrong active commit")
        assert(read("/startup.lua"):find("user%-startup%-ran"), "user startup was replaced")
        if config.phase == "offline" then
            ccpm("rollback", "smoke")
            assert(state().roots.smoke.resolved == config.first and state().roots.smoke.selector.kind == "commit")
            ccpm("prune", "--dry-run"); ccpm("prune"); ccpm("run", "smoke")
            assert(read("/last-run") == config.first)
            ccpm("doctor"); ccpm("version"); ccpm("info", "smoke")
            -- Model an interrupted runtime activation on the real filesystem.
            local journal = {schema=2}
            for name, path in pairs({["ccpm.lua"]="/ccpm.lua", ["startup.lua"]="/startup/10-ccpm.lua", ["runtime.json"]="/.ccpm/runtime.json"}) do
                journal[name] = true
                write("/.ccpm/runtime-update/" .. name .. ".old", read(path))
            end
            write("/startup/00-ccpm-recovery.lua", read("/startup/10-ccpm.lua"))
            write("/.ccpm/runtime-update/pending.json", textutils.serializeJSON(journal))
            write("/ccpm.lua", "error('interrupted activation')")
            fs.delete("/startup/10-ccpm.lua")
        elseif config.phase == "recover" then
            assert(not fs.exists("/.ccpm/runtime-update/pending.json"), "recovery did not finish")
            assert(not fs.exists("/startup/00-ccpm-recovery.lua"), "temporary hook retained")
        end
    end)
    finish(ok, reason)
    return
end

local ok, reason = pcall(function()
    local get = http.get
    http.get = function(url, headers, binary)
        local path = url:match("^https://api%.github%.com/repos/FottenSC/computerCraft(.*)$")
        if path then return get(config.endpoint .. "/api" .. path, headers, binary) end
        path = url:match("^https://raw%.githubusercontent%.com/FottenSC/computerCraft/(.*)$")
        assert(path, "unexpected external request " .. url)
        return get(config.endpoint .. "/raw/" .. path, headers, binary)
    end
    write("/startup/99-ccpm-smoke.lua", 'assert(loadfile("/repo/tests/craftos_smoke.lua", "t", _ENV))("--verify")')
    if config.phase == "install" then
        local original = read("/startup.lua")
        assert(shell.run("/repo/bootstrap.lua"), "bootstrap failed")
        assert(read("/startup.lua") == original)
        assert(not fs.exists("/.ccpm/state.json"), "bootstrap auto-installed a package")
        assert(settings.get("ccpm.startup_package", "") == "", "bootstrap selected startup")
        local capture = window.create(term.current(), 1, 1, 51, 19, false)
        local previous = term.redirect(capture)
        term.clear(); term.setCursorPos(1, 1)
        print("> ccpm set")
        ccpm("set")
        _G.write("> ")
        local lines = {}
        for y = 1, 19 do lines[y] = capture.getLine(y) end
        term.redirect(previous)
        write("/terminal-capture.json", textutils.serializeJSON({width=51, height=19, lines=lines}))
        assert(not turtle, "expected a fresh computer")
        assert(not shell.run("/ccpm.lua", "install", "block-checker", "--commit", config.first), "turtle gate missing")
        ccpm("install", "smoke", "--branch", "main", "--startup")
    elseif config.phase == "uninstall" then
        ccpm("self-update", "--commit", config.second)
        assert(fs.exists("/.ccpm/previous-runtime/ccpm.lua"))
        ccpm("uninstall")
    end
end)
if not ok then finish(false, reason) end
-- Return to the actual CraftOS startup pipeline. The verifier runs after ccpm.
