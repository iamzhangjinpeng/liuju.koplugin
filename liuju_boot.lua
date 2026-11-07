-- The installed launcher remains on disk across online updates. Keep the
-- version 1 state format compatible between it and future payloads.
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Boot = {}
Boot.__index = Boot

local function mode(path)
    return lfs.symlinkattributes(path, "mode")
end

local function valid_slot(slot)
    return type(slot) == "string" and #slot <= 25 and slot:match("^slot%-%d+%-%d+$") ~= nil
end

local function valid_version(version)
    return type(version) == "string" and #version <= 20 and version:match("^%d+%.%d+%.%d+$") ~= nil
end

function Boot.new(root)
    root = root:gsub("/+$", "") .. "/"
    return setmetatable({ root = root, dir = root .. ".liuju-versions" }, Boot)
end

function Boot:path(slot)
    if slot == "base" then return self.root end
    assert(valid_slot(slot))
    return self.dir .. "/" .. slot .. "/"
end

-- Confirmed is the last version that initialized successfully. A testing
-- record left by an interrupted startup tells us to boot that version again.
function Boot:read()
    local fallback = { active = "base" }
    local kind = mode(self.dir)
    if not kind then return fallback, true end
    if kind ~= "directory" then return fallback, false end
    local path = self.dir .. "/state"
    kind = mode(path)
    if not kind then return fallback, true end
    if kind ~= "file" then return fallback, false end
    local file = io.open(path, "rb")
    if not file then return fallback, false end
    local value = file:read(128)
    file:close()
    if not value or #value >= 128 then return fallback, false end
    local phase, active, rest = value:match("^1 (%a+) ([%w%-]+)([^\n]*)\n$")
    if active ~= "base" and not valid_slot(active) then return fallback, false end
    local pending, version
    if phase == "ready" or phase == "testing" then
        pending, version, rest = rest:match("^ ([%w%-]+) ([%d%.]+)(.*)$")
        if not valid_slot(pending) or active == pending or not valid_version(version) then return fallback, false end
    elseif phase ~= "confirmed" then
        return fallback, false
    end
    local previous = rest:match("^ ([%w%-]+)$")
    if rest ~= "" and (not valid_slot(previous) or previous == active or previous == pending) then
        return fallback, false
    end
    return { active = active, phase = pending and phase, pending = pending, version = version, previous = previous }, true
end

-- Once rename succeeds the record is visible, even if the directory sync
-- subsequently fails. Callers must keep every referenced payload in that case.
local function write_record(dir, name, value)
    local ffiutil = require("ffi/util")
    local target = dir .. "/" .. name
    local path = target .. ".tmp"
    if mode(path) and not os.remove(path) then return false, false end
    local file = io.open(path, "wb")
    if not file then return false, false end
    local ok = file:write(value)
    if ok then ok = file:flush() end
    if ok then
        local called, synced = pcall(ffiutil.fsyncOpenedFile, file, true)
        ok = called and synced
    end
    local closed = file:close()
    if not ok or not closed or not os.rename(path, target) then
        os.remove(path)
        return false, false
    end
    local called, synced = pcall(ffiutil.fsyncDirectory, dir)
    return true, called and synced
end

function Boot:write(value)
    return write_record(self.dir, "state", value)
end

local READER_RECORD = "reader.state"

function Boot:reader_status(slot)
    if not valid_slot(slot) then return end
    local path = self:path(slot) .. READER_RECORD
    local kind = mode(path)
    if not kind then return end
    local file = kind == "file" and io.open(path, "rb")
    if not file then return "testing" end
    local value = file:read(9)
    file:close()
    return value == "ok\n" and "ok" or "testing"
end

local function remove_tree(path)
    local kind = mode(path)
    if kind == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove_tree(path .. "/" .. name) end
        end
    end
    if kind then assert(os.remove(path)) end
end

function Boot.remove(path)
    local ok, err = pcall(remove_tree, path)
    if not ok then logger.warn("留句: 更新目录未能清理", tostring(err)) end
end

local function previous_field(slot)
    return valid_slot(slot) and " " .. slot or ""
end

function Boot:confirm(slot, previous)
    return self:write("1 confirmed " .. slot .. previous_field(previous) .. "\n")
end

function Boot:mark(phase, state)
    return self:write(string.format("1 %s %s %s %s%s\n", phase, state.active, state.pending,
        state.version, previous_field(state.previous)))
end

function Boot:quarantine_state()
    local _, valid = self:read()
    if valid then return true end
    if mode(self.dir) ~= "directory" then return end
    local path = self.dir .. "/state"
    if mode(path) ~= "file" then return end
    local prefix = path .. ".invalid-" .. os.time() .. "-"
    for i = 1, 20 do
        local backup = prefix .. i
        if not mode(backup) then
            local ok, err = os.rename(path, backup)
            if ok then require("ffi/util").fsyncDirectory(self.dir)
            else logger.warn("留句: 无法移开损坏的更新状态", tostring(err)) end
            return ok
        end
    end
end

function Boot:publish(payload, version)
    if not valid_version(version) then return false, "invalid update version" end
    local state, valid = self:read()
    if not valid or state.pending then return false, "invalid or pending update state" end
    if not mode(self.dir) then assert(lfs.mkdir(self.dir)) end
    local ffiutil = require("ffi/util")
    if not ffiutil.fsyncDirectory(self.root) then return false, "cannot sync plugin directory" end
    local prefix = "slot-" .. os.time() .. "-"
    for i = 1, 20 do
        local slot = prefix .. i
        local path = self.dir .. "/" .. slot
        if not mode(path) then
            local ok, err = os.rename(payload, path)
            if not ok then return false, err end
            local source = payload:match("^(.*)/[^/]+$")
            if not ffiutil.fsyncDirectory(self.dir) or not ffiutil.fsyncDirectory(source) then
                return false, "cannot sync staged version"
            end
            state.pending, state.version = slot, version
            return self:mark("ready", state)
        end
    end
    return false, "cannot allocate a version directory"
end

local function read_meta(path)
    local load = assert(loadfile(path .. "_meta.lua"))
    local meta = load(true)
    assert(type(meta) == "table" and valid_version(meta.version), "invalid version metadata")
    return meta
end

function Boot:active_metadata()
    local state = self:read()
    if state.active ~= "base" then
        local ok, meta = pcall(read_meta, self:path(state.active))
        if ok then return meta end
    end
end

function Boot:load_slot(slot, expected_version)
    local path = self:path(slot)
    assert(mode(path:sub(1, -2)) == "directory", "missing plugin version")
    local meta = read_meta(path)
    assert(not expected_version or meta.version == expected_version, "update version mismatch")
    local module = dofile(path .. "liuju_plugin.lua")
    assert(type(module) == "table" and type(module.new) == "function", "invalid plugin entry point")
    return module, meta.version
end

function Boot:prune(active)
    -- A missing state can also mean filesystem damage. In that case leave
    -- any recoverable slots intact, just as for an unreadable state.
    if mode(self.dir) ~= "directory" or mode(self.dir .. "/state") ~= "file" then return end
    local state, valid = self:read()
    if not valid or state.pending or state.active ~= active then return end
    local ok, err = pcall(function()
        if not require("ffi/util").fsyncDirectory(self.dir) then return end
        local stale = {}
        for name in lfs.dir(self.dir) do
            if valid_slot(name) and name ~= active and name ~= state.previous then stale[#stale + 1] = name end
        end
        for _, slot in ipairs(stale) do Boot.remove(self.dir .. "/" .. slot) end
    end)
    if not ok then logger.warn("留句: 更新备份未能清理", tostring(err)) end
end

function Boot:guard(module, version, slot, rollback, rollback_previous, on_start)
    local boot, create = self, module.new
    local reader_ready = slot and type(module.onReaderReady) == "function" and module.onReaderReady
    local trials = setmetatable({}, { __mode = "k" })
    local rejected = false
    local function reject(attr, err)
        if rollback then
            rejected = true
            if type(module._shutdown) == "function" and attr._generation then pcall(module._shutdown, attr) end
            logger.warn("留句: 插件初始化失败", tostring(err))
            local visible = boot:confirm(rollback, rollback_previous)
            local message = visible and "留句启动失败。重启 KOReader 后将恢复上一版本。"
                or "留句启动失败，无法写入恢复状态。请重启 KOReader，或通过 USB 重新安装。"
            require("ui/uimanager"):askForRestart(require("gettext")(message))
        end
        error(err or "invalid plugin instance", 0)
    end
    local function confirm_start(reader_trial)
        if reader_trial then
            local _, synced = write_record(boot:path(slot), READER_RECORD, "ok\n")
            if not synced then
                logger.warn("留句: 阅读界面的启动确认未能写入磁盘")
                return
            end
        end
        if on_start and on_start() then on_start, rollback_previous = nil, nil end
    end
    if reader_ready then
        function module:onReaderReady(...)
            local trial = trials[self]
            if not trial then return reader_ready(self, ...) end
            local ok, result = pcall(reader_ready, self, ...)
            if not ok then
                trials[self] = nil
                if trial.constructed then reject(self, result) end
                error(result, 0)
            end
            trial.ready = true
            if trial.constructed and not trial.post_ready then
                trials[self] = nil
                confirm_start(true)
            end
            return result
        end
    end
    function module:new(attr)
        if rejected then error("plugin update was rolled back", 0) end
        attr = attr or {}
        attr.version = version
        -- Library startup can confirm a version before it ever opens a book.
        -- Leave a separate durable record around that first reader startup so
        -- a process crash can roll back even when Lua cannot catch the error.
        local reader_trial = slot and attr.ui and attr.ui.document and boot:reader_status(slot) ~= "ok"
        if reader_trial then
            local _, synced = write_record(boot:path(slot), READER_RECORD, "testing\n")
            if not synced then reject(attr, "cannot record reader startup") end
        end
        local trial = reader_trial and reader_ready and {}
        if trial then trials[attr] = trial end
        local started, instance = pcall(create, self, attr)
        if trial then trials[attr] = nil end
        if not started or type(instance) ~= "table" then
            reject(attr, instance)
        end
        if trial and not trial.ready then
            trial.constructed = true
            trials[instance] = trial
            -- KOReader dispatches ReaderReady after constructing plugins.
            -- Confirm after the dispatch when the host offers its callback.
            if type(attr.ui.registerPostReaderReadyCallback) == "function" then
                trial.post_ready = true
                attr.ui:registerPostReaderReadyCallback(function()
                    if trials[instance] ~= trial then return end
                    trials[instance] = nil
                    if trial.ready then confirm_start(true) end
                end)
            end
        else
            confirm_start(reader_trial)
        end
        return instance
    end
    return module
end

function Boot:load_previous(state, reason)
    logger.warn("留句: 尝试回退到上一版本", tostring(reason))
    local previous = state.previous or "base"
    if self:reader_status(previous) == "testing" then previous = "base" end
    local ok, module, version = pcall(self.load_slot, self, previous)
    if not ok and previous ~= "base" then
        previous = "base"
        module, version = self:load_slot(previous)
    elseif not ok then
        error(module, 0)
    end
    self:confirm(previous)
    if previous ~= "base" then return self:guard(module, version, previous, "base") end
    return module
end

function Boot:load()
    local state, valid = self:read()
    if self:reader_status(state.active) == "testing" then
        return self:load_previous(state, "first reader startup was interrupted")
    end
    if state.phase == "ready" then
        local recorded, synced = self:mark("testing", state)
        if recorded and synced then
            local ok, candidate, version = pcall(self.load_slot, self, state.pending, state.version)
            if ok then
                return self:guard(candidate, version, state.pending, state.active, state.previous, function()
                    local visible, durable = self:confirm(state.pending, state.active)
                    if visible and durable then
                        self:prune(state.pending)
                        return true
                    end
                    logger.warn("留句: 新版本的启动确认未能写入磁盘")
                end)
            end
            logger.warn("留句: 新版本无法加载", tostring(candidate))
        end
    end
    if state.pending then
        logger.warn("留句: 放弃未完成的更新", state.version)
        local visible, durable = self:confirm(state.active, state.previous)
        valid = visible and durable
    end
    local ok, module, version = pcall(self.load_slot, self, state.active)
    if not ok then
        if state.active == "base" then error(module, 0) end
        return self:load_previous(state, module)
    end
    if not valid and state.active == "base" then
        return self:guard(module, version, nil, nil, nil, function()
            local checked, repaired = pcall(self.quarantine_state, self)
            if not checked then logger.warn("留句: 无法修复更新状态", tostring(repaired)) end
            return checked and repaired
        end)
    end
    if valid then self:prune(state.active) end
    if state.active ~= "base" then return self:guard(module, version, state.active, state.previous or "base") end
    return module
end

return Boot
