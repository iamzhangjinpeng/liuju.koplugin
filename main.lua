-- 留句: current-book annotations -> cached receipt PNGs -> KOReader sleep screen.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Screensaver = require("ui/screensaver")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
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
local screensaver_hook_installed = false
local unsupported_notified = false
local LIMIT, LAST_BOOK = "liuju_character_limit", "liuju_last_book"
local DEFAULT_IMAGE = "resources/koreader.png"

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end
local function fingerprint(path)
    local attrs = path and lfs.attributes(path)
    return attrs and attrs.mode == "file" and Core.pack({
        attrs.size, attrs.modification, attrs.change or "", attrs.ino or "",
    }) or ""
end
local function is_pdf(file)
    return type(file) == "string" and file:lower():match("%.pdf$") ~= nil
end
local function source_matches(last, stat_only)
    return type(last) == "table" and type(last.file) == "string"
        and not is_pdf(last.file)
        and type(last.id) == "string" and last.id == Core.book_id(last.file)
        and type(last.source) == "string" and last.source ~= "" and fingerprint(last.file) == last.source
        and type(last.full_digest) == "string" and #last.full_digest == 64
        and (stat_only or (Core.file_hash(last.file) == last.full_digest and fingerprint(last.file) == last.source))
end
local function cover_source(last)
    return Core.pack({ last.source, last.full_digest })
end
local function total(reasons)
    local n = 0
    for _, value in pairs(reasons) do n = n + value end
    return n
end

local function screen_size()
    local screen = Device.screen
    local width, height = screen:getWidth(), screen:getHeight()
    return math.min(width, height), math.max(width, height)
end

local function show_default(screensaver)
    if screensaver.image then pcall(screensaver.image.free, screensaver.image) end
    screensaver.image = nil
    screensaver.image_file = DEFAULT_IMAGE
    screensaver.screensaver_type = "cover"
end

local function setup_default(setup, screensaver, event, ...)
    local kind = G_reader_settings:readSetting("screensaver_type")
    local image = G_reader_settings:readSetting("screensaver_document_cover")
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", DEFAULT_IMAGE)
    local ok, result = pcall(setup, screensaver, event, ...)
    G_reader_settings:saveSetting("screensaver_type", kind)
    G_reader_settings:saveSetting("screensaver_document_cover", image)
    if not ok then error(result, 0) end
    show_default(screensaver)
    return result
end

-- Kindle selects the wallpaper before dispatching Suspend. Check for changes
-- in the ordinary sleep path before KOReader reads its screensaver settings.
local function install_screensaver_hook()
    if screensaver_hook_installed then return end
    local setup = Screensaver.setup
    function Screensaver:setup(event, ...)
        local plugin = not event and active_instance
        if not plugin then return setup(self, event, ...) end
        local ok, dir, last, fallback = pcall(plugin._before_sleep, plugin)
        if not ok then
            logger.warn("留句: 无法检查屏保状态", tostring(dir))
            fallback = plugin.policy:owns()
        end
        if fallback then return setup_default(setup, self, event, ...) end
        local result = setup(self, event, ...)
        if ok and last and (self.screensaver_type == "random_image" or self.screensaver_type == "cover") then
            local checked, err = pcall(plugin._validate_selection, plugin, self, dir, last)
            if not checked then
                logger.warn("留句: 无法检查屏保图片", tostring(err))
                show_default(self)
            end
        end
        return result
    end
    screensaver_hook_installed = true
end

function Liuju:init()
    if active_instance then active_instance:_shutdown() end
    active_instance = self
    install_screensaver_hook()
    self._stopped, self._suspended = false, false
    self._generation = 0
    self.policy = Policy.new(G_reader_settings)
    self.screensaver_supported = not Device.supportsScreensaver or Device:supportsScreensaver()
    self.renderer = Renderer.new(Core, Layout, Draw)
    self.root = DataStorage:getDataDir() .. "/screenshots/liuju"
    self.state_root = DataStorage:getSettingsDir() .. "/liuju"
    self.empty_dir = self.root .. "/empty"
    self.ui.menu:registerToMainMenu(self)
    if self.screensaver_supported and self.policy:enabled() then self.policy:check()
    else self.policy:restore(false) end
    -- ReaderReady handles normal opening. This path handles re-enabling a
    -- plugin while a reader is already initialized.
    if self.ui.document and self.ui.doc_props then self:onReaderReady() end
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
    self._pending = nil
end

function Liuju:_shutdown()
    self:_cancel_job()
    self._annotation_snapshot = nil
    self._opened = nil
    self._stopped = true
    if active_instance == self then active_instance = nil end
end

function Liuju:_current()
    return not self._stopped and active_instance == self and self.ui.document and self.ui.document.file
end

function Liuju:_is_pdf()
    local doc = self.ui.document
    return doc and (doc.is_pdf or is_pdf(doc.file))
end

function Liuju:_bind_document()
    local file, doc = self:_current(), self.ui.document
    if not file or self:_is_pdf() or (self._opened and self._opened.document == doc) then return end
    -- Keep this binding for the lifetime of the loaded document.
    local source = fingerprint(file)
    self._opened = { document = doc, file = file, id = Core.book_id(file), source = source }
    local digest = source ~= "" and Core.file_hash(file) or nil
    if source == fingerprint(file) then self._opened.full_digest = digest end
end

function Liuju:_opened_matches(stat_only)
    local opened = self._opened
    return opened and opened.document == self.ui.document and opened.file == self:_current()
        and source_matches(opened, stat_only)
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

function Liuju:_excluded()
    local settings = self.ui.doc_settings
    return settings ~= nil and settings:readSetting("exclude_screensaver") == true
end

function Liuju:_fallback(last)
    if last.excluded or not source_matches(last, true) then return DEFAULT_IMAGE end
    local cover = self.state_root .. "/" .. last.id .. "-cover.png"
    local index = Store.open_index(self.state_root, last.id)
    if index:readSetting("cover_source") == cover_source(last) and Store.valid_png(cover, last.width, last.height) then
        return cover
    end
    return last.file
end

function Liuju:_safeguard()
    local file = self:_current()
    if not file or not self.policy:check() then return end
    util.makePath(self.empty_dir)
    local pdf = self:_is_pdf()
    if pdf or not self:_opened_matches(true) then
        local clear_recent = pdf and G_reader_settings:readSetting(LAST_BOOK)
        if clear_recent then G_reader_settings:delSetting(LAST_BOOK) end
        self.policy:apply{ dir = self.empty_dir, image = DEFAULT_IMAGE }
        if clear_recent then G_reader_settings:flush() end
        return false
    end
    -- Explicit document_cover does not rely on readhistory.lastfile, which can
    -- still refer to another book when history freezing is enabled.
    local opened = self._opened
    local id, source, digest = opened.id, opened.source, opened.full_digest
    local width, height = screen_size()
    local excluded = self:_excluded()
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if type(last) ~= "table" or last.id ~= id or last.file ~= file or last.width ~= width or last.height ~= height
            or last.source ~= source or last.full_digest ~= digest or last.excluded ~= excluded then
        last = { id = id, file = file, width = width, height = height,
            source = source, full_digest = digest, excluded = excluded }
        G_reader_settings:saveSetting(LAST_BOOK, last)
    end
    return self.policy:apply{ dir = self.empty_dir, image = self:_fallback(last) } and not excluded
end

function Liuju:_queue_sync(force, show_result)
    if not self.screensaver_supported or not self:_current() or not self.policy:check() then return end
    local previous = self._pending or self._job or {}
    self:_cancel_job()
    self._retry_sync = false
    if show_result and not self:_is_pdf() and not self:_opened_matches() then
        notify(_("无法核对当前书籍，请重新打开后再试。"))
        return true
    end
    local ok, ready = pcall(self._safeguard, self)
    if not ok then
        logger.warn("留句: 暂存屏保失败", tostring(ready))
        self._retry_sync = self:_opened_matches(true)
        if self.policy:owns() then pcall(self.policy.apply, self.policy, { dir = self.empty_dir, image = DEFAULT_IMAGE }) end
        if show_result then notify(_("留句暂时无法更新，请稍后重试。")) end
    elseif show_result and not ready and not self:_is_pdf() then
        if self:_excluded() then notify(_("这本书已设为不显示在休眠屏幕。"))
        else notify(_("无法核对当前书籍，请重新打开后再试。")) end
    end
    if ok and ready then
        self._pending = { force = force or previous.force, show_result = show_result or previous.show_result }
        self:_schedule(function() self:_start_sync() end, 0.4)
    end
    return true
end

function Liuju:_annotations()
    return self.ui.annotation and self.ui.annotation.annotations
        or (self.ui.doc_settings and self.ui.doc_settings:readSetting("annotations"))
end

local function snapshot_annotations(annotations)
    local snapshot = {}
    for i, item in ipairs(annotations) do
        if type(item) == "table" then
            snapshot[i] = { item, item.text, item.note, item.datetime, item.note_format }
        else
            snapshot[i] = { item }
        end
    end
    return snapshot
end

function Liuju:_annotations_changed()
    local snapshot, annotations = self._annotation_snapshot, self:_annotations()
    if not snapshot or type(annotations) ~= "table" then return false end
    if #snapshot ~= #annotations then return true end
    for i, item in ipairs(annotations) do
        local old = snapshot[i]
        if not old or old[1] ~= item then return true end
        if type(item) == "table" and (old[2] ~= item.text or old[3] ~= item.note
                or old[4] ~= item.datetime or old[5] ~= item.note_format) then return true end
    end
    return false
end

function Liuju:_before_sleep()
    if not self.screensaver_supported or not self.policy:check() or not self.policy:owns() then return end
    local current = self:_current()
    if current and (self:_is_pdf() or not self:_opened_matches(true)) then
        return nil, nil, true
    end
    local last = G_reader_settings:readSetting(LAST_BOOK)
    local excluded = current and self:_excluded()
    if current and type(last) == "table" and last.file == current and last.excluded ~= excluded then
        self:_queue_sync(false, false)
        last = G_reader_settings:readSetting(LAST_BOOK)
    end
    if excluded or type(last) ~= "table" or last.excluded
            or (current and (last.file ~= current or cover_source(last) ~= cover_source(self._opened))) then
        return nil, nil, true
    end
    if G_reader_settings:readSetting("screensaver_type") == "document_cover"
            and G_reader_settings:readSetting("screensaver_document_cover") == DEFAULT_IMAGE then return end
    if not source_matches(last) then return nil, nil, true end
    if current and not self._pending and self:_annotations_changed() then self:_queue_sync(false, false) end
    local kind = G_reader_settings:readSetting("screensaver_type")
    if kind == "random_image" then
        local dir = G_reader_settings:readSetting("screensaver_dir")
        local book_dir = self.root .. "/" .. last.id
        if dir == book_dir .. "/pool" or dir == book_dir then return dir, last end
    elseif kind == "document_cover" then
        local path = G_reader_settings:readSetting("screensaver_document_cover")
        if path == self.state_root .. "/" .. last.id .. "-cover.png" then return nil, last end
        if path == last.file or path == DEFAULT_IMAGE then return end
    end
    return nil, nil, true
end

function Liuju:_validate_selection(screensaver, dir, last)
    local path = screensaver.image_file
    local cover = self.state_root .. "/" .. last.id .. "-cover.png"
    local index = Store.open_index(self.state_root, last.id)
    local indexed = dir and Store.indexed_candidate(index, dir, path, Core.limit(G_reader_settings:readSetting(LIMIT)))
    local cover_matches = index:readSetting("cover_source") == cover_source(last)
    local image
    if indexed then image = Store.decode_candidate(dir, path, last.width, last.height)
    elseif not dir and path == cover and cover_matches then image = Store.decode_png(cover, last.width, last.height) end
    if image then
        -- Screensaver:show transfers the buffer to its disposable image widget.
        screensaver.image = image
        return
    end
    local fallback = dir and cover_matches and Store.decode_png(cover, last.width, last.height)
    screensaver.image = fallback or nil
    screensaver.image_file = fallback and cover or DEFAULT_IMAGE
    if not self:_queue_sync(false, false) and not dir then
        self.policy:apply{ dir = self.empty_dir, image = last.file }
    end
    if indexed then Store.discard_candidate(dir, path) end
end

function Liuju:_prepare_job(pending)
    if not self:_opened_matches(true) then error("book_source_changed") end
    local doc = self.ui.document
    local annotations = self:_annotations()
    if type(annotations) ~= "table" then error("annotations_unavailable") end
    local props = self.ui.doc_props or (doc.getProps and doc:getProps()) or {}
    local title = Core.clean(props.display_title or props.title)
    if not title or title == "" then
        title = Core.clean(doc.file:match("([^/]+)$") or "") or ""
        title = title:gsub("%.[^%.]+$", "")
    end
    if title == "" then title = _("未命名书籍") end
    local width, height = screen_size()
    local cover_file = DocSettings.findCustomCoverFile and DocSettings:findCustomCoverFile(doc.file)
    local identity = cover_source(self._opened)
    local key = Core.pack({ Core.LAYOUT_VERSION, width, height, title,
        identity, cover_file, fingerprint(cover_file),
        G_reader_settings:readSetting("use_xtext"), Draw.signature and Draw:signature() or "" })
    local entries, reasons = Core.collect(annotations, G_reader_settings:readSetting(LIMIT), key)
    return {
        document = doc, book = { file = doc.file, title = title }, key = key, source = identity,
        store = Store.new(self.root, self.state_root, self._opened.id, width, height),
        entries = entries, index = 0, generation = self._generation,
        force = pending.force, show_result = pending.show_result, ready = 0,
        stats = { created = 0, cached = 0, layout = 0, errors = 0, filtered = total(reasons) },
    }, annotations
end

function Liuju:_write_image(job, entry)
    if not job.cover_loaded then
        job.cover_loaded = true
        local doc = job.document
        local ok, image = pcall(function()
            if self.ui.bookinfo and self.ui.bookinfo.getCoverImage then
                return self.ui.bookinfo:getCoverImage(doc)
            elseif doc.getCoverPageImage then return doc:getCoverPageImage() end
        end)
        if ok then job.book.cover = image
        else logger.warn("留句: 使用书名封面", tostring(image)) end
    end
    return job.store:write(self.renderer, job.book, entry)
end

function Liuju:_start_sync()
    if not self:_current() or not self.policy:check() then self:_cancel_job(); return end
    local pending = self._pending
    if not pending then return end
    self._pending = nil
    local ok, err = pcall(function()
        local job, annotations = self:_prepare_job(pending)
        self._annotation_snapshot = snapshot_annotations(annotations)
        self._job = job
        self:_schedule(function() self:_step(job) end)
    end)
    if not ok then
        self:_cancel_job()
        logger.warn("留句: 无法读取当前书", tostring(err))
        if tostring(err):find("annotations_unavailable", 1, true) then
            if not unsupported_notified then
                unsupported_notified = true
                notify(_("当前 KOReader 版本无法读取高亮，请先更新 KOReader。"))
            end
        else
            self._retry_sync = true
            if pending.show_result then notify(_("留句暂时无法生成图片，请检查剩余空间与 KOReader 版本。")) end
        end
    end
end

function Liuju:_job_valid(job)
    local last = G_reader_settings:readSetting(LAST_BOOK)
    return self._job == job and self._generation == job.generation
        and self:_current() == job.book.file and self.ui.document == job.document
        and not self:_is_pdf() and not self:_excluded() and self:_opened_matches(true)
        and type(last) == "table" and last.file == job.book.file
        and cover_source(last) == job.source
        and self.policy:check()
end

function Liuju:_apply_target(job)
    if not self:_job_valid(job) then return end
    if job.ready > 0 then
        self.policy:apply{ dir = job.store.dir, count = #job.entries + 8 }
    else
        local image = job.cover_ready and job.store.fallback or job.book.file
        self.policy:apply{ dir = self.empty_dir, image = image }
    end
end

function Liuju:_step(job)
    if not self:_job_valid(job) then self:_cancel_job(); return end
    local ok, err = pcall(function()
        local delay
        if job.index == 0 then
            local available = job.store:reconcile(job.entries, job.force)
            job.todo = {}
            for _, entry in ipairs(job.entries) do
                local valid = available[entry.filename]
                if valid then job.ready = job.ready + 1 end
                if not valid and job.store.skipped[entry.filename] == "layout" then
                    job.stats.layout = job.stats.layout + 1
                else
                    job.todo[#job.todo + 1] = { entry = entry, valid = valid }
                end
            end
            local cached_cover = Store.valid_png(job.store.fallback, job.store.width, job.store.height)
                and job.store.index:readSetting("cover_key") == job.key
            job.cover_ready = cached_cover
            local cover_written
            if job.force or not cached_cover then
                local written, why = self:_write_image(job, nil)
                if written then
                    job.cover_ready = true
                    cover_written = true
                    job.store.index:saveSetting("cover_key", job.key)
                else job.stats.errors = job.stats.errors + 1; logger.warn("留句: 封面生成失败", tostring(why)) end
            end
            if job.cover_ready and (cover_written or job.store.index:readSetting("cover_source") ~= job.source) then
                job.store.index:saveSetting("cover_source", job.source)
                job.store:save_index()
            end
            job.index = 1
            self:_apply_target(job)
        else
            local item = job.todo[job.index]
            if not item then
                job.store:save_index()
                self:_apply_target(job)
                self._last_stats = job.stats
                self._last_store = job.store
                self._retry_sync = job.stats.errors > 0
                if job.show_result then
                    notify(string.format(_("留句已更新：%d 张，跳过 %d 条。"),
                        job.ready, job.stats.filtered + job.stats.layout)
                        .. (job.stats.errors > 0 and _("\n部分图片未能生成，请稍后重试。") or ""))
                end
                self:_cancel_job()
                return
            end
            local entry = item.entry
            if item.valid then
                item.valid = job.store:verify_cached(entry.filename)
                if not item.valid then job.ready = job.ready - 1 end
            end
            if item.valid and not job.force then
                job.stats.cached = job.stats.cached + 1
                delay = 0.02
            elseif not job.force and job.store.skipped[entry.filename] == "layout" then
                job.stats.layout = job.stats.layout + 1
                self:_apply_target(job)
                delay = 0.02
            else
                local written, why = self:_write_image(job, entry)
                if written then
                    job.store.skipped[entry.filename] = nil
                    job.stats.created = job.stats.created + 1
                    if not item.valid then job.ready = job.ready + 1 end
                elseif written == false and why == "layout" then
                    job.store.skipped[entry.filename] = "layout"
                    job.stats.layout = job.stats.layout + 1
                    if item.valid then
                        Store.discard_candidate(job.store.dir, job.store.dir .. "/" .. entry.filename)
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
        self:_schedule(function() self:_step(job) end, delay)
    end)
    if not ok then
        logger.warn("留句: 同步停止", tostring(err))
        if job.show_result then notify(_("留句未能完成更新，请检查剩余空间后重试。")) end
        self._retry_sync = true
        self:_cancel_job()
    end
end

function Liuju:onReaderReady()
    if not self.screensaver_supported then return end
    local ok, err = pcall(self._bind_document, self)
    if not ok then logger.warn("留句: 无法确认已打开书籍的文件身份", tostring(err)) end
    self:_queue_sync(false, false)
end
function Liuju:onAnnotationsModified() self:_queue_sync(false, false) end
function Liuju:onBookMetadataChanged() self:_queue_sync(true, false) end
function Liuju:onCloseDocument()
    local current = self:_current()
    local last = G_reader_settings:readSetting(LAST_BOOK)
    local exclusion_changed = current and type(last) == "table" and last.file == current
        and last.excluded ~= self:_excluded()
    if self.screensaver_supported and current and (exclusion_changed or self._pending
            or (self._job and self._job.index == 0) or self:_annotations_changed())
            and self.policy:check() then
        local ok, err = pcall(function()
            if not self:_safeguard() then return end
            local job = self:_prepare_job({})
            local available = job.store:reconcile(job.entries, false)
            if next(available) then self.policy:apply{ dir = job.store.dir, count = #job.entries + 8 } end
        end)
        if not ok then logger.warn("留句: 关书时无法核对缓存", tostring(err)) end
    end
    self:_cancel_job()
end
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
    elseif self._pending then
        self:_schedule(function() self:_start_sync() end, 0.5)
    elseif self._retry_sync then
        self:_queue_sync(false, false)
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

function Liuju:_restrict_last_pool(limit)
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if not source_matches(last) or last.excluded then return end
    local owns_screen = self.policy:check() and self.policy:owns()
    if owns_screen then
        self.policy:apply{ dir = self.empty_dir, image = self:_fallback(last) }
    end
    local store = Store.new(self.root, self.state_root, last.id, last.width, last.height)
    local available, count = store:filter_limit(limit)
    if owns_screen and next(available) then
        self.policy:apply{ dir = store.dir, count = count + 8 }
    end
end

function Liuju:_set_limit(value)
    local limit, previous = Core.limit(value), Core.limit(G_reader_settings:readSetting(LIMIT))
    if limit == previous then return end
    G_reader_settings:saveSetting(LIMIT, limit)
    if not self:_queue_sync(false, true) and limit < previous then
        local ok, err = pcall(self._restrict_last_pool, self, limit)
        if not ok then logger.warn("留句: 无法按新字数上限筛选缓存", tostring(err)) end
    end
    G_reader_settings:flush()
end

function Liuju:_preview()
    if not self.screensaver_supported then notify(_("这台设备的休眠屏幕由 Kindle 系统管理。")); return end
    local ok, store, allowed, fallback
    if self:_current() then
        if self:_is_pdf() then notify(_("留句不支持 PDF。")); return end
        if not self:_opened_matches() then notify(_("无法核对当前书籍，请重新打开后再试。")); return end
        if not self._pending and self:_annotations_changed() then self:_queue_sync(false, false) end
        local job
        ok, job = pcall(self._prepare_job, self, {})
        if ok then
            store, allowed = job.store, {}
            for _, entry in ipairs(job.entries) do allowed[entry.filename] = true end
            if store.index:readSetting("cover_key") == job.key then fallback = store.fallback end
        end
    else
        local last = G_reader_settings:readSetting(LAST_BOOK)
        if not source_matches(last) or last.excluded then
            notify(_("请先打开一本书生成小票。"))
            return
        end
        ok, store = pcall(Store.new, self.root, self.state_root, last.id, last.width, last.height)
        if ok and store.index:readSetting("cover_source") == cover_source(last) then fallback = store.fallback end
    end
    if not ok then notify(_("暂时没有可预览的壁纸。")); return end
    local images = store:images(Core.limit(G_reader_settings:readSetting(LIMIT)), allowed)
    local path
    while #images > 0 and not path do
        local candidate = table.remove(images, math.random(#images))
        if Store.valid_png(candidate, store.width, store.height) then path = candidate end
    end
    if not path and fallback and Store.valid_png(fallback, store.width, store.height) then path = fallback end
    if not path then notify(_("暂时没有可预览的壁纸。")); return end
    UIManager:show(require("ui/widget/imageviewer"):new{ file = path, fullscreen = true })
end

function Liuju:addToMainMenu(items)
    items.liuju = {
        text = _("留句"), sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启用留句屏保"),
                checked_func = function() return self.screensaver_supported and self.policy:enabled() end,
                enabled_func = function() return self.screensaver_supported end,
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
                        callback = function(spin) self:_set_limit(spin.value) end,
                    })
                end,
            },
            {
                text = _("更新当前书的小票"),
                enabled_func = function()
                    return self.screensaver_supported and self:_current() and not self:_is_pdf() and self.policy:enabled()
                end,
                callback = function() self:_queue_sync(true, true) end,
            },
            { text = _("预览一张"), callback = function() self:_preview() end },
        },
    }
end
return Liuju
