local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local test_count = 0
local function test(name, fn)
    fn()
    test_count = test_count + 1
    print("PASS " .. name)
end
package.loaded["ffi/sha2"] = { sha256 = function(text) return py_hash(text) end }
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

local fixture_id = 0
local real_dofile = dofile
local function fixture()
    fixture_id = fixture_id + 1
    local f = { root = SCRATCH .. "/case-" .. fixture_id, queue = {}, indices = {}, writes = 0,
        texts = {}, painted_texts = {}, rectangles = {}, frees = 0,
        live_widgets = 0, live_covers = 0, live_images = 0, cover_reads = 0, flushes = 0, messages = {}, warnings = {} }
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
        if widget.file then f.preview = widget.file end
        if widget.text then f.messages[#f.messages+1] = widget.text end
    end
    local function textwidget(text, width, size, options)
        options = options or {}
        f.live_widgets = f.live_widgets + 1
        local freed = false
        f.texts[#f.texts+1] = text
        local columns, lines = math.max(1,math.floor(width/size)), 0
        for line in (text.."\n"):gmatch("(.-)\n") do
            lines = lines + math.max(1,math.ceil(#(Core.characters(line) or {})/columns))
        end
        return {
            getSize = function() return {h=math.floor(size*(1+(options.line_height or 0.48))+0.5)*lines} end,
            getAllLineCount = function() return lines end,
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
        cover_size = function(_, image) if image then return 420, 600 end end,
        cover = function() return false end,
        canvas = function(_,w,h)
            return {
                writePNG = function(_,path)
                    f.writes = f.writes + 1
                    if f.fail_write then
                        local file=assert(io.open(path,"wb")); file:write("partial"); file:close()
                        return false,"disk full"
                    end
                    return py_png(path,w,h)
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
        ["datastorage"] = {getDataDir=function() return f.root end,getSettingsDir=function() return f.root.."/settings" end},
        ["docsettings"] = {},
        ["device"] = {screen={getWidth=function()return 1072 end,getHeight=function()return 1448 end}},
        ["util"] = {makePath=function(path) return py_mkdir(path) end},
        ["logger"] = {warn=function(...)f.warnings[#f.warnings+1]={...}end},
        ["gettext"] = function(t)return t end,
        ["libs/libkoreader-lfs"] = {
            attributes=function(path,field)return py_attrs(path,field,false)end,
            symlinkattributes=function(path,field)return py_attrs(path,field,true)end,
            dir=function(path)
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
    function f:manager()
        local ui = {menu = {registerToMainMenu = function() end}}
        local instance = setmetatable({ui = ui}, {__index = plugin})
        instance:init()
        return instance
    end
    function f:reader(name, annotations)
        local path=self.root.."/"..name..".epub"
        local existing=io.open(path,"rb")
        if existing then existing:close()
        else local h=assert(io.open(path,"wb"));h:write(name);h:close() end
        local ui={
            document={file=path,getCoverPageImage=function()
                f.cover_reads = f.cover_reads + 1
                f.live_covers = f.live_covers + 1
                local freed=false
                return {free=function()
                    assert(not freed,"cover freed twice")
                    freed=true;f.live_covers=f.live_covers-1
                end}
            end},
            doc_props={title="测试书 "..name},
            annotation={annotations=annotations},
            menu={registerToMainMenu=function()end},
        }
        local instance=setmetatable({ui=ui},{__index=plugin})
        instance:init()
        self.instance=instance
        return instance
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
        eq(self.live_covers,0,"all cover resources released")
        eq(self.live_images,0,"all decoded images released")
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
test("Lowering the limit, deleting annotations and empty books use the cover fallback",function()
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
    f:step();f:step();f:step() -- start, fallback, first card
    local a_images=f:images(a);eq(#a_images,1)
    local b=f:reader("B",{annotation("新书的句子")})
    eq(f.settings.data.screensaver_document_cover,b.ui.document.file)
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
test("Closing before generation records the current book; disabled startup restores a lease",function()
    local f=fixture()
    f.settings.data.screensaver_type="message"
    local a=f:reader("A",{annotation("甲")});f:drain()
    local b=f:reader("B",{})
    eq(f.settings.data.liuju_last_book.id,Core.book_id(b.ui.document.file))
    b:onCloseDocument();b:onCloseWidget()
    eq(#f.queue,0);eq(f.settings.data.screensaver_document_cover,b.ui.document.file)
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
    eq(f.settings.data.screensaver_document_cover,a.ui.document.file)
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
    assert(image:match("%-cover%.png$"))
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
test("Changing the active random folder retains random mode when yielding ownership", function()
    local s = settings({ screensaver_type = "cover", screensaver_show_message = true })
    local p = Policy.new(s)
    assert(p:apply{ dir = "/liuju" })
    s.data.screensaver_dir = "/new-folder"
    eq(p:check(), false)
    eq(s.data.screensaver_type, "random_image")
    eq(s.data.screensaver_dir, "/new-folder")
    eq(s.data.screensaver_show_message, true)
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
    eq(selected, store.fallback)
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
    eq(f.flushes, 4, "backup, raw cover, generated cover, random pool")
    local flushes, reads, writes = f.flushes, f.cover_reads, f.writes
    eq(f:select(f:images(a)[1]), f:images(a)[1])
    a:onSuspend()
    a:onResume()
    eq(#f.queue, 0)
    eq(f.flushes, flushes)
    eq(f.cover_reads, reads)
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
    eq(#f.queue, 0)
    eq(f.writes, writes, "closing never draws new images")
    local after = f:images(a)
    eq(#after, 1)
    assert(after[1] == before[1] or after[1] == before[2])
    eq(f:select(after[1]), after[1])
    local stale = before[1] == after[1] and before[2] or before[1]
    eq(io.open(stale, "rb"), nil)
end)
test("Closing a freshly reopened book restores its verified random pool without drawing", function()
    local f = fixture()
    local rows = { annotation("已缓存的摘录") }
    local a = f:reader("A", rows)
    f:drain()
    local old = f:images(a)[1]
    local reads, writes = f.cover_reads, f.writes
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
    eq(f.cover_reads, reads)
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
    manager:_preview()
    eq(f.preview, store.fallback)
end)
test("After a lower limit, legacy cards wait for the next verified open", function()
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
    manager:_preview()
    eq(f.preview, store.fallback)
    assert(io.open(images[1], "rb")):close()
    local reopened = f:reader("A", rows)
    f:drain()
    eq(f:images(reopened)[1], images[1])
    eq(f.settings.data.screensaver_type, "random_image")
end)
test("Corrupt PNG image data is rejected on selection and repaired on ordinary sync", function()
    local f = fixture()
    local a = f:reader("A", { annotation("原文") })
    f:drain()
    local images, store = f:images(a)
    local path = images[1]
    py_corrupt_png_data(path)
    eq(f:select(path), store.fallback)
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
test("A damaged generated cover is replaced when a book has no eligible cards", function()
    local f = fixture()
    local a = f:reader("A", {})
    f:drain()
    local cover = f.settings.data.screensaver_document_cover
    py_corrupt_png_data(cover)
    eq(f:select(), "resources/koreader.png")
    f:drain()
    eq(f:select(), cover)
    eq(f.settings.data.screensaver_type, "document_cover")
end)
test("Poster straddles the black footer with the cover and centers the title beside it",function()
    local layout=real_dofile(TEST_ROOT.."/liuju_layout.lua")
    for _,size in ipairs({{1072,1448,420,600},{600,800,300,300},{1448,1072,600,420}}) do
        local l=layout.for_screen(size[1],size[2],size[3],size[4])
        eq(l.footer.x,0);eq(l.footer.w,l.width);eq(l.footer.y+l.footer.h,l.height)
        assert(l.body.y<l.height*0.25)
        assert(l.body.y+l.body.h<l.album.y)
        assert(l.body.y+l.body.h+l.date_gap+math.ceil(l.date_size*1.48)<l.album.y)
        assert(l.album.x<l.width*0.25 and l.album.x+l.album.w<l.title.x)
        eq(l.title.x-l.album.x-l.album.w,l.width-l.title.x-l.title.w)
        assert(math.abs((2*l.title.y+l.title.h)-(2*l.footer.y+l.footer.h))<=1)
        eq(l.footer.y-l.album.y,math.floor(l.album.h/2))
        eq(l.footer.y-l.cover.y,math.floor(l.cover.h/2))
        local frame=l.cover.x-l.album.x
        eq(l.cover.y-l.album.y,frame)
        eq(l.album.w-l.cover.w,2*frame)
        eq(l.album.h-l.cover.h,2*frame)
        assert(math.abs(l.cover.w-l.cover.h*size[3]/size[4])<=2)
    end
    local f=fixture();local a=f:reader("A",{annotation("正文在上方")});f:drain()
    local l=layout.for_screen(1072,1448)
    local title_seen,body_seen,footer_seen,frame_seen=false,false,false,false
    for _,paint in ipairs(f.painted_texts) do
        if paint.text=="测试书 A" and paint.x==l.title.x then
            eq(paint.options.gray,255);eq(paint.options.bgcolor,0)
            eq(paint.options.align,"center")
            local line_height=math.floor(l.title_size*(1+paint.options.line_height)+0.5)
            eq(paint.y,l.title.y+math.floor((l.title.h-line_height)/2))
            title_seen=true
        elseif paint.text=="正文在上方" then
            eq(paint.x,l.body.x);eq(paint.y,l.body.y);body_seen=true
        end
    end
    for _,rect in ipairs(f.rectangles) do
        if rect.x==0 and rect.y==l.footer.y and rect.w==l.width and rect.gray==0 then footer_seen=true end
        if rect.x==l.album.x and rect.y==l.album.y and rect.w==l.album.w and rect.h==l.album.h and rect.gray==0 then
            frame_seen=true
        end
    end
    assert(title_seen and body_seen and footer_seen and frame_seen)
end)
test("Production drawing adapter applies DPI once and paints the fitted cover rectangle",function()
    local raw_size, image_args, image_freed, painted_x, painted_y
    package.loaded["device"]={screen={scaleBySize=function(_,value)return value*2 end}}
    package.loaded["ffi/blitbuffer"]={Color8=function(v)return v end,COLOR_WHITE=255}
    package.loaded["ui/font"]={getFace=function(_,name,size)raw_size=size;return{size=size*2}end}
    package.loaded["ui/widget/textboxwidget"]={new=function(_,args)return args end}
    package.loaded["ui/widget/imagewidget"]={new=function(_,args)
        image_args=args
        return{paintTo=function(_,_,x,y)painted_x,painted_y=x,y end,free=function()image_freed=true end}
    end}
    local draw=real_dofile(TEST_ROOT.."/liuju_draw.lua")
    local widget=draw:text("文字",772,46)
    eq(raw_size,23);eq(widget.face.size,46);eq(widget.height,nil,"no native clipping height")
    local white=draw:text("白字书名",572,40,{gray=255,bgcolor=0})
    eq(white.fgcolor,255);eq(white.bgcolor,0)
    local image = {getWidth=function()return 420 end,getHeight=function()return 600 end}
    local width,height=draw:cover_size(image)
    eq(width,420);eq(height,600)
    assert(draw:cover({}, image, {x=146,y=181,w=179,h=256}))
    eq(image_args.width,179);eq(image_args.height,256)
    eq(painted_x,146);eq(painted_y,181)
    eq(image_args.image_disposable,false);assert(image_freed)
end)
print(string.format("%d regression scenarios passed",test_count))
