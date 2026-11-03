-- 留句: current-book annotations -> cached receipt PNGs -> KOReader sleep screen.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local base = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local function load_module(name) return dofile(base .. "liuju_" .. name .. ".lua") end
local Core, Layout, Policy, Store = load_module("core"), load_module("layout"), load_module("policy"), load_module("store")
local Renderer = load_module("render")
local Draw = load_module("draw")
local Liuju = WidgetContainer:extend{ name = "liuju", is_doc_only = false }
local active_instance
local unsupported_notified = false
local LIMIT, LAST_BOOK = "liuju_character_limit", "liuju_last_book"

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end
local function fingerprint(path)
    local attrs = path and lfs.attributes(path)
    return attrs and Core.pack({ attrs.size, attrs.modification }) or ""
end
local function total(reasons)
    local n = 0
    for _, value in pairs(reasons) do n = n + value end
    return n
end

function Liuju:init()
    if active_instance then active_instance:_shutdown() end
    active_instance = self
    self._stopped, self._suspended = false, false
    self._generation = 0
    self.policy = Policy.new(G_reader_settings)
    self.renderer = Renderer.new(Core, Layout, Draw)
    self.root = DataStorage:getDataDir() .. "/screenshots/liuju"
    self.state_root = DataStorage:getSettingsDir() .. "/liuju"
    self.empty_dir = self.root .. "/empty"
    self.ui.menu:registerToMainMenu(self)
    if self.policy:enabled() then self.policy:check()
    else self.policy:restore(false) end
    -- ReaderReady handles normal opening. This path handles re-enabling a
    -- plugin while a reader is already initialized.
    if self.ui.document and self.ui.doc_props then self:_queue_sync(false, false) end
end

function Liuju:_clear_timer()
    if self._timer then UIManager:unschedule(self._timer); self._timer = nil end
end

function Liuju:_cancel_job()
    self:_clear_timer()
    self._generation = self._generation + 1
    if self._job and self._job.book.cover then
        pcall(self._job.book.cover.free, self._job.book.cover)
    end
    self._job = nil
end

function Liuju:_shutdown()
    self:_cancel_job()
    self._stopped = true
    if active_instance == self then active_instance = nil end
end

function Liuju:_current()
    return not self._stopped and active_instance == self and self.ui.document and self.ui.document.file
end

function Liuju:_schedule(callback, delay)
    self:_clear_timer()
    if self._suspended then return end
    self._timer = function()
        self._timer = nil
        if not self._stopped and active_instance == self and not self._suspended then callback() end
    end
    UIManager:scheduleIn(delay or 0.12, self._timer)
end

function Liuju:_safeguard()
    local file = self:_current()
    if not file or not self.policy:check() then return end
    util.makePath(self.empty_dir)
    -- Explicit document_cover does not rely on readhistory.lastfile, which can
    -- still refer to another book when history freezing is enabled.
    local image = file
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if type(last) == "table" and last.id == Core.book_id(file) then
        local cover = self.state_root .. "/" .. last.id .. "-cover.png"
        if Store.valid_png(cover, last.width, last.height) then image = cover end
    end
    local screen = Device.screen
    G_reader_settings:saveSetting(LAST_BOOK, {
        id = Core.book_id(file),
        width = math.min(screen:getWidth(), screen:getHeight()),
        height = math.max(screen:getWidth(), screen:getHeight()),
    })
    self.policy:apply{ dir = self.empty_dir, image = image }
end

function Liuju:_queue_sync(force, show_result)
    if not self:_current() or not self.policy:check() then return end
    force = force or self._force
    show_result = show_result or self._show_result
    self:_cancel_job()
    self._force, self._show_result = force, show_result
    local ok, err = pcall(self._safeguard, self)
    if not ok then logger.warn("留句: 暂存屏保失败", tostring(err)) end
    self:_schedule(function() self:_start_sync() end, 0.4)
end

function Liuju:_book_snapshot()
    local doc = self.ui.document
    local props = self.ui.doc_props or (doc.getProps and doc:getProps()) or {}
    local title = Core.clean(props.display_title or props.title)
    if not title or title == "" then
        title = Core.clean(doc.file:match("([^/]+)$") or "") or ""
        title = title:gsub("%.[^%.]+$", "")
    end
    if title == "" then title = _("未命名书籍") end
    local cover, cover_file
    local ok, image, custom_file = pcall(function()
        if self.ui.bookinfo and self.ui.bookinfo.getCoverImage then
            return self.ui.bookinfo:getCoverImage(doc)
        elseif doc.getCoverPageImage then return doc:getCoverPageImage() end
    end)
    if ok then cover, cover_file = image, custom_file
    else logger.warn("留句: 使用书名封面", tostring(image)) end
    return { file = doc.file, title = title, cover = cover, cover_file = cover_file }
end

function Liuju:_start_sync()
    if not self:_current() or not self.policy:check() then self:_cancel_job(); return end
    local force, show_result = self._force, self._show_result
    self._force, self._show_result = nil, nil
    local book
    local ok, err = pcall(function()
        book = self:_book_snapshot()
        local screen = Device.screen
        local width, height = math.min(screen:getWidth(), screen:getHeight()), math.max(screen:getWidth(), screen:getHeight())
        local id = Core.book_id(book.file)
        local key = Core.pack({ Core.LAYOUT_VERSION, width, height, book.title,
            fingerprint(book.file), book.cover_file, fingerprint(book.cover_file),
            G_reader_settings:readSetting("use_xtext"), Draw.signature and Draw:signature() or "" })
        local annotations = self.ui.annotation and self.ui.annotation.annotations
            or (self.ui.doc_settings and self.ui.doc_settings:readSetting("annotations"))
        if type(annotations) ~= "table" then error("annotations_unavailable") end
        local entries, reasons = Core.collect(annotations, G_reader_settings:readSetting(LIMIT), key)
        local store = Store.new(self.root, self.state_root, id, width, height)
        local job = {
            document = self.ui.document, book = book, store = store, key = key,
            entries = entries, index = 0, generation = self._generation,
            force = force, show_result = show_result, ready = 0,
            stats = { created = 0, cached = 0, layout = 0, errors = 0, filtered = total(reasons) },
        }
        self._job = job
        G_reader_settings:saveSetting(LAST_BOOK, { id = id, width = width, height = height })
        G_reader_settings:flush()
        self:_schedule(function() self:_step(job) end)
    end)
    if not ok then
        if self._job then self:_cancel_job()
        elseif book and book.cover then pcall(book.cover.free, book.cover) end
        logger.warn("留句: 无法读取当前书", tostring(err))
        if tostring(err):find("annotations_unavailable", 1, true) then
            if not unsupported_notified then
                unsupported_notified = true
                notify(_("当前 KOReader 版本无法读取高亮，请先更新 KOReader。"))
            end
        elseif show_result then notify(_("留句暂时无法生成图片，请检查剩余空间与 KOReader 版本。")) end
    end
end

function Liuju:_job_valid(job)
    return self._job == job and self._generation == job.generation
        and self:_current() == job.book.file and self.ui.document == job.document
        and self.policy:check()
end

function Liuju:_apply_target(job)
    if not self:_job_valid(job) then return end
    if job.ready > 0 then
        self.policy:apply{ dir = job.store.dir, count = #job.entries + 8 }
    else
        local image = job.book.file
        if job.cover_ready and Store.valid_png(job.store.fallback, job.store.width, job.store.height) then image = job.store.fallback end
        self.policy:apply{ dir = self.empty_dir, image = image }
    end
end

function Liuju:_step(job)
    if not self:_job_valid(job) then self:_cancel_job(); return end
    local ok, err = pcall(function()
        if job.index == 0 then
            local cached_cover = Store.valid_png(job.store.fallback, job.store.width, job.store.height)
                and job.store.index:readSetting("cover_key") == job.key
            job.cover_ready = cached_cover
            if job.force or not cached_cover then
                local written, why = job.store:write(self.renderer, job.book, nil)
                if written then
                    job.cover_ready = true
                    job.store.index:saveSetting("cover_key", job.key)
                else job.stats.errors = job.stats.errors + 1; logger.warn("留句: 封面生成失败", tostring(why)) end
            end
            job.store:reconcile(job.entries, job.force)
            for _, entry in ipairs(job.entries) do
                if job.store:has(entry.filename) then job.ready = job.ready + 1 end
            end
            job.index = 1
            self:_apply_target(job)
        else
            local entry = job.entries[job.index]
            if not entry then
                job.store:save_index()
                self:_apply_target(job)
                self._last_stats = job.stats
                self._last_store = job.store
                if job.show_result then
                    notify(string.format(_("留句已更新：%d 张，跳过 %d 条。"),
                        job.ready, job.stats.filtered + job.stats.layout)
                        .. (job.stats.errors > 0 and _("\n部分图片未能生成，请稍后重试。") or ""))
                end
                self:_cancel_job()
                return
            end
            local valid = job.store:has(entry.filename)
            if job.store.skipped[entry.filename] == "layout" and not job.force then
                job.stats.layout = job.stats.layout + 1
            elseif valid and not job.force then
                job.stats.cached = job.stats.cached + 1
            else
                local written, why = job.store:write(self.renderer, job.book, entry)
                if written then
                    job.store.skipped[entry.filename] = nil
                    job.stats.created = job.stats.created + 1
                    if not valid then job.ready = job.ready + 1 end
                elseif written == false and why == "layout" then
                    job.store.skipped[entry.filename] = "layout"
                    job.stats.layout = job.stats.layout + 1
                    if valid then
                        assert(os.remove(job.store.dir .. "/" .. entry.filename))
                        job.ready = job.ready - 1
                    end
                else
                    job.stats.errors = job.stats.errors + 1
                    logger.warn("留句: 小票生成失败", tostring(why))
                end
                self:_apply_target(job)
            end
            job.index = job.index + 1
        end
        self:_schedule(function() self:_step(job) end)
    end)
    if not ok then
        logger.warn("留句: 同步停止", tostring(err))
        if job.show_result then notify(_("留句未能完成更新，请检查剩余空间后重试。")) end
        self:_cancel_job()
    end
end

function Liuju:onReaderReady() self:_queue_sync(false, false) end
function Liuju:onAnnotationsModified() self:_queue_sync(false, false) end
function Liuju:onBookMetadataChanged() self:_queue_sync(true, false) end
function Liuju:onCloseDocument() self:_cancel_job() end
function Liuju:onCloseWidget() self:_shutdown() end
function Liuju:onSuspend()
    self._suspended = true
    self:_clear_timer()
end
function Liuju:onResume()
    self._suspended = false
    if self._job then
        local job = self._job
        self:_schedule(function() self:_step(job) end, 0.5)
    elseif self:_current() and self.policy:check() then
        -- Keep the valid current pool selected during a quick wake/sleep.
        -- Explicit annotation changes and book switches still safeguard first.
        self:_schedule(function() self:_start_sync() end, 0.5)
    end
end
function Liuju:stopPlugin()
    if active_instance then active_instance:_shutdown() end
    self.policy:restore(false)
end
function Liuju:deletePluginSettings()
    self:stopPlugin()
    for _, key in ipairs({ Policy.ENABLED, LIMIT, LAST_BOOK }) do G_reader_settings:delSetting(key) end
    G_reader_settings:flush()
end

function Liuju:_preview()
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if type(last) ~= "table" then notify(_("请先打开一本书生成小票。")); return end
    local ok, store = pcall(Store.new, self.root, self.state_root, last.id, last.width, last.height)
    if not ok then notify(_("暂时没有可预览的壁纸。")); return end
    local images = store:images()
    local path = #images > 0 and images[math.random(#images)] or store.fallback
    if not Store.valid_png(path, last.width, last.height) then notify(_("暂时没有可预览的壁纸。")); return end
    UIManager:show(require("ui/widget/imageviewer"):new{ file = path, fullscreen = true })
end

function Liuju:addToMainMenu(items)
    items.liuju = {
        text = _("留句"), sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启用留句屏保"),
                checked_func = function() return self.policy:enabled() end,
                callback = function()
                    if self.policy:enabled() then
                        self:_cancel_job()
                        self.policy:restore(true)
                        notify(_("留句屏保已关闭。"))
                    else
                        self.policy:enable()
                        self:_queue_sync(false, true)
                        if not self:_current() then notify(_("打开书籍后，将自动生成留句壁纸。")) end
                    end
                end,
            },
            {
                text_func = function() return string.format(_("字数上限：%d"), Core.limit(G_reader_settings:readSetting(LIMIT))) end,
                callback = function()
                    UIManager:show(require("ui/widget/spinwidget"):new{
                        title_text = _("生成小票的字数上限"),
                        info_text = _("中文、字母、数字、标点各算一字，空白不计。原文和笔记合并计算；实际排版放不下的内容也会跳过。"),
                        value = Core.limit(G_reader_settings:readSetting(LIMIT)),
                        value_min = 1, value_max = 200, value_step = 5, default_value = Core.DEFAULT_LIMIT,
                        callback = function(spin)
                            G_reader_settings:saveSetting(LIMIT, Core.limit(spin.value))
                            G_reader_settings:flush()
                            self:_queue_sync(false, true)
                        end,
                    })
                end,
            },
            {
                text = _("更新当前书的小票"),
                enabled_func = function() return self:_current() and self.policy:enabled() end,
                callback = function() self:_queue_sync(true, true) end,
            },
            { text = _("预览一张"), callback = function() self:_preview() end },
        },
    }
end
return Liuju
