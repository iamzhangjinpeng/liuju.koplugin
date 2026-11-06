local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local test_count = 0
local function test(name, fn)
    fn()
    test_count = test_count + 1
    print("PASS " .. name)
end
package.loaded["ffi/sha2"] = { sha256 = function(text)
    if text ~= nil then return py_hash(text) end
    local chunks = {}
    return function(chunk)
        if chunk == nil then return py_hash(table.concat(chunks)) end
        chunks[#chunks + 1] = chunk
    end
end }
local Core = dofile(TEST_ROOT .. "/liuju_core.lua")
local Policy = dofile(TEST_ROOT .. "/liuju_policy.lua")

local function settings(data)
    return {
        data = data or {},
        readSetting = function(self,k) return self.data[k] end,
        saveSetting = function(self,k,v) self.data[k] = v end,
        delSetting = function(self,k) self.data[k] = nil end,
        flush = function() end,
    }
end
local function annotation(text, note, date)
    return { text = text, note = note, drawer = "lighten", datetime = date or "2026-11-03 12:30:00",
        page = "/body/p[1]", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5" }
end

test("Unicode limit counts characters, punctuation and non-ASCII spaces", function()
    eq(Core.count("句，A1　 \n\t"), 4)
    eq(Core.count("🙂"), 1)
    eq(Core.count("\255"), nil)
    eq(Core.count("\192\128"), nil)
    eq(Core.count("\237\160\128"), nil)
    local entries, skipped = Core.collect({ annotation(string.rep("字",79)), annotation(string.rep("字",80)),
        annotation(string.rep("字",81)) }, 80, "layout")
    eq(#entries, 2)
    eq(skipped.too_long, 1)
end)
test("Quote and note share one limit and preserve original creation date", function()
    local row = annotation(string.rep("字",40), string.rep("记",40))
    row.datetime_updated = "2026-12-15 12:00:00"
    local entries = Core.collect({ row }, 80, "layout")
    eq(#entries,1)
    eq(entries[1].date, "2026.11.03")
    row.note = row.note .. "！"
    local rejected, why = Core.collect({row},80,"layout")
    eq(#rejected,0); eq(why.too_long,1)
    eq(Core.date("2026-02-31"),"")
    eq(Core.date("2024-02-29"),"2024.02.29")
end)
test("Page bookmarks are not confused with quotes; invalid/rich notes are skipped", function()
    local entries, why = Core.collect({
        {text = "auto page description"}, {note = "自己的笔记"},
        {note = "<b>hello</b>", note_format = "html"}, annotation("\255"),
    },80,"layout")
    eq(#entries,1); eq(entries[1].text,""); eq(entries[1].note,"自己的笔记")
    eq(why.formatted_note,1); eq(why.invalid_text,1); eq(why.empty,1)
end)
test("Cache identity survives table order and distinguishes absent dates/positions", function()
    local a, b = annotation("同一句"), annotation("同一句")
    a.datetime, b.datetime = nil, nil
    a.pos0, b.pos0 = {page=1,x=3,y=4}, {y=4,x=3,page=1}
    local entries = Core.collect({a,b},80,"same")
    eq(#entries,1)
    b.pos0.x = 5
    eq(#Core.collect({a,b},80,"same"),2)
    assert(Core.pack({"a",nil,"b"}) ~= Core.pack({"a","b"}))
    assert(Core.pack({false}) ~= Core.pack({""}))
    local unpacked = assert(Core.unpack_fields(Core.pack({ "a:b", "", "书" }), 3))
    eq(unpacked[1], "a:b"); eq(unpacked[2], ""); eq(unpacked[3], "书")
    eq(Core.unpack_fields("10:short", 1), nil)
end)
test("Screen settings restore unset values and preserve a later provider choice", function()
    local s = settings({screensaver_type="cover",screensaver_show_message=true})
    local p = Policy.new(s)
    assert(p:apply{dir="/one",count=500})
    eq(s.data.screensaver_cycle_images_alphabetically,false)
    eq(s.data.screensaver_max_files,500)
    p:restore(true)
    eq(s.data.screensaver_type,"cover"); eq(s.data.screensaver_dir,nil)
    eq(s.data.screensaver_show_message,true); eq(p:enabled(),false)
    p:enable(); p:apply{dir="/one"}
    s.data.screensaver_dir = "/calendar"
    eq(p:check(),false)
    p:restore(true)
    eq(s.data.screensaver_dir,"/calendar")
end)

test("A damaged screen settings backup restores its usable values and allows re-enabling", function()
    local s = settings({ screensaver_type = "cover", screensaver_show_message = true })
    local policy = Policy.new(s)
    assert(policy:apply{ dir = "/liuju" })
    local backup = s.data[Policy.LEASE].backup
    backup.screensaver_max_files = nil
    backup.screensaver_stretch_images = true
    eq(policy:owns(), false)
    eq(policy:check(), false)
    eq(s.data[Policy.LEASE], nil)
    eq(s.data.screensaver_type, "cover")
    eq(s.data.screensaver_show_message, true)
    policy:enable()
    eq(policy:apply{ dir = "/liuju" }, true)
    eq(policy:owns(), true)
end)

local GENERIC = "resources/koreader.png"
local fixture_id = 0
local real_dofile = dofile
local function fixture()
    fixture_id = fixture_id + 1
    local f = { root = SCRATCH .. "/case-" .. fixture_id, queue = {}, indices = {}, writes = 0,
        texts = {}, painted_texts = {}, rectangles = {}, circles = {}, backgrounds = {},
        live_widgets = 0, live_images = 0, cover_reads = 0, flushes = 0, messages = {}, warnings = {},
        saved_docs = {} }
    py_mkdir(f.root)
    local s = settings()
    G_reader_settings = s
    function s:flush() f.flushes = f.flushes + 1 end
    f.settings = s
    local uimanager = {}
    function uimanager:scheduleIn(delay, cb) f.queue[#f.queue+1] = cb end
    function uimanager:unschedule(cb)
        for i=#f.queue,1,-1 do if f.queue[i] == cb then table.remove(f.queue,i) end end
    end
    function uimanager:show(widget)
        if widget.file then
            f.preview = widget.file
            f.preview_title = widget.title_text
        end
        if widget.text then f.messages[#f.messages+1] = widget.text end
        if widget.ok_callback then f.confirmation = widget end
    end
    local function textwidget(text, width, size, options)
        options = options or {}
        f.live_widgets = f.live_widgets + 1
        local freed = false
        f.texts[#f.texts+1] = text
        local lines = 0
        for line in (text.."\n"):gmatch("(.-)\n") do
            lines = lines + 1
            local used = 0
            for _, char in ipairs(Core.characters(line) or {}) do
                local glyph = char.cp <= 0xFF and size / 2 or size
                if used > 0 and used + glyph > width then lines = lines + 1; used = 0 end
                used = used + glyph
            end
        end
        local line_height = math.floor(size*(1+(options.line_height or 0.48))+0.5)
        local visible = options.max_height and math.min(lines, math.max(1, math.floor(options.max_height/line_height))) or lines
        f.max_bitmap_height = math.max(f.max_bitmap_height or 0, line_height*visible)
        return {
            getSize = function() return {h=line_height*visible} end,
            getAllLineCount = function() return lines end,
            getVisLineCount = function() return visible end,
            paintTo = function(_,canvas,x,y)
                f.painted_texts[#f.painted_texts+1] = {text=text,x=x,y=y,options=options}
            end, free = function()
                assert(not freed,"text widget freed twice")
                freed = true; f.live_widgets = f.live_widgets - 1
            end,
        }
    end
    local draw = {
        text = function(_,text,width,size,options) return textwidget(text,width,size,options) end,
        rect = function(_,canvas,x,y,w,h,gray)
            f.rectangles[#f.rectangles+1]={x=x,y=y,w=w,h=h,gray=gray}
        end,
        background = function(_, _, name) f.backgrounds[#f.backgrounds + 1] = name end,
        circle = function(_, _, x, y, radius, gray)
            f.circles[#f.circles + 1] = { x = x, y = y, radius = radius, gray = gray }
        end,
        canvas = function(_,w,h)
            return {
                writePNG = function(_,path)
                    f.writes = f.writes + 1
                    if f.fail_write then
                        local file=assert(io.open(path,"wb")); file:write("partial"); file:close()
                        if f.void_png_write then return end
                        return false,"disk full"
                    end
                    local written = py_png(path,w,h)
                    if not f.void_png_write then return written end
                end,
                free = function() end,
            }
        end,
    }
    local modules = {
        ["ui/widget/container/widgetcontainer"] = {extend=function(_,t) return t end},
        ["ui/uimanager"] = uimanager,
        ["ui/screensaver"] = { setup = function(screensaver, event)
            local kind = s.data[(event and event .. "_" or "") .. "screensaver_type"]
                or s.data.screensaver_type
            screensaver.screensaver_type = kind == "document_cover" and "cover" or kind
            screensaver.image_file = kind == "random_image" and f.next_image
                or s.data.screensaver_document_cover
        end },
        ["ui/renderimage"] = { renderImageFile = function(_, path)
            f.decodes = (f.decodes or 0) + 1
            local width, height = py_decode_png(path)
            if not width then return end
            f.live_images = f.live_images + 1
            local freed = false
            return {
                getWidth = function() return width end,
                getHeight = function() return height end,
                free = function()
                    assert(not freed, "decoded image freed twice")
                    freed = true
                    f.live_images = f.live_images - 1
                end,
            }
        end },
        ["ui/widget/imageviewer"] = {new=function(_,t) return t end},
        ["ui/widget/infomessage"] = {new=function(_,t)return t end},
        ["ui/widget/confirmbox"] = {new=function(_,t)return t end},
        ["datastorage"] = {getDataDir=function() return f.root end,getSettingsDir=function() return f.root.."/settings" end},
        ["docsettings"] = {open = function(_, path) return f.saved_docs[path] or settings() end},
        ["device"] = {
            supportsScreensaver = function() return not f.native_sleep_only end,
            screen={getWidth=function()return 1072 end,getHeight=function()return 1448 end},
        },
        ["util"] = {makePath=function(path) return py_mkdir(path) end},
        ["logger"] = {warn=function(...)f.warnings[#f.warnings+1]={...}end},
        ["gettext"] = function(t)return t end,
        ["libs/libkoreader-lfs"] = {
            attributes=function(path,field)
                if path == f.fixed_path and not field then return f.fixed_attrs end
                return py_attrs(path,field,false)
            end,
            symlinkattributes=function(path,field)return py_attrs(path,field,true)end,
            dir=function(path)
                if path == f.unreadable_dir then error("cannot list cache directory") end
                local names=py_list(path); local i=0
                return function()i=i+1;return names[i]end
            end,
        },
        ["luasettings"] = {open=function(_,path)
            if not f.indices[path] then f.indices[path]=settings() end
            return f.indices[path]
        end},
    }
    for name, value in pairs(modules) do package.loaded[name] = value end
    dofile=function(path)
        if path:match("liuju_draw%.lua$") then return draw end
        return real_dofile(path)
    end
    local plugin = assert(loadfile(TEST_ROOT.."/main.lua"))()
    dofile = real_dofile
    function f:save_reader()
        if self.instance then
            local reader = self.instance.ui
            self.saved_docs[reader.document.file] = settings{
                annotations = reader.annotation and reader.annotation.annotations,
                exclude_screensaver = reader.doc_settings and reader.doc_settings:readSetting("exclude_screensaver"),
            }
            self.instance = nil
        end
    end
    function f:manager()
        self:save_reader()
        local ui = {menu = {registerToMainMenu = function() end}}
        local instance = setmetatable({ui = ui}, {__index = plugin})
        instance:init()
        return instance
    end
    function f:reader(name, annotations, doc_settings, extension)
        self:save_reader()
        local path=self.root.."/"..name..(extension or ".epub")
        local existing=io.open(path,"rb")
        if existing then existing:close()
        else local h=assert(io.open(path,"wb"));h:write(name);h:close() end
        local ui={
            document={file=path,getCoverPageImage=function()
                f.cover_reads = f.cover_reads + 1
                error("receipts must never load the book cover")
            end},
            doc_props={title="测试书 "..name},
            doc_settings=doc_settings,
            annotation={annotations=annotations},
            menu={registerToMainMenu=function()end},
        }
        local instance=setmetatable({ui=ui},{__index=plugin})
        instance:init()
        self.instance=instance
        return instance
    end
    function f:update(instance)
        local menu = {}
        instance:addToMainMenu(menu)
        for _, item in ipairs(menu.liuju.sub_item_table) do
            if item.text == "更新当前书的小票" then return item.callback() end
        end
        error("update menu missing")
    end
    function f:select(path, event)
        self.next_image = path
        local screensaver = modules["ui/screensaver"]
        screensaver:setup(event)
        if screensaver.image then screensaver.image:free(); screensaver.image = nil end
        return screensaver.image_file, screensaver.screensaver_type
    end
    function f:step()
        local callback=table.remove(self.queue,1)
        if callback then callback() end
        return callback ~= nil
    end
    function f:drain()
        local n=0
        while self:step() do n=n+1;assert(n<2000,"scheduler did not become idle") end
        eq(self.live_widgets,0,"all text resources released")
        eq(self.live_images,0,"all decoded images released")
        eq(self.cover_reads, 0, "book covers are never requested")
    end
    function f:images(instance)
        local Store = real_dofile(TEST_ROOT.."/liuju_store.lua")
        local file = instance.ui.document.file
        local store=Store.new(instance.root,instance.state_root,Core.book_id(file),1072,1448)
        return store:images(),store
    end
    return f
end

test("Open, render, repeat and edit use an incremental current-book pool", function()
    local f=fixture()
    local row=annotation("在安静的地方，重新遇见自己留下的句子。")
    local a=f:reader("A",{row})
    f:drain()
    eq(#f:images(a),1)
    eq(f.settings.data.screensaver_type,"random_image")
    local writes=f.writes
    a:onReaderReady();f:drain()
    eq(f.writes,writes,"cache reuse")
    local old=f:images(a)[1]
    row.note="再读一遍。"
    a:onAnnotationsModified()
    eq(f.settings.data.screensaver_type,"document_cover","stale quote hidden immediately")
    f:drain()
    local images=f:images(a)
    eq(#images,1);assert(images[1]~=old);eq(io.open(old,"rb"),nil)
    assert(not table.concat(f.texts,"\n"):find("2026.12",1,true))
end)
test("Lowering the limit, deleting annotations and empty books use the generic fallback",function()
    local f=fixture(); local row=annotation("1234567890")
    local a=f:reader("A",{row});f:drain()
    f.settings:saveSetting("liuju_character_limit",5)
    a:onAnnotationsModified();f:drain()
    eq(#f:images(a),0);eq(f.settings.data.screensaver_type,"document_cover")
    a.ui.annotation.annotations={annotation("短句")}
    a:onAnnotationsModified();f:drain();eq(#f:images(a),1)
    a.ui.annotation.annotations={}
    a:onAnnotationsModified();f:drain()
    eq(#f:images(a),0);eq(f.settings.data.screensaver_type,"document_cover")
end)
test("Switching books cancels pending work and never selects the prior pool",function()
    local f=fixture()
    local a=f:reader("A",{annotation("旧书的句子"),annotation("还没生成的句子")})
    f:step();f:step();f:step() -- start, reconcile, first card
    local a_images=f:images(a);eq(#a_images,1)
    local b=f:reader("B",{annotation("新书的句子")})
    eq(f.settings.data.screensaver_document_cover,GENERIC)
    assert(f.settings.data.screensaver_dir:match("/empty$"))
    f:drain()
    local b_images=f:images(b);eq(#b_images,1)
    assert(f.settings.data.screensaver_dir:find(Core.book_id(b.ui.document.file),1,true))
    eq(#f:images(a),1,"cancelled old job did not finish")
    a:onCloseWidget()
    b:onAnnotationsModified();f:drain()
    eq(#f:images(b),1,"closing an old instance preserves the active instance")
end)
test("Rendering overflow skips a card without truncating its content",function()
    local f=fixture()
    local a=f:reader("A",{annotation("甲"..string.rep("\n",20).."乙")})
    f:drain()
    eq(#f:images(a),0);eq(a._last_stats.layout,1)
    eq(f.settings.data.screensaver_type,"document_cover")
    local found=false
    for _, text in ipairs(f.texts) do if text=="甲"..string.rep("\n",20).."乙" then found=true end end
    assert(found,"the original full text was submitted to layout measurement")
end)
test("Suspend defers work; resume completes; closing leaves no queued callback",function()
    local f=fixture();local a=f:reader("A",{annotation("睡前留下的一句")})
    f:step();a:onSuspend()
    eq(#f.queue,0);eq(f.writes,0)
    a:onResume();f:drain()
    eq(#f:images(a),1)
    local pool=f.settings.data.screensaver_dir
    a:onSuspend();a:onResume()
    eq(f.settings.data.screensaver_dir,pool,"quick resume preserves the valid pool")
    eq(f.settings.data.screensaver_type,"random_image")
    f:drain()
    a:onAnnotationsModified();a:onCloseDocument();a:onCloseWidget()
    eq(#f.queue,0)
end)
test("Partial PNG writes cannot enter the random directory and can be retried",function()
    local f=fixture();f.fail_write=true
    local a=f:reader("A",{annotation("生成失败后重试")});f:drain()
    eq(#f:images(a),0)
    assert(f.settings.data.screensaver_dir:match("/empty$"))
    f.fail_write=false;a:onAnnotationsModified();f:drain()
    eq(#f:images(a),1)
end)
test("PNG writers without a return value still require a complete decodable image", function()
    local f = fixture()
    f.void_png_write = true
    f.fail_write = true
    local a = f:reader("A", { annotation("兼容旧版 PNG 写入接口") })
    f:drain()
    eq(#f:images(a), 0)
    eq(a._last_stats.errors, 1)
    eq(f.warnings[#f.warnings][2], "invalid PNG")
    f.fail_write = false
    a:onAnnotationsModified()
    f:drain()
    local images, store = f:images(a)
    eq(#images, 1)
    eq(a._last_stats.errors, 0)
    eq(f:select(images[1]), images[1])
    eq(io.open(store:temp_path(), "rb"), nil)
end)
test("Reconciliation preserves unrelated files and disables itself on a provider change",function()
    local f=fixture();local a=f:reader("A",{annotation("旧内容")});f:drain()
    local images,store=f:images(a)
    local path=store.book_dir.."/my-photo.png"
    local h=assert(io.open(path,"wb"));h:write("not managed");h:close()
    a.ui.annotation.annotations={};a:onAnnotationsModified();f:drain()
    local kept=assert(io.open(path,"rb"));kept:close()
    f.settings.data.screensaver_dir="/calendar"
    a:onAnnotationsModified()
    eq(f.settings.data.liuju_enabled,false)
    a:stopPlugin()
    eq(f.settings.data.screensaver_dir,"/calendar")
end)
test("Screen restoration occurs on plugin stop, not ordinary reader close",function()
    local f=fixture()
    f.settings.data.screensaver_type="message"
    local a=f:reader("A",{annotation("保存屏保设置")});f:drain()
    a:onCloseWidget()
    eq(f.settings.data.screensaver_type,"random_image")
    a:stopPlugin()
    eq(f.settings.data.screensaver_type,"message")
    eq(f.settings.data.screensaver_dir,nil)
end)
test("Enabling from the library immediately uses verified receipts from the last book", function()
    local f = fixture()
    f.settings.data.screensaver_type = "message"
    local reader = f:reader("A", { annotation("书库启用前已有小票") })
    f:drain()
    local images, store = f:images(reader)
    eq(#images, 1)
    reader:onCloseDocument()

    local library = f:manager()
    local menu = {}
    library:addToMainMenu(menu)
    local toggle = menu.liuju.sub_item_table[1]
    toggle.callback()
    eq(f.settings.data.screensaver_type, "message")
    library:_preview()
    eq(f.preview, images[1])

    toggle.callback()
    eq(toggle.checked_func(), true)
    eq(f.settings.data.screensaver_type, "random_image")
    eq(f:select(images[1]), images[1])
    eq(#f.queue, 0)

    toggle.callback()
    library.policy:enable() -- Older versions could persist only the enable flag.
    local reopened_library = f:manager()
    eq(f:select(images[1]), images[1])
    eq(#f.queue, 0)

    reopened_library.policy:restore(false)
    assert(os.remove(reader.ui.document.file))
    f:manager()
    eq(f.settings.data.screensaver_type, "message")
    eq(f.settings.data.liuju_screensaver_lease, nil)
end)

test("The library hides receipts for annotations deleted while the plugin was disabled", function()
    local f = fixture()
    local removed, kept = annotation("稍后删除的摘录"), annotation("保留的摘录")
    local reader = f:reader("A", { removed, kept })
    f:drain()
    local images, store = f:images(reader)
    eq(#images, 2)
    local entries = Core.collect({ removed, kept }, 80, store.index:readSetting("receipt_key"))
    local obsolete = store.dir .. "/" .. entries[1].filename
    local valid = store.dir .. "/" .. entries[2].filename
    local library = f:manager()
    eq(f:select(obsolete), obsolete)

    local saved = f.saved_docs[reader.ui.document.file]
    saved:saveSetting("annotations", { kept })
    eq(f:select(obsolete), valid)
    library:_preview()
    eq(f.preview, valid)

    saved:saveSetting("exclude_screensaver", true)
    eq(f:select(valid), "resources/koreader.png")
    saved:delSetting("exclude_screensaver")

    library.policy:restore(true)
    saved:saveSetting("annotations", {})
    local menu = {}
    library:addToMainMenu(menu)
    menu.liuju.sub_item_table[1].callback()
    eq(f.settings.data.screensaver_type, "document_cover")
    eq(f:select(), GENERIC)
    f.preview = nil
    library:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书暂无小票")
end)

test("Closing before generation records the current book; disabled startup restores a lease",function()
    local f=fixture()
    f.settings.data.screensaver_type="message"
    local a=f:reader("A",{annotation("甲")});f:drain()
    local b=f:reader("B",{})
    eq(f.settings.data.liuju_last_book.id,Core.book_id(b.ui.document.file))
    b:onCloseDocument();b:onCloseWidget()
    eq(#f.queue,0);eq(f.settings.data.screensaver_document_cover,GENERIC)
    f.settings.data.liuju_enabled=false
    f:reader("B",{});f:drain()
    eq(f.settings.data.screensaver_type,"message")
    eq(f.settings.data.liuju_screensaver_lease,nil)
end)
test("Unsupported annotation APIs are reported and never treated as an empty migrated book",function()
    local f=fixture();local a=f:reader("A",{})
    a.ui.annotation=nil
    f:drain()
    eq(#f.messages,1)
    assert(f.messages[1]:find("KOReader",1,true))
    eq(f.settings.data.screensaver_document_cover,GENERIC)
    eq(a._job,nil)
end)
test("Sleep detects silent edits before choosing an image and resumes the pending update", function()
    local f = fixture()
    local row = annotation("摘录", "旧笔记")
    local a = f:reader("A", { row })
    f:drain()
    local old = f:images(a)[1]
    row.note = "新笔记"
    eq(#f.queue, 0)
    eq(f:select(old, "reboot"), old, "event-specific setup bypasses the ordinary sleep hook")
    eq(#f.queue, 0)
    local image, kind = f:select(old)
    eq(kind, "cover")
    eq(image, GENERIC)
    a:onSuspend()
    eq(#f.queue, 0)
    a:onResume()
    f:drain()
    local updated = f:images(a)[1]
    assert(updated ~= old)
    row.text = "编辑后的摘录"
    image, kind = f:select(updated)
    eq(kind, "cover")
    f:drain()
    assert(f:images(a)[1] ~= updated)
end)
test("Changing stretch restores the former screensaver without discarding the user's change", function()
    local f = fixture()
    f.settings.data.screensaver_type = "cover"
    f.settings.data.screensaver_dir = "/previous"
    f.settings.data.screensaver_show_message = true
    local a = f:reader("A", { annotation("甲") })
    f:drain()
    f.settings.data.screensaver_stretch_images = false
    local _, kind = f:select(f:images(a)[1])
    eq(kind, "cover")
    eq(a.policy:enabled(), false)
    eq(f.settings.data.screensaver_dir, "/previous")
    eq(f.settings.data.screensaver_stretch_images, false)
    eq(f.settings.data.screensaver_show_message, true)
    local b = f:reader("B", { annotation("乙") })
    f:drain()
    b:stopPlugin()
    eq(f.settings.data.screensaver_type, "cover")
    eq(f.settings.data.screensaver_dir, "/previous")
end)
test("Taking over the random directory preserves the new provider's display settings", function()
    local s = settings({ screensaver_type = "cover", screensaver_show_message = true,
        screensaver_stretch_images = false })
    local p = Policy.new(s)
    assert(p:apply{ dir = "/liuju" })
    s.data.screensaver_dir = "/yiyan/.yiyan-screen/"
    s.data.screensaver_stretch_images = true
    s.data.screensaver_show_message = false
    eq(p:check(), false)
    eq(s.data.screensaver_type, "random_image")
    eq(s.data.screensaver_dir, "/yiyan/.yiyan-screen/")
    eq(s.data.screensaver_show_message, false)
    eq(s.data.screensaver_stretch_images, true)
    eq(s.data[Policy.LEASE], nil)
    eq(p:enabled(), false)
end)

test("Stopping Liuju after another mode takes over leaves that mode and its settings intact", function()
    local s = settings({ screensaver_type = "cover", screensaver_show_message = true,
        screensaver_stretch_images = false })
    local p = Policy.new(s)
    assert(p:apply{ dir = "/liuju" })
    s.data.screensaver_type = "document_cover"
    s.data.screensaver_document_cover = "/external.png"
    p:restore(true)
    eq(s.data.screensaver_type, "document_cover")
    eq(s.data.screensaver_document_cover, "/external.png")
    eq(s.data.screensaver_show_message, false)
    eq(s.data.screensaver_stretch_images, true)
end)

test("A failed repair leaves only valid eligible images in the selected pool", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲"), annotation("乙") })
    f:drain()
    local images, store = f:images(a)
    local broken = assert(io.open(images[1], "wb"))
    broken:write("broken PNG")
    broken:close()
    local foreign = store.dir .. "/other.png"
    py_png(foreign, 1072, 1448)
    local selected = f:select(images[1])
    eq(selected, GENERIC)
    f.fail_write = true
    f:drain()
    eq(f.settings.data.screensaver_dir, store.dir)
    eq(io.open(images[1], "rb"), nil)
    eq(io.open(foreign, "rb"), nil)
    assert(io.open(store.book_dir .. "/excluded/other.png", "rb")):close()
    eq(f:select(images[2]), images[2])
    f.fail_write = false
    a:onSuspend()
    a:onResume()
    f:drain()
    eq(#f:images(a), 2)
end)
test("Existing flat caches migrate into the private pool without redrawing", function()
    local f = fixture()
    local a = f:reader("A", { annotation("已缓存的摘录") })
    f:drain()
    local images, store = f:images(a)
    local legacy = store.book_dir .. "/" .. images[1]:match("([^/]+)$")
    assert(os.rename(images[1], legacy))
    eq(f:images(a)[1], legacy)
    local writes = f.writes
    a:onReaderReady()
    f:drain()
    eq(f.writes, writes)
    eq(f:images(a)[1], images[1])
    eq(io.open(legacy, "rb"), nil)
end)
test("Batch generation only writes changed settings and an unchanged wake is idle", function()
    local f = fixture()
    local rows = {}
    for i = 1, 12 do rows[i] = annotation("摘录 " .. i) end
    local a = f:reader("A", rows)
    f:drain()
    eq(#f:images(a), 12)
    eq(f.flushes, 4, "recent book, backup, generic, random pool")
    local flushes, writes = f.flushes, f.writes
    eq(f:select(f:images(a)[1]), f:images(a)[1])
    a:onSuspend()
    a:onResume()
    eq(#f.queue, 0)
    eq(f.flushes, flushes)
    eq(f.writes, writes)
end)
test("Closing after a silent edit removes the stale card while keeping other eligible cards", function()
    local f = fixture()
    local edited = annotation("这段摘录", "旧笔记")
    local a = f:reader("A", { edited, annotation("仍可展示") })
    f:drain()
    local before = f:images(a)
    local writes = f.writes
    edited.note = "新笔记"
    a:onCloseDocument()
    a:onCloseWidget()
    f:manager()
    eq(#f.queue, 1)
    eq(f.writes, writes, "closing never draws new images")
    local after = f:images(a)
    eq(#after, 1)
    assert(after[1] == before[1] or after[1] == before[2])
    eq(f:select(after[1]), after[1])
    local stale = before[1] == after[1] and before[2] or before[1]
    eq(io.open(stale, "rb"), nil)
    f:drain()
    eq(#f:images(a), 2)
    eq(f.writes, writes + 1)
end)
test("Closing a freshly reopened book restores its verified random pool without drawing", function()
    local f = fixture()
    local rows = { annotation("已缓存的摘录") }
    local a = f:reader("A", rows)
    f:drain()
    local old = f:images(a)[1]
    local writes = f.writes
    a:onCloseDocument()
    a:onCloseWidget()
    f:manager()
    local reopened = f:reader("A", rows)
    eq(f.settings.data.screensaver_type, "document_cover")
    reopened:onCloseDocument()
    reopened:onCloseWidget()
    f:manager()
    eq(#f.queue, 0)
    eq(f.settings.data.screensaver_type, "random_image")
    eq(f:select(old), old)
    eq(f.writes, writes)
end)
test("Lowering the limit in the library filters both the screensaver pool and preview", function()
    local f = fixture()
    local a = f:reader("A", { annotation("短句"), annotation("原文", "加上笔记超限") })
    f:drain()
    eq(#f:images(a), 2)
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    manager:_set_limit(2)
    local images, store = f:images(a)
    eq(#images, 1)
    eq(f.settings.data.screensaver_dir, store.dir)
    manager:_preview()
    eq(f.preview, images[1])
    manager:_set_limit(1)
    eq(#f:images(a), 0)
    eq(f.settings.data.screensaver_type, "document_cover")
    f.preview = nil
    manager:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书暂无小票")
end)
test("A library repair reapplies a lower limit before recovering an incomplete index", function()
    local f = fixture()
    local rows = { annotation("旧图") }
    local a = f:reader("A", rows)
    f:drain()
    local images, store = f:images(a)
    store.index:delSetting("counts")
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    manager:_set_limit(2)
    eq(f.settings.data.screensaver_type, "document_cover")
    f.preview = nil
    manager:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书的小票生成中")
    assert(io.open(images[1], "rb")):close()
    f:drain()
    eq(f:images(a)[1], images[1])
    eq(f.settings.data.screensaver_type, "random_image")
end)
test("Corrupt PNG image data is rejected on selection and repaired on ordinary sync", function()
    local f = fixture()
    local a = f:reader("A", { annotation("原文") })
    f:drain()
    local images, store = f:images(a)
    local path = images[1]
    py_corrupt_png_data(path)
    eq(f:select(path), GENERIC)
    eq(io.open(path, "rb"), nil)
    f:drain()
    eq(f:select(path), path)
    local writes = f.writes
    py_corrupt_png_data(path)
    a:onReaderReady()
    f:drain()
    eq(f.writes, writes + 1)
    eq(f:select(path), path)
end)
test("An empty book uses the generic screen and detects the first silent annotation", function()
    local f = fixture()
    local a = f:reader("A", {})
    f:drain()
    eq(f.writes, 0)
    eq(f:select(), GENERIC)
    a.ui.annotation.annotations[1] = annotation("刚划下的句子")
    eq(f:select(), GENERIC)
    f:drain()
    local images = f:images(a)
    eq(#images, 1)
    eq(f:select(images[1]), images[1])
end)
test("Deleted and unverified recent books cannot expose cached cards in the library", function()
    local f = fixture()
    local a = f:reader("A", { annotation("最近阅读") })
    f:drain()
    local image = f:images(a)[1]
    local source = a.ui.document.file
    local last = f.settings.data.liuju_last_book
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    local stamp = last.source
    last.source = nil
    eq(f:select(image), "resources/koreader.png")
    manager:_preview()
    eq(f.preview, nil)
    last.source = stamp
    assert(os.remove(source))
    eq(f:select(image), "resources/koreader.png")
    manager:_preview()
    eq(f.preview, nil)
end)
test("Replacing a book at the same path suppresses its old cache before regeneration", function()
    local f = fixture()
    local a = f:reader("A", { annotation("原来的书") })
    f:drain()
    local images, store = f:images(a)
    local old_receipt_key = store.index:readSetting("receipt_key")
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    local source = a.ui.document.file
    f.fixed_path, f.fixed_attrs = source, py_attrs(source, nil, false)
    local replacement = assert(io.open(source .. ".new", "wb"))
    replacement:write("B")
    replacement:close()
    assert(os.rename(source .. ".new", source))
    eq(f:select(images[1]), "resources/koreader.png")
    manager:_preview()
    eq(f.preview, nil)
    local b = f:reader("A", { annotation("替换后的书") })
    eq(f:select(), GENERIC)
    eq(store.index:readSetting("receipt_key"), old_receipt_key)
    f:drain()
    eq(store.index:readSetting("receipt_key"), old_receipt_key)
    f:update(b)
    assert(f.confirmation)
    f.confirmation.ok_callback()
    f:drain()
    assert(store.index:readSetting("receipt_key") ~= old_receipt_key)
    assert(f:images(b)[1] ~= images[1])
end)
test("Sync keeps the identity of the open document after its file is replaced", function()
    local f = fixture()
    local row = annotation("原书的摘录")
    local a = f:reader("A", { row })
    f:drain()
    local old, writes = f:images(a)[1], f.writes
    local path = a.ui.document.file
    local replacement = assert(io.open(path .. ".new", "wb"))
    replacement:write("new source")
    replacement:close()
    assert(os.rename(path .. ".new", path))
    row.note = "旧阅读界面中的新笔记"
    a:onAnnotationsModified()
    a:onReaderReady()
    a:_queue_sync(true, true)
    assert(f.messages[#f.messages]:find("重新打开", 1, true))
    f:drain()
    eq(f.writes, writes)
    eq(f:select(old), "resources/koreader.png")
    a:_preview()
    eq(f.preview, nil)
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    eq(f:select(old), "resources/koreader.png")
    manager:_preview()
    eq(f.preview, nil)
    local b = f:reader("A", { annotation("新书的摘录") })
    f:drain()
    eq(f.writes, writes)
    f:update(b)
    f.confirmation.ok_callback()
    f:drain()
    assert(f:images(b)[1] ~= old)
end)
test("Full digest detects equal-stat edits beyond the first read chunk", function()
    local f = fixture()
    local path = f.root .. "/A.epub"
    local file = assert(io.open(path, "wb"))
    file:write(string.rep("x", 160000))
    file:close()
    local a = f:reader("A", { annotation("旧版书籍") })
    f:drain()
    local old = f:images(a)[1]
    f.fixed_path, f.fixed_attrs = path, py_attrs(path, nil, false)
    file = assert(io.open(path, "r+b"))
    assert(file:seek("set", 145000))
    file:write("new content")
    file:close()
    local writes = f.writes
    a:_queue_sync(true, true)
    f:drain()
    assert(f.messages[#f.messages]:find("重新打开", 1, true))
    eq(f.writes, writes)
    eq(f:select(old), "resources/koreader.png")
    a:_preview()
    eq(f.preview, nil)
    a:onCloseDocument()
    a:onCloseWidget()
    local manager = f:manager()
    eq(f:select(old), "resources/koreader.png")
    manager:_preview()
    eq(f.preview, nil)
end)
test("Sleep fallback leaves the random pool in place for the next successful verification", function()
    local f = fixture()
    local a = f:reader("A", { annotation("待核对") })
    f:drain()
    local path = a.ui.document.file
    local image = f:images(a)[1]
    local dir = f.settings.data.screensaver_dir
    local flushes = f.flushes
    f.fixed_path, f.fixed_attrs = path, py_attrs(path, nil, false)
    local file = assert(io.open(path, "wb"))
    file:write("B"); file:close()
    eq(f:select(image), "resources/koreader.png")
    eq(f.settings.data.screensaver_type, "random_image")
    eq(f.settings.data.screensaver_dir, dir)
    eq(f.flushes, flushes)
    file = assert(io.open(path, "wb"))
    file:write("A"); file:close()
    eq(f:select(image), image)
end)
test("An owned but mismatched sleep target cannot borrow another book's image or cover", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲书") })
    f:drain()
    local images, store = f:images(a)
    local b = f:reader("B", { annotation("乙书") })
    f:drain()
    b:onCloseDocument()
    b:onCloseWidget()
    local manager = f:manager()
    assert(manager.policy:apply{ dir = store.dir })
    eq(f:select(images[1]), "resources/koreader.png")
    assert(manager.policy:apply{ dir = manager.empty_dir, image = a.ui.document.file })
    eq(f:select(), "resources/koreader.png")
    eq(f.settings.data.screensaver_document_cover, a.ui.document.file)
end)
test("A backup-only lease leaves the original screen active until a book is opened", function()
    local f = fixture()
    local s = f.settings
    s.data.screensaver_type = "document_cover"
    s.data.screensaver_document_cover = "/my-wallpaper.png"
    local flush = s.flush
    s.flush = function() error("interrupted after backing up settings") end
    local policy = Policy.new(s)
    eq(pcall(policy.apply, policy, { dir = "/liuju" }), false)
    s.flush = flush
    f:manager()
    eq(f:select(), "/my-wallpaper.png")
    local a = f:reader("A", { annotation("小票内容") })
    f:drain()
    local image = f:images(a)[1]
    eq(f:select(image), image)
    a:stopPlugin()
    eq(f:select(), "/my-wallpaper.png")
end)
test("Devices with native-only sleep restore the lease and skip wallpaper work", function()
    local f = fixture()
    f.settings.data.screensaver_type = "cover"
    local a = f:reader("A", { annotation("甲书") })
    f:drain()
    assert(f.settings.data.liuju_screensaver_lease)
    local writes = f.writes
    f.native_sleep_only = true
    f:manager()
    eq(f.settings.data.liuju_screensaver_lease, nil)
    eq(f.settings.data.screensaver_type, "cover")
    local b = f:reader("B", { annotation("乙书") })
    f:drain()
    eq(b._opened, nil)
    eq(f.writes, writes)
    local menu = {}
    b:addToMainMenu(menu)
    eq(menu.liuju.sub_item_table[1].enabled_func(), false)
end)
test("Sleep falls back safely when the index is malformed or a validator throws", function()
    local f = fixture()
    local a = f:reader("A", { annotation("有效小票") })
    f:drain()
    local images, store = f:images(a)
    local image = images[1]
    local foreign = "liuju-" .. string.rep("f", 64) .. ".png"
    local legacy_foreign = "liuju-" .. string.rep("e", 64) .. ".png"
    py_png(store.dir .. "/" .. foreign, 1072, 1448)
    py_png(store.book_dir .. "/" .. legacy_foreign, 1072, 1448)
    store.index.data = 1
    eq(f:select(image), "resources/koreader.png")
    f:drain()
    assert(io.open(store.book_dir .. "/excluded/" .. foreign, "rb")):close()
    assert(io.open(store.book_dir .. "/excluded/" .. legacy_foreign, "rb")):close()
    eq(f:select(image), image)
    local read = store.index.readSetting
    store.index.readSetting = function() error("index unavailable") end
    eq(f:select(image), "resources/koreader.png")
    store.index.readSetting = read
    a._before_sleep = function() error("source check unavailable") end
    eq(f:select(image), "resources/koreader.png")
    a.policy:restore(true)
    f.settings.data.screensaver_type = "document_cover"
    f.settings.data.screensaver_document_cover = "/my-wallpaper.png"
    eq(f:select(), "/my-wallpaper.png")
end)
test("An incomplete index hides unknown images and repairs in the library", function()
    local f = fixture()
    local rows = { annotation("有效小票") }
    local a = f:reader("A", rows)
    f:drain()
    local images, store = f:images(a)
    local foreign = "liuju-" .. string.rep("c", 64) .. ".png"
    py_png(store.dir .. "/" .. foreign, 1072, 1448)
    store.index:delSetting("counts")
    store.index:saveSetting("skipped", 1)
    a:onCloseDocument()
    a:onCloseWidget()
    f:manager():_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书的小票生成中")
    f:drain()
    eq(f:images(a)[1], images[1])
    eq(f:select(images[1]), images[1])
    assert(io.open(store.book_dir .. "/excluded/" .. foreign, "rb")):close()
end)
test("PDF skips generation and preview without blocking the next supported book", function()
    local f = fixture()
    local a = f:reader("A", { annotation("当前小票") })
    f:drain()
    local old, writes = f:images(a)[1], f.writes
    local pdf = f:reader("B", { annotation("PDF 内容") }, nil, ".PDF")
    f:drain()
    eq(f.writes, writes)
    eq(f:select(old), "resources/koreader.png")
    pdf:_preview()
    eq(f.preview, nil)
    assert(f.messages[#f.messages]:find("PDF", 1, true))
    pdf:onCloseDocument()
    pdf:onCloseWidget()
    f:manager()
    eq(f:select(old), "resources/koreader.png")
    local c = f:reader("C", { annotation("继续阅读") })
    f:drain()
    eq(f:select(f:images(c)[1]), f:images(c)[1])
end)
test("Sleep rejects a decodable managed-name card missing from the current book's index", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲书的摘录") })
    f:drain()
    local from = f:images(a)[1]
    local b = f:reader("B", { annotation("乙书的摘录") })
    f:drain()
    local images, store = f:images(b)
    local name = from:match("([^/]+)$")
    local foreign = store.dir .. "/" .. name
    local input, output = assert(io.open(from, "rb")), assert(io.open(foreign, "wb"))
    assert(output:write(input:read("*a")))
    input:close()
    output:close()
    eq(f:select(foreign), GENERIC)
    f:drain()
    eq(f:select(images[1]), images[1])
    eq(io.open(foreign, "rb"), nil)
    assert(io.open(store.book_dir .. "/excluded/" .. name, "rb")):close()
end)
test("Book-level sleep exclusion survives closing and is lifted when opening another book", function()
    local f = fixture()
    local privacy = settings({ exclude_screensaver = true })
    local a = f:reader("A", { annotation("私密摘录") }, privacy)
    f:drain()
    eq(f.writes, 0)
    eq(f:select(), "resources/koreader.png")
    privacy:delSetting("exclude_screensaver")
    f:select()
    f:drain()
    local cached = f:images(a)[1]
    eq(f:select(cached), cached)
    privacy:saveSetting("exclude_screensaver", true)
    a:onCloseDocument()
    a:onCloseWidget()
    f:manager()
    eq(f:select(cached), "resources/koreader.png")
    local b = f:reader("B", { annotation("另一本文字") })
    f:drain()
    eq(f:select(f:images(b)[1]), f:images(b)[1])
end)
test("Character screening handles long quotes and combined notes without a character table", function()
    local characters = Core.characters
    Core.characters = function() error("screening built a full character table") end
    local ok, entries, reasons = pcall(Core.collect, {
        annotation(string.rep("长", 200000)),
        annotation(string.rep("字", 79), "笔记"),
        annotation("　甲\r\n乙　", "　丙\r丁  "),
    }, 80, "test")
    Core.characters = characters
    assert(ok, entries)
    eq(#entries, 1)
    eq(reasons.too_long, 2)
    eq(entries[1].text, "甲\n乙")
    eq(entries[1].note, "丙\n丁")
    eq(entries[1].count, 4)
end)
test("Preview identifies current-book receipts, pending generation, and no eligible receipts", function()
    local f = fixture()
    local reader = f:reader("A", { annotation("正在生成的小票") })
    local menu = {}
    reader:addToMainMenu(menu)
    local preview
    for _, item in ipairs(menu.liuju.sub_item_table) do
        if item.text == "预览一张" then preview = item.callback end
    end
    assert(preview, "preview action is missing")

    preview()
    eq(f.messages[#f.messages], "当前书的小票生成中")
    eq(f.preview, nil)
    assert(f:step() and f:step(), "prepare the pool before drawing")
    preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书的小票生成中")

    f:drain()
    preview()
    eq(f.preview, f:images(reader)[1])
    eq(f.preview_title, "当前书的小票")

    local empty = f:reader("B", { annotation(string.rep("长", 81)) })
    f:drain()
    f.preview = nil
    empty:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书暂无小票")
end)

test("A temporarily unreadable cache reports an unknown preview state and can be retried", function()
    local f = fixture()
    local reader = f:reader("A", { annotation("可预览的小票") })
    f:drain()
    local images, store = f:images(reader)
    f.unreadable_dir = store.dir

    reader:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "暂时无法确认当前书的小票状态。")
    f:manager():_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "暂时没有可预览的壁纸。")

    f.unreadable_dir = nil
    f:manager():_preview()
    eq(f.preview, images[1])
end)

test("Opening a book while disabled makes it the only candidate for library re-enable", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲书内容") })
    f:drain()
    local old, writes = f:images(a)[1], f.writes
    a.policy:restore(true)
    a:onCloseDocument()
    local b = f:reader("B", { annotation("乙书内容") })
    b:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书暂无小票")
    eq(f.settings.data.liuju_last_book.file, b.ui.document.file)
    eq(f.writes, writes)
    b:onCloseDocument()
    local library = f:manager()
    library:_preview()
    eq(f.preview, nil)
    local menu = {}
    library:addToMainMenu(menu)
    menu.liuju.sub_item_table[1].callback()
    eq(f:select(old), GENERIC)
    f:drain()
    local current = f:images(b)[1]
    assert(current and current ~= old)
    eq(f:select(current), current)
end)

test("An unsupported last book opened while disabled cannot reveal an earlier receipt", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲书内容") })
    f:drain()
    local old, writes = f:images(a)[1], f.writes
    a.policy:restore(true)
    f:reader("B", {}, nil, ".pdf")
    local library = f:manager()
    local menu = {}
    library:addToMainMenu(menu)
    menu.liuju.sub_item_table[1].callback()
    f:drain()
    eq(f:select(old), GENERIC)
    eq(f.writes, writes)
end)
test("Preview ignores a silently edited note until its new wallpaper is ready", function()
    local f = fixture()
    local row = annotation("摘录", "编辑前")
    local a = f:reader("A", { row })
    f:drain()
    local images, store = f:images(a)
    row.note = "编辑后"
    a:_preview()
    eq(f.preview, nil)
    eq(f.messages[#f.messages], "当前书的小票生成中")
    f:drain()
    a:_preview()
    assert(f.preview ~= images[1])
    eq(f.preview, f:images(a)[1])
end)
test("Quote and note bitmaps stay bounded when eligible text contains thousands of newlines", function()
    local f = fixture()
    local text = "甲" .. string.rep("\n", 10000) .. "乙"
    local a = f:reader("A", { annotation(text), annotation("短句", text) })
    f:drain()
    eq(a._last_stats.layout, 2)
    eq(#f:images(a), 0)
    local layout = real_dofile(TEST_ROOT.."/liuju_layout.lua").for_screen(1072,1448,"classic")
    assert(f.max_bitmap_height <= layout.body.h)
end)
test("A large cached pool is verified across callbacks and closing avoids bulk decodes", function()
    local f = fixture()
    local rows = {}
    for i = 1, 120 do rows[i] = annotation("缓存 " .. i) end
    local a = f:reader("A", rows)
    f:drain()
    local writes = f.writes
    a:onCloseDocument()
    a:onCloseWidget()
    local reopened = f:reader("A", rows)
    local before = f.decodes
    for i = 1, 122 do
        local start = f.decodes
        assert(f:step())
        assert(f.decodes - start <= 1, "bulk decode in one callback")
    end
    f:drain()
    eq(f.decodes - before, 120)
    eq(reopened._last_stats.cached, 120)
    eq(f.writes, writes)
    reopened:onCloseDocument()
    reopened:onCloseWidget()
    local quick = f:reader("A", rows)
    before = f.decodes
    quick:onCloseDocument()
    eq(f.decodes - before, 0, "closing does not decode the pool")
    eq(f.settings.data.screensaver_type, "random_image")
end)
test("Titles keep all characters when they fit and ellipsize only on overflow", function()
    local layout = real_dofile(TEST_ROOT.."/liuju_layout.lua").for_screen(1072,1448,"classic")
    for _, suffix in ipairs({ "", string.rep(" Extra words", 12) }) do
        local f = fixture()
        local a = f:reader("A", { annotation("短摘录") })
        local title = "A Quiet Place to Read" .. suffix
        a.ui.doc_props.title = title
        f:drain()
        local painted
        for _, item in ipairs(f.painted_texts) do
            if item.x == layout.title.x and item.y >= layout.footer.y then painted = item.text end
        end
        assert(painted)
        local date = "  ·  2026.11.03"
        if suffix == "" then eq(painted, title .. date)
        else assert(painted:sub(-#date) == date and painted:find("…" .. date, 1, true)) end
    end
end)
local function wallpaper_menu(instance)
    local menu = {}
    instance:addToMainMenu(menu)
    for _, item in ipairs(menu.liuju.sub_item_table) do
        if item.text == "壁纸样式" then return item.sub_item_table, menu.liuju.sub_item_table[1] end
    end
    error("wallpaper style menu missing")
end

test("Wallpaper menu persists a single style and replaces a running generation", function()
    local f = fixture()
    local a = f:reader("A", { annotation("样式切换", nil, "2026-11-06 08:00:00") })
    f:drain()
    local original, store = f:images(a)
    local styles = wallpaper_menu(a)
    eq(#styles, 3)
    eq(styles[1].checked_func(), true)
    styles[2].callback()
    eq(styles[1].checked_func(), false)
    eq(styles[2].checked_func(), true)
    eq(f:select(original[1]), GENERIC)
    a:_preview()
    eq(f.preview, nil)
    assert(f:step() and f:step(), "calendar preparation started")
    styles[3].callback()
    f:drain()
    local current = f:images(a)
    eq(#current, 1)
    assert(current[1] ~= original[1])
    eq(io.open(original[1], "rb"), nil)
    eq(f.backgrounds[2], "dark-card-background.png")
    eq(f:select(current[1]), current[1])
    assert(store.index:readSetting("receipt_key"):find("/dark/", 1, true))
    local seen = false
    for _, item in ipairs(f.painted_texts) do
        if item.text == "11.06  /  FRI" then seen = true end
    end
    assert(seen, "dark card uses annotation date, not generation day")
    f:reader("B", { annotation("另一本文字") })
    f:drain()
    eq(f.backgrounds[3], "dark-card-background.png")
end)

test("Library regenerates saved annotations when style changes and after re-enabling", function()
    local f = fixture()
    local reader = f:reader("A", { annotation("旧原文") })
    f:drain()
    local old = f:images(reader)[1]
    reader:onCloseDocument()
    local library = f:manager()
    local styles, toggle = wallpaper_menu(library)
    toggle.callback()
    local saved = f.saved_docs[reader.ui.document.file]
    saved:saveSetting("annotations", { { note = "书库使用已保存的笔记", datetime = "2026-11-06" } })
    styles[2].callback()
    eq(f.settings.data.liuju_wallpaper_style, "calendar")
    eq(#f.queue, 0)
    toggle.callback()
    eq(f:select(old), GENERIC)
    f:drain()
    local current = f:images(reader)
    eq(#current, 1)
    eq(f.backgrounds[2], "date-card-background.png")
    eq(f:select(current[1]), current[1])
    library:_preview()
    eq(f.preview, current[1])
    local seen = {}
    for _, item in ipairs(f.painted_texts) do seen[item.text] = true end
    assert(seen["书库使用已保存的笔记"] and seen["星期五"])
    styles[1].callback()
    local restarted_library = f:manager()
    f:drain()
    eq(f.backgrounds[3], "lyrics-background.png")
    eq(f:select(f:images(reader)[1]), f:images(reader)[1])
    restarted_library:deletePluginSettings()
    eq(f.settings.data.liuju_wallpaper_style, nil)
end)

test("Pre-style cache and legacy cover paths stay hidden until regenerated", function()
    local f = fixture()
    local reader = f:reader("A", { annotation("旧版小票") })
    f:drain()
    local paths, store = f:images(reader)
    store.index:saveSetting("receipt_key", "album-player-4")
    local library = f:manager()
    eq(f:select(paths[1]), GENERIC)
    library:_preview()
    eq(f.preview, nil)
    library.policy:apply{ dir = library.empty_dir, image = reader.ui.document.file }
    eq(f:select(), GENERIC)
    local new_reader = f:reader("A", { annotation("旧版小票") })
    f:drain()
    eq(f:select(f:images(new_reader)[1]), f:images(new_reader)[1])
end)

test("A replacement sharing the old sidecar is blocked in the library and survives a book switch", function()
    local f = fixture()
    local rows = { annotation("旧文件的批注") }
    local a = f:reader("A", rows)
    f:drain()
    local images, store = f:images(a)
    local old, old_digest = images[1], store.index:readSetting("book_digest")
    assert(old_digest)
    store.index:delSetting("book_digest") -- The 1.1.0 index stored it only in the render key.
    a:onCloseDocument()
    f:reader("Other", {}):onCloseDocument()
    f:manager()
    local path = a.ui.document.file
    local replacement = assert(io.open(path .. ".new", "wb"))
    assert(replacement:write("replacement book"))
    replacement:close()
    assert(os.rename(path .. ".new", path))

    local b = f:reader("A", rows)
    b.ui.doc_props.title = "新文件的书名"
    b:onBookMetadataChanged()
    assert(f.settings.data.liuju_last_book.full_digest ~= old_digest)
    local library = f:manager()
    library:_preview()
    eq(f.preview, nil)
    eq(f:select(old), GENERIC)
    eq(#f.queue, 0)
    eq(f.writes, 1)
    eq(f.saved_docs[path]:readSetting("annotations")[1], rows[1])

    local reopened = f:reader("A", rows)
    f:update(reopened)
    local stale_confirmation = assert(f.confirmation)
    f:reader("C", {})
    stale_confirmation.ok_callback()
    f:drain()
    eq(f.writes, 1)
    local verified = f:reader("A", rows)
    f:drain()
    eq(f.writes, 1)
    f:update(verified)
    f.confirmation.ok_callback()
    f:drain()
    local updated = f:images(verified)
    eq(#updated, 1)
    assert(updated[1] ~= old)
    eq(f:select(updated[1]), updated[1])
    eq(store.index:readSetting("book_digest"), f.settings.data.liuju_last_book.full_digest)
end)

test("File identity recorded while disabled survives switching away before any receipts exist", function()
    local f = fixture()
    f.settings.data[Policy.ENABLED] = false
    local rows = { annotation("尚未制成小票的批注") }
    local a = f:reader("A", rows)
    local _, store = f:images(a)
    local old_digest = store.index:readSetting("book_digest")
    assert(old_digest)
    f:reader("B", {})
    local file = assert(io.open(a.ui.document.file, "wb"))
    assert(file:write("different book"))
    file:close()

    f:reader("A", rows)
    local library = f:manager()
    local _, toggle = wallpaper_menu(library)
    toggle.callback()
    f:drain()
    eq(f.writes, 0)
    eq(f:select(), GENERIC)
    eq(store.index:readSetting("book_digest"), old_digest)
    library:_preview()
    assert(f.messages[#f.messages]:find("文件已更换", 1, true))
end)

test("Library restart finishes a partial style change without dropping a valid receipt", function()
    local f = fixture()
    local a = f:reader("A", { annotation("第一条"), annotation("第二条"), annotation("第三条") })
    f:drain()
    a:onCloseDocument()
    local library = f:manager()
    library:_set_style("dark")
    assert(f:step() and f:step() and f:step())
    local partial = f:images(a)
    eq(#partial, 1)
    f:manager()
    eq(f:select(partial[1]), partial[1])
    f:drain()
    eq(#f:images(a), 3)
    eq(f.writes, 6)
end)

test("A corrupt library receipt is regenerated after resume while a valid peer remains selectable", function()
    local f = fixture()
    local a = f:reader("A", { annotation("第一条"), annotation("第二条") })
    f:drain()
    local paths = f:images(a)
    a:onCloseDocument()
    local library = f:manager()
    py_corrupt_png_data(paths[1])
    eq(f:select(paths[1]), paths[2])
    library:onSuspend()
    eq(#f.queue, 0)
    library:onResume()
    f:drain()
    eq(f:select(paths[1]), paths[1])
    eq(f.writes, 3)
end)

test("The library recovers when its only receipt was corrupted and sleep was interrupted", function()
    local f = fixture()
    local a = f:reader("A", { annotation("唯一小票") })
    f:drain()
    local path = f:images(a)[1]
    a:onCloseDocument()
    f:manager()
    py_corrupt_png_data(path)
    eq(f:select(path), GENERIC)
    assert(io.open(path, "rb") == nil)
    f:manager()
    f:drain()
    eq(f:select(path), path)
    eq(f.writes, 2)
end)

test("An inactive library retry cannot change the active reader's screensaver", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲书") })
    f:drain()
    a:onCloseDocument()
    local library = f:manager()
    f.fail_write = true
    library:_set_style("dark")
    f:drain()
    assert(library._retry_sync)
    f.fail_write = false
    local b = f:reader("B", { annotation("乙书") })
    f:drain()
    local image = f:images(b)[1]
    library:onResume()
    eq(f:select(image), image)
    eq(#f.queue, 0)
end)

test("Library initialization recognizes layout skips as completed work", function()
    local f = fixture()
    local a = f:reader("A", { annotation("甲" .. string.rep("\n", 25) .. "乙") })
    f:drain()
    eq(a._last_stats.layout, 1)
    a:onCloseDocument()
    f:manager()
    eq(#f.queue, 0)
    eq(f.writes, 0)
    eq(f:select(), GENERIC)
end)

test("Phrase breaks keep closing quotes and existing newlines intact", function()
    local f = fixture()
    f:reader("A", { annotation("先读。”\n再想；最后再读。") })
    f:drain()
    local expected = "先读。”\n再想；\n最后再读。"
    for _, item in ipairs(f.painted_texts) do
        if item.text == expected then return end
    end
    error("quote punctuation or existing line breaks changed")
end)

test("Classic wallpaper keeps the original disc and puts title and date on one line", function()
    local layout = real_dofile(TEST_ROOT .. "/liuju_layout.lua")
    for _, size in ipairs({ {1072, 1448}, {600, 800} }) do
        local l = layout.for_screen(size[1], size[2], "classic")
        eq(l.disc.y, l.footer.y)
        eq(l.footer.y + l.footer.h, l.height)
        assert(l.body.y + l.body.h < l.disc.y - l.disc.radius)
        assert(l.disc.x + l.disc.radius < l.title.x)
    end
    local f = fixture()
    f:reader("A", { annotation("正文在上方") })
    f:drain()
    local l = layout.for_screen(1072, 1448, "classic")
    eq(f.backgrounds[1], "lyrics-background.png")
    eq(#f.circles, 6)
    eq(f.circles[1].radius, l.disc.radius)
    eq(f.circles[1].y, l.footer.y)
    eq(f.circles[1].gray, 255)
    eq(f.circles[2].gray, 0)
    eq(f.rectangles[1].y, l.footer.y)
    eq(f.rectangles[1].gray, 0)
    local footer_count = 0
    for _, item in ipairs(f.painted_texts) do
        if item.y >= l.footer.y then
            footer_count = footer_count + 1
            eq(item.text, "测试书 A  ·  2026.11.03")
            eq(item.options.align, "center")
        end
    end
    eq(footer_count, 1)
end)

test("Production adapter applies DPI once and frees scaled and unscaled backgrounds", function()
    local raw_size, decoded_path, blitted
    local source = { free = function(self) self.freed = (self.freed or 0) + 1 end }
    local scaled = { free = source.free }
    package.loaded["device"] = { screen = { scaleBySize = function(_, value) return value * 2 end } }
    package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return v end, COLOR_WHITE = 255 }
    package.loaded["ui/font"] = { getFace = function(_, _, size) raw_size = size; return { size = size * 2 } end }
    package.loaded["ui/widget/textboxwidget"] = { new = function(_, args) return args end }
    package.loaded["ui/renderimage"] = {
        renderImageFile = function(_, path) decoded_path = path; return source end,
        scaleBlitBuffer = function(_, image, w, h, free)
            eq(image, source); eq(w, 1072); eq(h, 1448); eq(free, false)
            return scaled
        end,
    }
    local draw = real_dofile(TEST_ROOT .. "/liuju_draw.lua")
    local widget = draw:text("文字", 772, 46, { max_height = 120, gray = 255, bgcolor = 0 })
    eq(raw_size, 23); eq(widget.face.size, 46)
    eq(widget.height, 120); eq(widget.height_adjust, true)
    eq(widget.fgcolor, 255); eq(widget.bgcolor, 0)
    draw:background({ blitFrom = function(_, image) blitted = image end }, "lyrics-background.png", 1072, 1448)
    assert(decoded_path:match("/assets/lyrics%-background%.png$"))
    eq(blitted, scaled); eq(scaled.freed, 1); eq(source.freed, 1)
end)

print(string.format("%d regression scenarios passed", test_count))
