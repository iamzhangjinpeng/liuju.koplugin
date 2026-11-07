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
local launcher = read(TEST_ROOT .. "/main.lua")
local function meta(version_number)
    return 'return {\n    version = "' .. version_number .. '",\n}\n'
end
local runtime = "return { new = function(_, attr) return attr end }"
local function fixture()
    number = number + 1
    local dir = SCRATCH .. "/ota-" .. number
    local f = { dir = dir, live = dir .. "/liuju.koplugin", requests = {}, tasks = {},
        messages = {}, entries = {}, standby = 0, connected = 0 }
    py_mkdir(f.live)
    write(f.live .. "/main.lua", launcher)
    write(f.live .. "/liuju_boot.lua", read(TEST_ROOT .. "/liuju_boot.lua"))
    write(f.live .. "/liuju_plugin.lua", runtime)
    local base_meta = read(TEST_ROOT .. "/_meta.lua"):gsub('version = "[%d%.]+"', 'version = "1.9.9"', 1)
    write(f.live .. "/_meta.lua", base_meta)
    write(dir .. "/reading-settings", "unchanged")
    for _, name in ipairs({ "_meta.lua", "main.lua", "liuju_boot.lua", "liuju_plugin.lua",
        "liuju_core.lua", "liuju_draw.lua", "liuju_layout.lua", "liuju_metadata.lua",
        "liuju_policy.lua", "liuju_render.lua", "liuju_store.lua", "liuju_update.lua",
        "assets/lyrics-background.png", "assets/date-card-background.png", "assets/dark-card-background.png" }) do
        local data = name == "_meta.lua" and meta(version) or name == "liuju_plugin.lua" and runtime or "-- runtime"
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
    f.boot = dofile(TEST_ROOT .. "/liuju_boot.lua").new(f.live)
    function f:new_updater(current)
        local Updater = dofile(TEST_ROOT .. "/liuju_update.lua")
        self.updater = Updater.new({ hash = py_hash }, self.live, current, function() return not self.inactive end)
    end
    f:new_updater("1.9.9")
    return f
end

local function test(name, fn)
    fn()
    print("PASS " .. name)
end

test("Manual update stages a newer official release and commits it after the first startup", function()
    local f = fixture()
    eq(f.connected, 0)
    f.updater:check()
    f:drain()
    eq(#f.requests, 1)
    eq(read(f.live .. "/main.lua"), launcher)
    assert(f.confirmation.text:find(version, 1, true))
    f.confirmation.ok_callback()
    f:drain()
    eq(table.concat(f.requests, ","), "api.github.com,api.github.com,release-assets.githubusercontent.com")
    eq(read(f.live .. "/main.lua"), launcher)
    local state = f.boot:read()
    eq(state.active, "base")
    eq(state.phase, "ready")
    assert(read(f.boot:path(state.pending) .. "liuju_plugin.lua"))
    eq(read(f.dir .. "/reading-settings"), "unchanged")
    eq(#py_list(f.dir), 2)
    assert(f.restart:find(version, 1, true))
    f.updater:check()
    eq(#f.requests, 3)
    local plugin = dofile(f.live .. "/main.lua")
    eq(f.boot:read().phase, "testing")
    eq(dofile(f.live .. "/_meta.lua").version, "1.9.9")
    eq(plugin:new({ version = "1.9.9" }).version, version)
    eq(f.boot:read().active, state.pending)
    eq(f.boot:read().pending, nil)
    assert(f.boot:active_metadata().version == version)
    eq(dofile(f.live .. "/_meta.lua").version, version)
    eq(read(f.live .. "/main.lua"), launcher)
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
    eq(read(f.live .. "/main.lua"), launcher)
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
        eq(read(f.live .. "/main.lua"), launcher)
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
        eq(read(f.live .. "/main.lua"), launcher)
        eq(#py_list(f.dir), 2)
    end
end)

test("A failed payload or state rename leaves the plugin discoverable and bootable", function()
    for _, failure in ipairs({ "payload", "state" }) do
        local f = fixture()
        f:download()
        local rename = os.rename
        os.rename = function(from, to)
            if (failure == "payload" and from:match("/next$"))
                    or (failure == "state" and to:match("/%.liuju%-versions/state$")) then
                return nil, "simulated rename failure"
            end
            return rename(from, to)
        end
        local ok, err = pcall(f.drain, f)
        os.rename = rename
        assert(ok, err)
        eq(read(f.live .. "/main.lua"), launcher)
        eq(f.boot:read().active, "base")
        eq(f.boot:read().pending, nil)
        assert(dofile(f.live .. "/main.lua"):new({}))
        eq(f.restart, nil)
    end
end)

test("A startup interrupted before confirmation reopens the previous confirmed version", function()
    local f = fixture()
    f:download()
    f:drain()
    local state = f.boot:read()
    dofile(f.live .. "/main.lua") -- Trial starts, but KOReader never finishes creating the instance.
    eq(f.boot:read().phase, "testing")
    assert(read(f.boot:path(state.pending) .. "liuju_plugin.lua"))
    local previous = dofile(f.live .. "/main.lua")
    assert(previous:new({}))
    eq(f.boot:read().active, "base")
    eq(f.boot:read().pending, nil)
    eq(read(f.boot:path(state.pending) .. "liuju_plugin.lua"), nil)
end)

test("A candidate that fails to load leaves the previous version usable on the same boot", function()
    local f = fixture()
    f:download()
    f:drain()
    local pending = f.boot:read().pending
    write(f.boot:path(pending) .. "liuju_plugin.lua", 'error("missing dependency")')
    assert(dofile(f.live .. "/main.lua"):new({}))
    eq(f.boot:read().active, "base")
    eq(f.boot:read().pending, nil)
end)

test("A candidate that fails initialization retains the prior online version", function()
    local f = fixture()
    f:download()
    f:drain()
    dofile(f.live .. "/main.lua"):new({})
    local previous = f.boot:read().active
    f:new_updater(version)
    f.release.tag_name = "v1.11.0"
    f.release.assets[1].name = "liuju.koplugin-v1.11.0.zip"
    f.entries[1].data = meta("1.11.0")
    f.entries[1].size = #f.entries[1].data
    f:download()
    f:drain()
    local pending = f.boot:read().pending
    write(f.boot:path(pending) .. "liuju_plugin.lua", 'return { new = function() error("init failure") end }')
    local trial = dofile(f.live .. "/main.lua")
    assert(read(f.boot:path(previous) .. "liuju_plugin.lua"))
    local ok, err = pcall(trial.new, trial, {})
    eq(ok, false)
    assert(err:find("init failure", 1, true))
    eq(f.boot:read().active, previous)
    eq(f.boot:read().pending, nil)
    assert(f.restart:find("启动失败", 1, true))
    assert(dofile(f.live .. "/main.lua"):new({}))
    eq(f.boot:active_metadata().version, version)
end)

test("A confirmation whose directory sync fails keeps the previous online version on disk", function()
    local f = fixture()
    f:download()
    f:drain()
    dofile(f.live .. "/main.lua"):new({})
    local previous = f.boot:read().active
    f:new_updater(version)
    f.release.tag_name = "v1.11.0"
    f.release.assets[1].name = "liuju.koplugin-v1.11.0.zip"
    f.entries[1].data = meta("1.11.0")
    f.entries[1].size = #f.entries[1].data
    f:download()
    f:drain()
    local trial = dofile(f.live .. "/main.lua")
    local ffiutil = require("ffi/util")
    ffiutil.fsyncDirectory = function() return false end
    eq(trial:new({}).version, "1.11.0")
    assert(read(f.boot:path(previous) .. "liuju_plugin.lua"))
    ffiutil.fsyncDirectory = function() return true end
    assert(dofile(f.live .. "/main.lua"):new({}))
    eq(f.boot:active_metadata().version, "1.11.0")
    assert(read(f.boot:path(previous) .. "liuju_plugin.lua"))
    eq(f.boot:read().previous, previous)
end)

test("A missing state file falls back to the base without deleting the last online version", function()
    local f = fixture()
    f:download()
    f:drain()
    dofile(f.live .. "/main.lua"):new({})
    local previous = f.boot:read().active
    assert(os.remove(f.boot.dir .. "/state"))
    assert(dofile(f.live .. "/main.lua"):new({}))
    eq(dofile(f.live .. "/_meta.lua").version, "1.9.9")
    assert(read(f.boot:path(previous) .. "liuju_plugin.lua"))
end)

test("A version that starts in the library can still roll back after reader initialization fails", function()
    for _, reopen in ipairs({ false, true }) do
        local f = fixture()
        f:download()
        f:drain()
        dofile(f.live .. "/main.lua"):new({})
        local previous = f.boot:read().active
        f:new_updater(version)
        f.release.tag_name = "v1.11.0"
        f.release.assets[1].name = "liuju.koplugin-v1.11.0.zip"
        f.entries[1].data = meta("1.11.0")
        f.entries[1].size = #f.entries[1].data
        f:download()
        f:drain()
        local pending = f.boot:read().pending
        write(f.boot:path(pending) .. "liuju_plugin.lua", [[
            return { new = function(_, attr)
                if attr.ui.document then error("reader init failure") end
                return attr
            end }
        ]])
        local plugin = dofile(f.live .. "/main.lua")
        eq(plugin:new({ ui = {} }).version, "1.11.0")
        eq(f.boot:read().previous, previous)
        if reopen then plugin = dofile(f.live .. "/main.lua") end
        local ok, err = pcall(plugin.new, plugin, { ui = { document = {} } })
        eq(ok, false)
        assert(err:find("reader init failure", 1, true))
        eq(f.boot:read().active, previous)
        assert(f.restart:find("启动失败", 1, true))
        eq(dofile(f.live .. "/main.lua"):new({}).version, version)
    end
end)

test("The first reader startup records its trial before initialization and clears it on success", function()
    local f = fixture()
    f:download()
    f:drain()
    local slot = f.boot:read().pending
    local path = f.boot:path(slot)
    write(path .. "liuju_plugin.lua", [[
        return { new = function(_, attr)
            if attr.ui.document then
                local marker = assert(io.open(attr.marker, "rb"))
                assert(marker:read("*a") == attr.expected)
                marker:close()
            end
            return attr
        end }
    ]])
    local plugin = dofile(f.live .. "/main.lua")
    eq(plugin:new({ ui = {} }).version, version)
    eq(read(path .. "reader.state"), nil)
    local marker = path .. "reader.state"
    plugin:new({ ui = { document = {} }, marker = marker, expected = "testing\n" })
    eq(read(marker), "ok\n")
    local next_boot = dofile(f.live .. "/main.lua")
    eq(next_boot:new({ ui = { document = {} }, marker = marker, expected = "ok\n" }).version, version)
end)

test("An interrupted reader startup rolls back a version already confirmed in the library", function()
    local f = fixture()
    f:download()
    f:drain()
    dofile(f.live .. "/main.lua"):new({})
    local previous = f.boot:read().active
    f:new_updater(version)
    f.release.tag_name = "v1.11.0"
    f.release.assets[1].name = "liuju.koplugin-v1.11.0.zip"
    f.entries[1].data = meta("1.11.0")
    f.entries[1].size = #f.entries[1].data
    f:download()
    f:drain()
    eq(dofile(f.live .. "/main.lua"):new({ ui = {} }).version, "1.11.0")
    write(f.boot:path(f.boot:read().active) .. "reader.state", "testing\n")
    local restarted = dofile(f.live .. "/main.lua")
    eq(f.boot:read().active, previous)
    eq(restarted:new({ ui = { document = {} } }).version, version)
end)

test("Reader startup is confirmed only after ReaderReady and the host's post-ready callback", function()
    local f = fixture()
    f:download()
    f:drain()
    local slot = f.boot:read().pending
    local marker = f.boot:path(slot) .. "reader.state"
    write(f.boot:path(slot) .. "liuju_plugin.lua", [[
        return {
            new = function(_, attr) return attr end,
            onReaderReady = function(self) assert(self.ui.doc_props) end,
        }
    ]])
    local ui = { document = {}, registerPostReaderReadyCallback = function(self, callback) self.after = callback end }
    local plugin = dofile(f.live .. "/main.lua")
    local instance = plugin:new({ ui = ui })
    eq(read(marker), "testing\n")
    eq(f.boot:read().phase, "testing")
    ui.doc_props = {}
    plugin.onReaderReady(instance)
    eq(read(marker), "testing\n")
    ui.after()
    eq(read(marker), "ok\n")
    eq(f.boot:read().active, slot)
end)

test("ReaderReady errors cannot confirm a trial version", function()
    local f = fixture()
    f:download()
    f:drain()
    local slot = f.boot:read().pending
    write(f.boot:path(slot) .. "liuju_plugin.lua", [[
        return {
            new = function(_, attr) return attr end,
            onReaderReady = function() error("reader ready failed") end,
        }
    ]])
    local ui = { document = {}, registerPostReaderReadyCallback = function(self, callback) self.after = callback end }
    local plugin = dofile(f.live .. "/main.lua")
    local instance = plugin:new({ ui = ui })
    local ok, err = pcall(plugin.onReaderReady, instance)
    eq(ok, false)
    assert(err:find("reader ready failed", 1, true))
    ui.after()
    eq(f.boot:read().active, "base")
    eq(f.boot:reader_status(slot), "testing")
end)

test("A damaged update state is kept aside after the USB version starts, allowing a fresh update", function()
    local f = fixture()
    f:download()
    f:drain()
    dofile(f.live .. "/main.lua"):new({})
    local previous = f.boot:read().active
    local journal = f.boot.dir .. "/state"
    write(journal, "1 conf")
    local base = dofile(f.live .. "/main.lua")
    eq(read(journal), "1 conf")
    eq(base:new({}).version, "1.9.9")
    eq(read(journal), nil)
    local backup
    for _, name in ipairs(py_list(f.boot.dir)) do
        if name:match("^state%.invalid%-") then backup = read(f.boot.dir .. "/" .. name) end
    end
    eq(backup, "1 conf")
    f:new_updater("1.9.9")
    f:download()
    f:drain()
    eq(f.boot:read().phase, "ready")
    assert(read(f.boot:path(previous) .. "liuju_plugin.lua"))
    eq(dofile(f.live .. "/main.lua"):new({}).version, version)
end)
