-- GitHub release checks and staged installation, invoked only from the menu.
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")
local Updater = {}
Updater.__index = Updater

local REPO = "iamzhangjinpeng/liuju.koplugin"
local RELEASES = "https://api.github.com/repos/" .. REPO .. "/releases/"
local MAX_ZIP = 2 * 1024 * 1024
local MAX_UNPACKED = 8 * 1024 * 1024
local REQUIRED = {
    "_meta.lua", "main.lua", "liuju_core.lua", "liuju_draw.lua", "liuju_layout.lua",
    "liuju_policy.lua", "liuju_render.lua", "liuju_store.lua", "liuju_update.lua",
    "assets/lyrics-background.png", "assets/date-card-background.png", "assets/dark-card-background.png",
}
local worker, installed_version

local function version_parts(version)
    if type(version) ~= "string" then return end
    local a, b, c = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if a and #a <= 6 and #b <= 6 and #c <= 6 then
        return { tonumber(a), tonumber(b), tonumber(c) }
    end
end

local function is_newer(latest, current)
    local a, b = version_parts(latest), version_parts(current)
    if not a or not b then return false end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return false
end

local function asset_url(id)
    return RELEASES .. "assets/" .. id
end

local function host_matches(cert, host)
    if cert and cert.checkhost then return cert:checkhost(host) == true end
    -- LuaSec 1.3.2 exposes DNS subject alternative names but no checkhost.
    local names = cert and cert:extensions()["2.5.29.17"]
    local wildcard = host:gsub("^[^.]+", "*", 1)
    for _, name in ipairs(names and names.dNSName or {}) do
        if name:lower() == host or name:lower() == wildcard then return true end
    end
    return false
end

local function fetch(url, limit, asset)
    local http, https = require("socket.http"), require("ssl.https")
    require("socketutil"):set_timeout(8, 18)
    -- Use LuaSec's connector with explicit trust and a DNS name check before
    -- LuaSocket sends the HTTP request. Older KOReader defaults to verify=none.
    local tls = https.tcp{ verify = "peer", cafile = "./data/ca-bundle.crt" }
    http.PROXY = nil -- These requests run in the worker. LuaSec cannot tunnel through an HTTP proxy.
    for _ = 1, 4 do
        local host, path = url:match("^https://([%w%.%-]+)(/[^%s%c]*)$")
        if not host or (host ~= "api.github.com" and (not asset or
                (host ~= "release-assets.githubusercontent.com" and host ~= "objects.githubusercontent.com"))) then
            return nil, "redirect"
        end
        local chunks, size = {}, 0
        local ok, code, headers = http.request{
            url = "https://" .. host .. ":443" .. path,
            redirect = false,
            headers = { ["User-Agent"] = "KOReader-liuju.koplugin",
                Accept = asset and "application/octet-stream" or "application/vnd.github+json" },
            create = function()
                local connection = tls()
                local connect = connection.connect
                function connection:connect(peer, port)
                    local connected, err = connect(self, peer, port)
                    if not connected then return nil, err end
                    if peer ~= host or not host_matches(self:getpeercertificate(), host) then
                        self:close()
                        return nil, "TLS hostname mismatch"
                    end
                    return connected
                end
                return connection
            end,
            sink = function(chunk, err)
                if err then return nil, err end
                if chunk then
                    size = size + #chunk
                    if size > limit then return nil, "response too large" end
                    chunks[#chunks + 1] = chunk
                end
                return 1
            end,
        }
        if not ok then return nil, "network" end
        if code == 200 then return table.concat(chunks) end
        if not asset or (code ~= 301 and code ~= 302 and code ~= 303 and code ~= 307 and code ~= 308)
                or not headers or type(headers.location) ~= "string" then return nil, "HTTP " .. tostring(code) end
        url = headers.location
    end
    return nil, "redirect"
end

local function check_release(current)
    local body, err = fetch(RELEASES .. "latest", 128 * 1024, false)
    if not body then return nil, err end
    local release = require("dkjson").decode(body)
    if type(release) ~= "table" or release.draft ~= false or release.prerelease ~= false
            or type(release.tag_name) ~= "string" then return nil, "release metadata" end
    local version = release.tag_name:match("^v(.+)$")
    if not version_parts(version) then return nil, "release version" end
    if not is_newer(version, current) then return "current" end
    local name = "liuju.koplugin-v" .. version .. ".zip"
    if type(release.assets) ~= "table" then return nil, "release assets" end
    for _, asset in ipairs(release.assets) do
        if type(asset) == "table" and asset.name == name and asset.state == "uploaded" then
            local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
            local size, id = asset.size, asset.id
            if digest and #digest == 64 and type(size) == "number" and size % 1 == 0
                    and size > 0 and size <= MAX_ZIP and type(id) == "number"
                    and id % 1 == 0 and id > 0 and id < 2 ^ 53 then
                local asset_id = string.format("%.0f", id)
                if asset.url == asset_url(asset_id) then
                    return string.format("%s\n%d\n%s\n%s", version, size, digest:lower(), asset_id)
                end
            end
        end
    end
    return nil, "release package missing or invalid"
end

local function mode(path)
    return lfs.symlinkattributes(path, "mode")
end

local function write_file(path, content, sync)
    local file, err = io.open(path, "wb")
    if not file then error(err) end
    local ok, why = file:write(content)
    if ok then ok, why = file:flush() end
    if ok and sync then ok, why = ffiutil.fsyncOpenedFile(file, true) end
    local closed, close_err = file:close()
    assert(ok, why)
    assert(closed, close_err)
end

local function extract(zip, target, version)
    local reader = require("ffi/archiver").Reader:new()
    local ok, err = pcall(function()
        assert(reader:open(zip), reader.err)
        assert(lfs.mkdir(target))
        assert(lfs.mkdir(target .. "/assets"))
        local seen, size, count = {}, 0, 0
        while true do
            local entry = reader:next()
            if not entry then break end
            local name = entry.path:match("^liuju%.koplugin/(.*)$")
            local directory = entry.mode == "directory" and (name == "" or name == "assets/")
            assert(directory or (entry.mode == "file" and name and (name == "_meta.lua" or name == "main.lua"
                or name:match("^liuju_[a-z_]+%.lua$") or name:match("^assets/[a-z0-9%-]+%.png$"))), "unexpected ZIP entry")
            count = count + 1
            assert(not seen[name] and count <= 40, "duplicate or excessive ZIP entries")
            seen[name] = true
            if not directory then
                size = size + entry.size
                assert(entry.size > 0 and size <= MAX_UNPACKED, "invalid unpacked size")
                -- Read bytes, rather than letting the archiver create links or paths.
                local content = assert(reader:extractToMemory(entry.path), reader.err)
                assert(#content == entry.size, "incomplete ZIP entry")
                if name == "_meta.lua" then
                    assert(content:match('\n%s*version%s*=%s*"([%d%.]+)"%s*,') == version, "package version mismatch")
                end
                if name:match("%.lua$") then
                    assert(content:byte(1) ~= 27, "expected Lua source")
                    assert(loadstring(content, "@" .. name))
                end
                write_file(target .. "/" .. name, content, true)
            end
        end
        assert(not reader.err, reader.err)
        for _, name in ipairs(REQUIRED) do assert(seen[name], "missing " .. name) end
        assert(ffiutil.fsyncDirectory(target .. "/assets"))
        assert(ffiutil.fsyncDirectory(target))
    end)
    reader:close()
    if not ok then error(err, 0) end
end

local function prepare(core, stage, version, size, digest, id)
    local data, err = fetch(asset_url(id), size, true)
    if not data then return nil, err end
    if #data ~= size or core.hash(data) ~= digest then return nil, "package checksum" end
    local zip = stage .. "/package.zip"
    write_file(zip, data)
    extract(zip, stage .. "/next", version)
    assert(ffiutil.fsyncDirectory(stage))
    return "ready"
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

local function cleanup(stage)
    if stage then
        local ok, err = pcall(remove_tree, stage)
        if not ok then logger.warn("留句: 更新目录未能清理", tostring(err)) end
    end
end

local function staging_dir(parent)
    local prefix = parent .. "liuju-update-" .. os.time()
    for i = 1, 20 do
        local path = prefix .. "-" .. i
        if lfs.mkdir(path) then return path end
        if not mode(path) then break end
    end
end

local function replace(live, stage)
    local previous = stage .. "/previous"
    if mode(live) ~= "directory" or mode(stage .. "/next") ~= "directory" then return false end
    local moved, err = os.rename(live, previous)
    if not moved then return false, err end
    moved, err = os.rename(stage .. "/next", live)
    if moved then return true end
    local restored, why = os.rename(previous, live)
    if not restored then return false, why, previous end
    return false, err
end

local function tell(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function Updater.new(core, path, current, alive)
    return setmetatable({ core = core, path = path:gsub("/+$", ""), current = current, alive = alive }, Updater)
end

function Updater:cancel()
    if worker and worker.owner == self then worker.stop() end
end

function Updater:_run(text, stage, task, complete)
    local ok, pid, fd = pcall(ffiutil.runInSubProcess, function(_, child_fd)
        local ran, result, why = pcall(task)
        if not ran or not result then logger.warn("留句: 在线更新失败", tostring(ran and why or result)) end
        ffiutil.writeToFD(child_fd, ran and result or "error", true)
    end, true)
    if not ok or not pid then
        cleanup(stage)
        tell(_("无法启动更新任务，请稍后重试。"))
        return
    end
    local job = { owner = self }
    worker = job
    local dialog, poll, deadline
    local function stop()
        if worker ~= job or job.cancelled then return end
        job.cancelled = true
        ffiutil.terminateSubProcess(pid)
    end
    job.stop = stop
    deadline = function()
        job.timed_out = true
        stop()
    end
    dialog = InfoMessage:new{ text = text, dismissable = true, dismiss_callback = stop }
    UIManager:show(dialog)
    UIManager:preventStandby()
    poll = function()
        if not ffiutil.isSubProcessDone(pid) then
            if job.cancelled then ffiutil.terminateSubProcess(pid) end
            UIManager:scheduleIn(0.2, poll)
            return
        end
        worker = nil
        UIManager:unschedule(deadline)
        if UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
        UIManager:allowStandby()
        local read_ok, result = pcall(ffiutil.readAllFromFD, fd)
        if job.cancelled or not self.alive() then
            cleanup(stage)
            if job.timed_out and self.alive() then tell(_("在线更新超时，请检查网络后重试。")) end
            return
        end
        complete(read_ok and result or nil)
    end
    UIManager:scheduleIn(0.2, poll)
    UIManager:scheduleIn(30, deadline)
end

function Updater:_install(version, size, digest, id)
    if not self.alive() or worker or installed_version then return end
    local parent = self.path:match("^(.*[/])liuju%.koplugin$")
    if not parent or mode(self.path) ~= "directory" then
        tell(_("无法确认留句的安装目录，请通过 USB 手动更新。"))
        return
    end
    local stage = staging_dir(parent)
    if not stage then tell(_("无法创建更新目录，请检查剩余空间。")); return end
    self:_run(_("正在下载和校验留句更新…\n轻触可取消。"), stage, function()
        return prepare(self.core, stage, version, size, digest, id)
    end, function(result)
        if result ~= "ready" then
            cleanup(stage)
            tell(_("下载或校验失败，已保留当前版本。请检查网络和剩余空间后重试。"))
            return
        end
        local ok, err, backup = replace(self.path, stage)
        if not ok then
            logger.warn("留句: 无法替换插件目录", tostring(err))
            if backup then
                tell(_("无法恢复旧版本。请通过 USB 将以下目录移回 liuju.koplugin。\n") .. backup)
            else
                cleanup(stage)
                tell(_("安装失败，已保留当前版本。"))
            end
            return
        end
        installed_version = version
        if ffiutil.fsyncDirectory(stage) and ffiutil.fsyncDirectory(parent) then
            cleanup(stage)
        else
            logger.warn("留句: 更新备份仍保留在", stage)
        end
        UIManager:askForRestart(string.format(_("留句 %s 已安装。重启 KOReader 后生效。"), version))
    end)
end

function Updater:check()
    if not self.alive() then return end
    if installed_version then
        UIManager:askForRestart(string.format(_("留句 %s 已安装。重启 KOReader 后生效。"), installed_version))
        return
    end
    if worker then tell(_("留句正在检查或下载更新。")); return end
    if not version_parts(self.current) then tell(_("无法识别当前版本，请通过 USB 手动更新。")); return end
    require("ui/network/manager"):runWhenConnected(function()
        if not self.alive() or worker or installed_version then return end
        self:_run(_("正在检查留句更新…\n轻触可取消。"), nil, function()
            return check_release(self.current)
        end, function(result)
            if result == "current" then
                tell(string.format(_("当前版本 %s 已是最新正式版。"), self.current))
                return
            end
            local version, size, digest, id = (result or ""):match("^([%d%.]+)\n(%d+)\n(%x+)\n(%d+)$")
            if not version then
                tell(_("暂时无法检查更新，请确认 Wi-Fi 能访问 GitHub 后重试。"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = string.format(_("当前版本 %s，发现正式版 %s。是否下载并安装？"), self.current, version),
                ok_text = _("下载并安装"),
                ok_callback = function() self:_install(version, tonumber(size), digest, id) end,
            })
        end)
    end)
end

return Updater
