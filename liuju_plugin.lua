-- 留句: current-book annotations -> cached receipt PNGs -> KOReader sleep screen.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Screensaver = require("ui/screensaver")
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
local Metadata = load_module("metadata")
local Liuju = WidgetContainer:extend{ name = "liuju", is_doc_only = false }
local active_instance
local Update
local screensaver_hook_installed = false
local unsupported_notified = false
local LIMIT, LAST_BOOK = "liuju_character_limit", "liuju_last_book"
local PENDING_DIGESTS = "liuju_pending_book_digests"
local STYLE = "liuju_wallpaper_style"
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
local function book_identity(last)
    return Core.pack({ last.source, last.full_digest })
end
local function selected_style()
    return Layout.style(G_reader_settings:readSetting(STYLE)).id
end

local function book_title(title, file)
    title = Core.clean(title)
    if title and title ~= "" then return title end
    local name = Core.clean(file:match("([^/]+)$") or "") or ""
    name = name:gsub("%.[^%.]+$", "")
    return name ~= "" and name or _("未命名书籍")
end

local function render_key(last, style)
    return Core.LAYOUT_VERSION .. "/" .. style .. "/" .. Core.pack({
        last.width, last.height, book_title(last.title, last.file), book_identity(last),
        tostring(G_reader_settings:readSetting("use_xtext")), Draw.signature and Draw:signature() or "",
    })
end

local function receipt_key(index, last)
    local expected = render_key(last, selected_style())
    if index:readSetting("receipt_key") == expected then return expected end
end

local function valid_digest(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

-- The 1.0/1.1 cache keys already encode the book digest. Recover it on
-- upgrade so a different file cannot silently inherit an existing sidecar.
local function indexed_book_digest(index)
    local digest = index:readSetting("book_digest")
    if valid_digest(digest) then return digest end
    for _, field in ipairs({ "receipt_key", "cover_key" }) do
        local key = index:readSetting(field)
        local parts, identity
        local prefix = "yiyan-receipts-1/"
        if type(key) == "string" and key:sub(1, #prefix) == prefix then
            parts = Core.unpack_fields(key:match("^[^/]+/[^/]+/(.*)$"), 4)
            identity = parts and parts[4]
        else
            parts = Core.unpack_fields(key, 5)
            if parts and parts[1] == "album-player-4" then identity = parts[5] end
        end
        parts = Core.unpack_fields(identity, 2)
        if parts and valid_digest(parts[2]) then return parts[2] end
    end
end

local function pending_digest(id)
    local pending = G_reader_settings:readSetting(PENDING_DIGESTS)
    local digest = type(pending) == "table" and pending[id]
    if valid_digest(digest) then return digest end
end

local function save_pending_digest(id, digest)
    local pending = G_reader_settings:readSetting(PENDING_DIGESTS)
    if type(pending) ~= "table" then pending = {} end
    if pending[id] == digest then return end
    pending[id] = digest
    G_reader_settings:saveSetting(PENDING_DIGESTS, next(pending) and pending or nil)
    G_reader_settings:flush()
end

local function book_replaced(last, index)
    local known = indexed_book_digest(index) or pending_digest(last.id) or last.previous_digest
    return valid_digest(known) and known ~= last.full_digest
end

local function replacement_notice()
    notify(_("书籍文件已更换。请打开该书，通过「更新当前书的小票」确认是否沿用已有批注。"))
end

local function total(reasons)
    local n = 0
    for _, value in pairs(reasons) do n = n + value end
    return n
end

local function saved_receipts(settings, index, limit, last)
    if book_replaced(last, index) then return {}, false, 0 end
    local key = receipt_key(index, last)
    local counts = index:readSetting("counts")
    if type(counts) ~= "table" then counts = {} end
    local skipped = index:readSetting("skipped")
    local allowed, expected, needs_sync = {}, {}, false
    local entries = Core.collect(settings.annotations, limit, key or render_key(last, selected_style()))
    for _, entry in ipairs(entries) do
        local name = entry.filename
        expected[name] = true
        if key and counts[name] == entry.count then
            if type(skipped) ~= "table" or skipped[name] ~= "layout" then allowed[name] = true end
        else
            needs_sync = true
        end
    end
    -- An externally deleted note leaves an index entry with no saved annotation.
    for name in pairs(counts) do
        if not expected[name] then needs_sync = true; break end
    end
    return allowed, needs_sync, #entries
end

local function alternate_receipt(dir, allowed, width, height)
    local names, damaged = {}, false
    for name in pairs(allowed) do names[#names + 1] = name end
    while #names > 0 do
        local i = math.random(#names)
        local path = dir .. "/" .. names[i]
        names[i] = names[#names]
        names[#names] = nil
        local image = Store.decode_candidate(dir, path, width, height)
        if image then return path, image, damaged end
        if Store.discard_candidate(dir, path) then damaged = true end
    end
    return nil, nil, damaged
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
        local ok, dir, last, fallback, saved = pcall(plugin._before_sleep, plugin)
        if not ok then
            logger.warn("留句: 无法检查屏保状态", tostring(dir))
            fallback = plugin.policy:owns()
        end
        if fallback then return setup_default(setup, self, event, ...) end
        local result = setup(self, event, ...)
        if ok and dir then
            local checked, err = pcall(plugin._validate_selection, plugin, self, dir, last, saved)
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
    if self.screensaver_supported and self.policy:enabled() then self.policy:check()
    else self.policy:restore(false) end
    -- ReaderReady handles normal opening.
    if self.ui.document and self.ui.doc_props then
        self:onReaderReady()
    elseif not self.ui.document and self.screensaver_supported and self.policy:enabled() then
        local ok, err = pcall(self._init_library_screen, self)
        if not ok then logger.warn("留句: 无法在书库初始化屏保", tostring(err)) end
    end
    self.ui.menu:registerToMainMenu(self)
end

function Liuju:_clear_timer()
    if self._timer then UIManager:unschedule(self._timer); self._timer = nil end
end

function Liuju:_cancel_job()
    self:_clear_timer()
    self._generation = self._generation + 1
    self._job = nil
    self._pending = nil
end

function Liuju:_shutdown()
    self:_cancel_job()
    if self._updater then self._updater:cancel() end
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

function Liuju:_show_generic()
    util.makePath(self.empty_dir)
    return self.policy:apply{ dir = self.empty_dir, image = DEFAULT_IMAGE }
end

function Liuju:_recent_book()
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if source_matches(last) and not last.excluded then return last end
end

function Liuju:_init_library_screen()
    local lease = G_reader_settings:readSetting(Policy.LEASE)
    if not lease or self.policy:owns() then self:_restore_recent_screen(self.policy:owns()) end
end

function Liuju:_restore_recent_screen(already_owned, explicitly_enabled)
    local ok, applied = pcall(function()
        local last = G_reader_settings:readSetting(LAST_BOOK)
        if type(last) ~= "table" then return already_owned and self:_show_generic() end
        if last.unavailable or last.excluded then return self:_show_generic() end
        if not source_matches(last, already_owned) then
            return explicitly_enabled and self:_show_generic()
        end
        local saved = Metadata.read(last.file)
        if not saved then return explicitly_enabled and self:_show_generic() end
        if saved.exclude_screensaver == true then return self:_show_generic() end
        local store = Store.new(self.root, self.state_root, last.id, last.width, last.height)
        if book_replaced(last, store.index) then return self:_show_generic() end

        local limit = Core.limit(G_reader_settings:readSetting(LIMIT))
        local allowed, needs_sync, count = saved_receipts(saved, store.index, limit, last)
        local ready = {}
        for name in pairs(allowed) do
            if store:has_cached(name) then
                ready[#ready + 1] = name
            else
                needs_sync = true
            end
        end
        local current_pool = already_owned
            and G_reader_settings:readSetting("screensaver_type") == "random_image"
            and G_reader_settings:readSetting("screensaver_dir") == store.dir
        if current_pool and not needs_sync and #ready > 0 then return true end
        if already_owned and (#ready > 0 or needs_sync) and not source_matches(last) then return false end

        local usable = current_pool and #ready > 0
        if not usable then
            for _, name in ipairs(ready) do
                local path = store.dir .. "/" .. name
                if Store.valid_png(path, store.width, store.height) then
                    usable = self.policy:apply{ dir = store.dir, count = count + 8 }
                    break
                end
                Store.discard_candidate(store.dir, path)
                needs_sync = true
            end
        end
        if needs_sync then return self:_queue_sync(false, false, last, usable) end
        return usable or self:_show_generic()
    end)
    if not ok then
        logger.warn("留句: 无法在书库恢复屏保", tostring(applied))
        return false
    end
    return applied
end

function Liuju:_reader_book()
    local file = self:_current()
    if not file then return end
    local opened = self._opened
    if self:_is_pdf() or not opened or not valid_digest(opened.full_digest) then
        return { file = file, unavailable = true }
    end
    local width, height = screen_size()
    local doc = self.ui.document
    local props = self.ui.doc_props or (doc.getProps and doc:getProps()) or {}
    return { id = opened.id, file = file, width = width, height = height,
        source = opened.source, full_digest = opened.full_digest, excluded = self:_excluded(),
        title = book_title(props.display_title or props.title, file) }
end

function Liuju:_record_recent()
    local last = self:_reader_book()
    if not last then return end
    local previous = G_reader_settings:readSetting(LAST_BOOK)
    if type(previous) == "table" then
        if last.id and last.id == previous.id then
            last.previous_digest = previous.previous_digest
            if not last.previous_digest and valid_digest(previous.full_digest)
                    and last.full_digest ~= previous.full_digest then
                last.previous_digest = previous.full_digest
            end
        end
        local unchanged = true
        for _, key in ipairs({ "file", "id", "source", "full_digest", "excluded",
                "title", "width", "height", "unavailable", "previous_digest" }) do
            if previous[key] ~= last[key] then unchanged = false; break end
        end
        if unchanged then last = previous end
    end
    if last ~= previous then
        G_reader_settings:saveSetting(LAST_BOOK, last)
        G_reader_settings:flush()
    end
    -- Remember the file identity even if wallpaper generation is disabled
    -- or the book has no qualifying annotations.
    if last.id and not self._opened.provenance_saved then
        local index = Store.open_index(self.state_root, last.id)
        local pending = pending_digest(last.id)
        local digest = indexed_book_digest(index) or pending or last.previous_digest or last.full_digest
        if index:readSetting("book_digest") ~= digest or pending then
            local saved, err = pcall(Store.save_book_digest, self.state_root, index, digest)
            if not saved then
                save_pending_digest(last.id, digest)
                error(err, 0)
            end
            save_pending_digest(last.id, nil)
        end
        self._opened.provenance_saved = true
    end
    return last
end

function Liuju:_safeguard()
    if not self:_current() or not self.policy:check() then return end
    local last = self:_record_recent()
    return self:_show_generic() and self:_opened_matches(true) and not last.excluded
end

function Liuju:_queue_sync(force, show_result, recent, keep_pool)
    if self._stopped or active_instance ~= self or not self.screensaver_supported
            or not self.policy:check() then return end
    local current = self:_current()
    if current then recent = nil end
    if not current and not recent then return end
    local previous = self._pending or self._job or {}
    self:_cancel_job()
    self._retry_sync = false
    if current and show_result and not self:_is_pdf() and not self:_opened_matches() then
        notify(_("无法核对当前书籍，请重新打开后再试。"))
        return true
    end
    local ok, ready, reason = pcall(function()
        if current and not self:_safeguard() then return false end
        local last = recent or G_reader_settings:readSetting(LAST_BOOK)
        if recent then
            local saved = Metadata.read(recent.file)
            if not saved then return false, "metadata_unavailable" end
            if saved.exclude_screensaver == true then return false, "excluded" end
        end
        local index = Store.open_index(self.state_root, last.id)
        if book_replaced(last, index) then
            if recent then self:_show_generic() end
            return false, "replaced"
        end
        local pool = self.root .. "/" .. last.id .. "/pool"
        return current or (keep_pool and receipt_key(index, last) and self.policy:owns()
            and G_reader_settings:readSetting("screensaver_type") == "random_image"
            and G_reader_settings:readSetting("screensaver_dir") == pool) or self:_show_generic()
    end)
    if not ok then
        logger.warn("留句: 暂存屏保失败", tostring(ready))
        self._retry_sync = recent or self:_opened_matches(true)
        if self.policy:owns() then pcall(self.policy.apply, self.policy, { dir = self.empty_dir, image = DEFAULT_IMAGE }) end
        if show_result then notify(_("留句暂时无法更新，请稍后重试。")) end
    elseif show_result and not ready and not self:_is_pdf() then
        if reason == "replaced" then replacement_notice()
        elseif reason == "excluded" or self:_excluded() then notify(_("这本书已设为不显示在休眠屏幕。"))
        elseif reason == "metadata_unavailable" then notify(_("暂时无法读取这本书的标注，请稍后重试。"))
        else notify(_("无法核对当前书籍，请重新打开后再试。")) end
    end
    if ok and ready then
        self._pending = { force = force or previous.force, show_result = show_result or previous.show_result,
            recent = recent }
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
            or (current and (last.file ~= current or book_identity(last) ~= book_identity(self._opened))) then
        return nil, nil, true
    end
    if current and not self._pending and self:_annotations_changed() then self:_queue_sync(false, false) end
    if G_reader_settings:readSetting("screensaver_type") == "document_cover"
            and G_reader_settings:readSetting("screensaver_document_cover") == DEFAULT_IMAGE then
        if not current and not self._pending and not self._job and source_matches(last, true) then
            local saved = Metadata.read(last.file)
            if saved and saved.exclude_screensaver ~= true then
                local index = Store.open_index(self.state_root, last.id)
                local allowed, needs_sync = saved_receipts(saved, index, Core.limit(G_reader_settings:readSetting(LIMIT)), last)
                if (needs_sync or next(allowed)) and source_matches(last) then self:_queue_sync(false, false, last) end
            end
        end
        return
    end
    if not source_matches(last) then return nil, nil, true end
    local saved
    if not current then
        saved = Metadata.read(last.file)
        if not saved or saved.exclude_screensaver == true then return nil, nil, true end
    end
    local kind = G_reader_settings:readSetting("screensaver_type")
    if kind == "random_image" then
        local dir = G_reader_settings:readSetting("screensaver_dir")
        local book_dir = self.root .. "/" .. last.id
        if dir == book_dir .. "/pool" or dir == book_dir then return dir, last, nil, saved end
    end
    return nil, nil, true
end

function Liuju:_validate_selection(screensaver, dir, last, saved)
    local path = screensaver.image_file
    local index = Store.open_index(self.state_root, last.id)
    local limit = Core.limit(G_reader_settings:readSetting(LIMIT))
    local key = receipt_key(index, last)
    local indexed = key and not book_replaced(last, index)
        and Store.indexed_candidate(index, dir, path, limit)
    local allowed, needs_sync
    if saved then allowed, needs_sync = saved_receipts(saved, index, limit, last) end
    local image, damaged
    if indexed and (not allowed or allowed[path:sub(#dir + 2)]) then
        image = Store.decode_candidate(dir, path, last.width, last.height)
        if not image then damaged = Store.discard_candidate(dir, path) end
    end
    if not image and allowed then
        local replacement, alternate, alternate_damaged = alternate_receipt(dir, allowed, last.width, last.height)
        damaged = damaged or alternate_damaged
        image = alternate
        if image then screensaver.image_file = replacement end
    end
    if image then
        -- Screensaver:show transfers the buffer to its disposable image widget.
        screensaver.image = image
    else
        show_default(screensaver)
    end
    if saved then
        if damaged or ((needs_sync or (not image and next(allowed))) and not self._pending and not self._job) then
            self:_queue_sync(false, false, last, true)
        end
    elseif not image then
        self:_queue_sync(false, false)
    end
end

function Liuju:_prepare_job(pending)
    local doc, last, annotations
    if pending.recent then
        last = pending.recent
        if self.ui.document or G_reader_settings:readSetting(LAST_BOOK) ~= last
                or not source_matches(last, true) then error("book_source_changed") end
        local saved = Metadata.read(last.file)
        if not saved then error("metadata_unavailable") end
        if saved.exclude_screensaver == true then error("book_excluded") end
        annotations = saved.annotations or {}
    else
        if not self:_opened_matches(true) then error("book_source_changed") end
        doc = self.ui.document
        last = self:_record_recent()
        annotations = self:_annotations()
    end
    if type(annotations) ~= "table" then error("annotations_unavailable") end
    local store = Store.new(self.root, self.state_root, last.id, last.width, last.height)
    if book_replaced(last, store.index) then error("book_replaced") end
    local style, limit = selected_style(), Core.limit(G_reader_settings:readSetting(LIMIT))
    local key = render_key(last, style)
    local entries, reasons = Core.collect(annotations, limit, key)
    return {
        document = doc, recent = pending.recent, book = { file = last.file,
            title = book_title(last.title, last.file), style = style },
        key = key, source = book_identity(last), digest = last.full_digest, limit = limit, store = store,
        entries = entries, index = 0, generation = self._generation,
        force = pending.force, show_result = pending.show_result, ready = 0,
        stats = { created = 0, cached = 0, layout = 0, errors = 0, filtered = total(reasons) },
    }, annotations
end

function Liuju:_start_sync()
    local pending = self._pending
    if not pending then return end
    if (not pending.recent and not self:_current()) or not self.policy:check() then
        self:_cancel_job()
        return
    end
    self._pending = nil
    local ok, err = pcall(function()
        local job, annotations = self:_prepare_job(pending)
        if job.document then self._annotation_snapshot = snapshot_annotations(annotations) end
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
        elseif tostring(err):find("book_replaced", 1, true) then
            if pending.show_result then replacement_notice() end
        else
            self._retry_sync = pending.recent or true
            if pending.show_result then notify(_("留句暂时无法生成图片，请检查剩余空间与 KOReader 版本。")) end
        end
    end
end

function Liuju:_job_valid(job)
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if self._job ~= job or self._generation ~= job.generation
            or selected_style() ~= job.book.style or Core.limit(G_reader_settings:readSetting(LIMIT)) ~= job.limit
            or type(last) ~= "table" or last.file ~= job.book.file or book_identity(last) ~= job.source
            or not self.policy:check() then return false end
    if job.recent then
        return not self.ui.document and last == job.recent and source_matches(last, true)
    end
    return self:_current() == job.book.file and self.ui.document == job.document
        and not self:_is_pdf() and not self:_excluded() and self:_opened_matches(true)
end

function Liuju:_apply_target(job)
    if not self:_job_valid(job) then return end
    if job.ready > 0 then
        self.policy:apply{ dir = job.store.dir, count = #job.entries + 8 }
    else
        self:_show_generic()
    end
end

function Liuju:_step(job)
    if not self:_job_valid(job) then self:_cancel_job(); return end
    local ok, err = pcall(function()
        local delay
        if job.index == 0 then
            local available = job.store:reconcile(job.entries, job.force, job.key, job.digest)
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
            job.index = 1
            self:_apply_target(job)
        else
            local item = job.todo[job.index]
            if not item then
                job.store:save_index()
                self:_apply_target(job)
                self._last_stats = job.stats
                self._last_store = job.store
                self._retry_sync = job.stats.errors > 0 and (job.recent or true)
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
                local written, why = job.store:write(self.renderer, job.book, entry)
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
        self._retry_sync = job.recent or true
        self:_cancel_job()
    end
end

function Liuju:onReaderReady()
    if not self.screensaver_supported then return end
    local ok, err = pcall(function()
        self:_bind_document()
        self:_record_recent()
    end)
    if not ok then logger.warn("留句: 无法确认已打开书籍的文件身份", tostring(err)) end
    self:_queue_sync(false, false)
end
function Liuju:onAnnotationsModified() self:_queue_sync(false, false) end
function Liuju:onBookMetadataChanged()
    if self.screensaver_supported then
        local ok, err = pcall(self._record_recent, self)
        if not ok then logger.warn("留句: 无法保存最近阅读的书", tostring(err)) end
    end
    self:_queue_sync(true, false)
end
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
            local available = job.store:reconcile(job.entries, false, job.key, job.digest)
            if next(available) then self.policy:apply{ dir = job.store.dir, count = #job.entries + 8 } end
        end)
        if not ok then logger.warn("留句: 关书时无法核对缓存", tostring(err)) end
    end
    if self.screensaver_supported and current then
        local ok, err = pcall(self._record_recent, self)
        if not ok then logger.warn("留句: 无法保存最近阅读的书", tostring(err)) end
    end
    self:_cancel_job()
end
function Liuju:onCloseWidget() self:_shutdown() end
function Liuju:onSuspend()
    self._suspended = true
    self:_clear_timer()
    if self._updater then self._updater:cancel() end
end
function Liuju:onResume()
    if self._stopped or active_instance ~= self then return end
    self._suspended = false
    if self._job then
        local job = self._job
        self:_schedule(function() self:_step(job) end, 0.5)
    elseif self._pending then
        self:_schedule(function() self:_start_sync() end, 0.5)
    elseif self._retry_sync then
        local recent = type(self._retry_sync) == "table" and self:_recent_book()
        self:_queue_sync(false, false, recent, true)
    end
end
function Liuju:stopPlugin()
    if active_instance then active_instance:_shutdown() end
    self.policy:restore(false)
end
function Liuju:deletePluginSettings()
    self:stopPlugin()
    for _, key in ipairs({ Policy.ENABLED, LIMIT, LAST_BOOK, STYLE, PENDING_DIGESTS }) do G_reader_settings:delSetting(key) end
    G_reader_settings:flush()
end

function Liuju:_restrict_last_pool(limit)
    local last = G_reader_settings:readSetting(LAST_BOOK)
    if not source_matches(last) or last.excluded then return end
    local owns_screen = self.policy:check() and self.policy:owns()
    if owns_screen then
        self:_show_generic()
    end
    local store = Store.new(self.root, self.state_root, last.id, last.width, last.height)
    local available, count = store:filter_limit(limit)
    if owns_screen and receipt_key(store.index, last) and not book_replaced(last, store.index) and next(available) then
        self.policy:apply{ dir = store.dir, count = count + 8 }
    end
end

function Liuju:_set_limit(value)
    local limit, previous = Core.limit(value), Core.limit(G_reader_settings:readSetting(LIMIT))
    if limit == previous then return end
    G_reader_settings:saveSetting(LIMIT, limit)
    local running = self._pending or self._job
    local recent = running and running.recent
    if limit > previous and not recent and not self:_current()
            and self.screensaver_supported and self.policy:check() then
        local ok, last = pcall(self._recent_book, self)
        if ok then recent = last
        else logger.warn("留句: 无法核对最近一本书", tostring(last)) end
    end
    if not self:_queue_sync(false, true, recent, limit > previous) and limit < previous then
        local ok, err = pcall(self._restrict_last_pool, self, limit)
        if not ok then logger.warn("留句: 无法按新字数上限筛选缓存", tostring(err)) end
    end
    G_reader_settings:flush()
end

function Liuju:_set_style(style)
    style = Layout.style(style).id
    if style == selected_style() then return end
    G_reader_settings:saveSetting(STYLE, style)
    G_reader_settings:flush()
    if self:_current() then
        if self:_queue_sync(false, true) then return end
    elseif self.screensaver_supported and self.policy:check() then
        local ok, last = pcall(self._recent_book, self)
        if ok and last and self:_queue_sync(false, true, last) then return end
        if not ok then logger.warn("留句: 无法核对最近一本书", tostring(last)) end
    end
    notify(_("壁纸样式已保存，下次生成时生效。"))
end

function Liuju:_preview()
    if not self.screensaver_supported then notify(_("这台设备的休眠屏幕由 Kindle 系统管理。")); return end
    local current = self:_current()
    local ok, store, allowed, has_entries
    if current then
        if self:_is_pdf() then notify(_("留句不支持 PDF。")); return end
        if not self:_opened_matches() then notify(_("无法核对当前书籍，请重新打开后再试。")); return end
        if self:_excluded() then notify(_("这本书已设为不显示在休眠屏幕。")); return end
        if not self._pending and self:_annotations_changed() then self:_queue_sync(false, false) end
        local job
        ok, job = pcall(self._prepare_job, self, {})
        if not ok and tostring(job):find("book_replaced", 1, true) then
            replacement_notice()
            return
        end
        if ok then
            store, allowed = job.store, {}
            has_entries = #job.entries > 0
            for _, entry in ipairs(job.entries) do allowed[entry.filename] = true end
        end
    else
        local last = G_reader_settings:readSetting(LAST_BOOK)
        if not source_matches(last) or last.excluded then
            notify(_("请先打开一本书生成小票。"))
            return
        end
        ok, store, allowed, has_entries = pcall(function()
            local saved = Metadata.read(last.file)
            if not saved then error("metadata_unavailable") end
            if saved.exclude_screensaver == true then return end
            local recent = Store.new(self.root, self.state_root, last.id, last.width, last.height)
            local limit = Core.limit(G_reader_settings:readSetting(LIMIT))
            if book_replaced(last, recent.index) then error("book_replaced") end
            local available, _, count = saved_receipts(saved, recent.index, limit, last)
            return recent, available, count > 0
        end)
        if not ok and tostring(store):find("book_replaced", 1, true) then
            replacement_notice()
            return
        end
        if ok and not store then
            notify(_("这本书已设为不显示在休眠屏幕。"))
            return
        end
    end
    local images
    if ok then
        ok, images = pcall(store.images, store, Core.limit(G_reader_settings:readSetting(LIMIT)), allowed)
        if not ok then logger.warn("留句: 无法读取小票目录", tostring(images)) end
    end
    if not ok then
        notify(current and _("暂时无法确认当前书的小票状态。") or _("暂时没有可预览的壁纸。"))
        return
    end
    local path
    while #images > 0 and not path do
        local candidate = table.remove(images, math.random(#images))
        if Store.valid_png(candidate, store.width, store.height) then path = candidate end
    end
    if not path then
        if has_entries and (self._pending or self._job) then
            notify(_("当前书的小票生成中"))
            return
        end
        notify(_("当前书暂无小票"))
        return
    end
    local title = current and _("当前书的小票") or nil
    UIManager:show(require("ui/widget/imageviewer"):new{ file = path, fullscreen = true, title_text = title })
end

function Liuju:_update_current_book()
    local ok, replaced = pcall(function()
        if not self:_opened_matches(true) then return false end
        local last = self:_record_recent()
        return book_replaced(last, Store.open_index(self.state_root, last.id))
    end)
    if not ok or not replaced then self:_queue_sync(true, true); return end
    local opened = self._opened
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = _("同一路径的书籍文件已更换。请先检查本书的标注。是否使用当前书中保留的批注生成小票？"),
        ok_text = _("沿用批注"),
        ok_callback = function()
            local accepted, err = pcall(function()
                if self._opened ~= opened or not self:_opened_matches() or self:_excluded()
                        or not self.policy:check() then error("book_source_changed") end
                local last = self:_record_recent()
                local index = Store.open_index(self.state_root, last.id)
                Store.save_book_digest(self.state_root, index, last.full_digest)
                save_pending_digest(last.id, nil)
                if last.previous_digest then
                    last.previous_digest = nil
                    G_reader_settings:flush()
                end
                self:_queue_sync(true, true)
            end)
            if not accepted then
                logger.warn("留句: 无法确认替换后的书籍", tostring(err))
                notify(_("无法确认当前书籍，请重新打开后再试。"))
            end
        end,
    })
end

function Liuju:_check_for_updates()
    if not self._updater then
        if not Update then
            local ok, result = pcall(load_module, "update")
            if not ok then
                logger.warn("留句: 无法加载在线更新", tostring(result))
                notify(_("在线更新暂不可用，请通过 USB 手动更新。"))
                return
            end
            Update = result
        end
        self._updater = Update.new(Core, self.path or base, self.version, function()
            return active_instance == self and not self._stopped and not self._suspended
        end)
    end
    self._updater:check()
end

function Liuju:addToMainMenu(items)
    local labels = {
        classic = _("原版半露 CD（默认）"),
        calendar = _("白底日期卡"),
        dark = _("纯色深灰卡"),
    }
    local styles = {}
    for _, style in ipairs(Layout.STYLES) do
        local id = style.id
        styles[#styles + 1] = {
            text = labels[id],
            checked_func = function() return selected_style() == id end,
            callback = function() self:_set_style(id) end,
        }
    end
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
                        if self:_current() then
                            self:_queue_sync(false, true)
                        elseif self:_restore_recent_screen(false, true) then
                            notify(_("留句屏保已启用。"))
                        else
                            notify(_("打开书籍后，将自动生成留句壁纸。"))
                        end
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
                callback = function() self:_update_current_book() end,
            },
            { text = _("预览一张"), callback = function() self:_preview() end },
            { text = _("壁纸样式"), sub_item_table = styles },
            {
                text = _("在线更新"),
                sub_item_table = {
                    { text_func = function() return string.format(_("当前版本：%s"), self.version or _("未知")) end,
                        enabled = false },
                    { text = _("检查更新"), callback = function() self:_check_for_updates() end },
                },
            },
        },
    }
end
return Liuju
