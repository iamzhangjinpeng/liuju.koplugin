local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return end
    local content = file:read("*all")
    file:close()
    return content
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

local number = 0
local repo = "iamzhangjinpeng/liuju.koplugin"
local version, bytes = "1.10.0", "fixture ZIP"
local url = "https://api.github.com/repos/" .. repo .. "/releases/assets/12345"
local function fixture()
    number = number + 1
    local dir = SCRATCH .. "/ota-" .. number
    local f = { dir = dir, live = dir .. "/liuju.koplugin", requests = {}, tasks = {},
        messages = {}, entries = {}, standby = 0, connected = 0 }
    py_mkdir(f.live)
    write(f.live .. "/main.lua", "-- old installation")
    write(dir .. "/reading-settings", "unchanged")
    for _, name in ipairs({ "_meta.lua", "main.lua", "liuju_core.lua", "liuju_draw.lua", "liuju_layout.lua",
        "liuju_policy.lua", "liuju_render.lua", "liuju_store.lua", "liuju_update.lua",
        "assets/lyrics-background.png", "assets/date-card-background.png", "assets/dark-card-background.png" }) do
        local data = name == "_meta.lua" and ('return {\n    version = "' .. version .. '",\n}\n') or "-- runtime"
        f.entries[#f.entries + 1] = { path = "liuju.koplugin/" .. name, size = #data, data = data, mode = "file" }
    end
    f.release = { tag_name = "v" .. version, draft = false, prerelease = false, assets = {{
        name = "liuju.koplugin-v" .. version .. ".zip", state = "uploaded", url = url, id = 12345,
        digest = "sha256:" .. py_hash(bytes), size = #bytes,
    }} }
    local function run_task()
        if f.task then
            local task = f.task
            f.task = nil
            task(17, 19)
        end
    end
    function f:drain()
        run_task()
        local n = 0
        while #self.tasks > 0 do
            table.sort(self.tasks, function(a, b) return a.delay < b.delay end)
            table.remove(self.tasks, 1).cb()
            n = n + 1
            assert(n < 50)
        end
        eq(self.standby, 0)
    end
    function f:download()
        self.updater:check()
        self:drain()
        assert(self.confirmation).ok_callback()
    end
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, delay, cb) f.tasks[#f.tasks + 1] = { delay = delay, cb = cb } end,
        unschedule = function(_, cb)
            for i = #f.tasks, 1, -1 do if f.tasks[i].cb == cb then table.remove(f.tasks, i) end end
        end,
        show = function(_, widget)
            f.messages[#f.messages + 1] = widget.text
            if widget.ok_callback then f.confirmation = widget end
            if widget.dismiss_callback then f.progress = widget end
        end,
        close = function(_, widget) widget.dismiss_callback() end,
        isWidgetShown = function() return true end,
        preventStandby = function() f.standby = f.standby + 1 end,
        allowStandby = function() f.standby = f.standby - 1 end,
        askForRestart = function(_, message) f.restart = message end,
    }
    package.loaded["ui/widget/confirmbox"] = { new = function(_, args) return args end }
    package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/confirmbox"]
    package.loaded["ui/network/manager"] = { runWhenConnected = function(_, callback)
        f.connected = f.connected + 1
        callback()
    end }
    package.loaded["libs/libkoreader-lfs"] = {
        mkdir = py_mkdir_one,
        symlinkattributes = function(path, field) return py_attrs(path, field, true) end,
        dir = function(path)
            local files, i = py_list(path), 0
            return function() i = i + 1; return files[i] end
        end,
    }
    package.loaded["ffi/util"] = {
        fsyncOpenedFile = function() return true end,
        fsyncDirectory = function() return true end,
        runInSubProcess = function(task) f.task, f.result = task, nil; return 17, 18 end,
        isSubProcessDone = function() return f.task == nil end,
        terminateSubProcess = function() f.task = nil end,
        writeToFD = function(_, result) f.result = result end,
        readAllFromFD = function() return f.result end,
    }
    package.loaded["logger"] = { warn = function(...) f.warning = table.concat({...}, " ") end }
    package.loaded["socketutil"] = { set_timeout = function() end }
    package.loaded["ssl.https"] = { tcp = function(config)
        eq(config.verify, "peer")
        eq(config.cafile, "./data/ca-bundle.crt")
        return function()
            return {
                connect = function() return 1 end,
                close = function() end,
                getpeercertificate = function()
                    return { extensions = function()
                        return { ["2.5.29.17"] = { dNSName = { f.certificate or f.host } } }
                    end }
                end,
            }
        end
    end }
    package.loaded["socket.http"] = { request = function(opts)
        f.host = assert(opts.url:match("^https://([^:]+):443/"))
        eq(opts.redirect, false)
        f.requests[#f.requests + 1] = f.host
        if not opts.create():connect(f.host, 443) then return nil, "TLS error" end
        if f.host == "api.github.com" and opts.url:match("/assets/12345$") then return 1, 302, {
            location = f.redirect or "https://release-assets.githubusercontent.com/update.zip",
        } end
        local data = f.host == "api.github.com" and "JSON" or f.bytes or bytes
        if not opts.sink(data) then return nil, "size" end
        return 1, 200, {}
    end }
    package.loaded["dkjson"] = { decode = function() return f.release end }
    package.loaded["ffi/archiver"] = { Reader = { new = function()
        local index = 0
        return {
            open = function(_, zip) eq(read(zip), bytes); return true end,
            next = function() index = index + 1; return f.entries[index] end,
            extractToMemory = function(_, path) eq(path, f.entries[index].path); return f.entries[index].data end,
            close = function() f.archive_closed = true end,
        }
    end } }
    local Updater = dofile(TEST_ROOT .. "/liuju_update.lua")
    f.updater = Updater.new({ hash = py_hash }, f.live, "1.9.9", function() return not f.inactive end)
    return f
end

local function test(name, fn)
    fn()
    print("PASS " .. name)
end

test("Manual update installs a numerically newer official release after confirmation", function()
    local f = fixture()
    eq(f.connected, 0)
    f.updater:check()
    f:drain()
    eq(#f.requests, 1)
    eq(read(f.live .. "/main.lua"), "-- old installation")
    assert(f.confirmation.text:find(version, 1, true))
    f.confirmation.ok_callback()
    f:drain()
    eq(table.concat(f.requests, ","), "api.github.com,api.github.com,release-assets.githubusercontent.com")
    eq(read(f.live .. "/main.lua"), "-- runtime")
    eq(read(f.dir .. "/reading-settings"), "unchanged")
    eq(#py_list(f.dir), 2)
    assert(f.restart:find(version, 1, true))
    f.updater:check()
    eq(#f.requests, 3)
end)

test("Older and equal releases do not offer to install", function()
    for _, tag in ipairs({ "v1.9.8", "v1.9.9" }) do
        local f = fixture()
        f.release.tag_name = tag
        f.updater:check()
        f:drain()
        eq(f.confirmation, nil)
        assert(f.messages[#f.messages]:find("已是最新正式版", 1, true))
    end
end)

test("Prereleases and packages without a GitHub SHA-256 never install", function()
    for _, kind in ipairs({ "prerelease", "digest" }) do
        local f = fixture()
        if kind == "prerelease" then f.release.prerelease = true
        else f.release.assets[1].digest = nil end
        f.updater:check()
        f:drain()
        eq(f.confirmation, nil)
        eq(#f.requests, 1)
    end
end)

test("TLS hostname checks and redirect restrictions protect release requests", function()
    local f = fixture()
    f.certificate = "other.github.com"
    f.updater:check()
    f:drain()
    eq(f.confirmation, nil)
    f.certificate = "*.github.com"
    f.redirect = "http://release-assets.githubusercontent.com/update.zip"
    f:download()
    f:drain()
    eq(f.requests[#f.requests], "api.github.com")
    eq(f.restart, nil)
    eq(read(f.live .. "/main.lua"), "-- old installation")
end)

test("A bad checksum or bad archive leaves the old installation usable", function()
    for _, kind in ipairs({ "checksum", "traversal", "missing", "wrong version" }) do
        local f = fixture()
        if kind == "checksum" then f.bytes = string.rep("x", #bytes)
        elseif kind == "traversal" then f.entries[1].path = "liuju.koplugin/../reading-settings"
        elseif kind == "missing" then table.remove(f.entries)
        else f.entries[1].data = f.entries[1].data:gsub("1%.10", "1.11") end
        f:download()
        f:drain()
        eq(read(f.live .. "/main.lua"), "-- old installation")
        eq(read(f.dir .. "/reading-settings"), "unchanged")
        eq(#py_list(f.dir), 2)
        eq(f.restart, nil)
    end
end)

test("Cancelling or leaving the active screen before installation preserves the previous version", function()
    for _, kind in ipairs({ "tap", "suspend", "inactive" }) do
        local f = fixture()
        f:download()
        if kind == "tap" then f.progress.dismiss_callback()
        elseif kind == "suspend" then f.updater:cancel()
        else f.inactive = true end
        f:drain()
        eq(f.restart, nil)
        eq(read(f.live .. "/main.lua"), "-- old installation")
        eq(#py_list(f.dir), 2)
    end
end)

test("Failure to move the staged plugin restores the old installation", function()
    local f = fixture()
    f:download()
    local rename = os.rename
    os.rename = function(from, to)
        if from:match("/next$") and to == f.live then return nil, "simulated rename failure" end
        return rename(from, to)
    end
    local ok, err = pcall(f.drain, f)
    os.rename = rename
    assert(ok, err)
    eq(read(f.live .. "/main.lua"), "-- old installation")
    eq(#py_list(f.dir), 2)
    eq(f.restart, nil)
end)

test("A second filesystem error retains the old plugin as a recoverable backup", function()
    local f = fixture()
    f:download()
    local rename = os.rename
    os.rename = function(from, to)
        if to == f.live then return nil, "simulated rename failure" end
        return rename(from, to)
    end
    local ok, err = pcall(f.drain, f)
    os.rename = rename
    assert(ok, err)
    eq(read(f.live .. "/main.lua"), nil)
    local backup = assert(f.messages[#f.messages]:match("\n(.+)$"))
    eq(read(backup .. "/main.lua"), "-- old installation")
    eq(f.restart, nil)
end)
