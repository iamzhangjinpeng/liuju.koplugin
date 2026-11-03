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
        live_widgets = 0, live_covers = 0, messages = {}, warnings = {} }
    py_mkdir(f.root)
    local s = settings()
    G_reader_settings = s
    f.settings = s
    local uimanager = {}
    function uimanager:scheduleIn(delay, cb) f.queue[#f.queue+1] = cb end
    function uimanager:unschedule(cb)
        for i=#f.queue,1,-1 do if f.queue[i] == cb then table.remove(f.queue,i) end end
    end
    function uimanager:show(widget) f.messages[#f.messages+1] = widget.text end
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
        ["ui/widget/infomessage"] = {new=function(_,t)return t end},
        ["datastorage"] = {getDataDir=function() return f.root end,getSettingsDir=function() return f.root.."/settings" end},
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
    function f:reader(name, annotations)
        local path=self.root.."/"..name..".epub"
        local existing=io.open(path,"rb")
        if existing then existing:close()
        else local h=assert(io.open(path,"wb"));h:write(name);h:close() end
        local ui={
            document={file=path,getCoverPageImage=function()
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
    local path=store.dir.."/my-photo.png"
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
test("Poster places excerpts above a lower-left album and white book title on the black footer",function()
    local layout=real_dofile(TEST_ROOT.."/liuju_layout.lua")
    for _,size in ipairs({{1072,1448},{600,800},{1448,1072}}) do
        local l=layout.for_screen(size[1],size[2])
        eq(l.footer.x,0);eq(l.footer.w,l.width);eq(l.footer.y+l.footer.h,l.height)
        assert(l.body.y<l.height*0.25)
        assert(l.body.y+l.body.h<l.album.y)
        assert(l.body.y+l.body.h+l.date_gap+math.ceil(l.date_size*1.48)<l.album.y)
        assert(l.album.x<l.width*0.25 and l.album.x+l.album.w<l.title.x)
        assert(l.title.y>=l.footer.y and l.title.y+l.title.h<=l.height)
        assert(l.album.y<l.footer.y and l.album.y+l.album.h>l.footer.y)
        eq(l.album.w,l.album.h)
    end
    local f=fixture();local a=f:reader("A",{annotation("正文在上方")});f:drain()
    local l=layout.for_screen(1072,1448)
    local title_seen,body_seen,footer_seen=false,false,false
    for _,paint in ipairs(f.painted_texts) do
        if paint.text=="测试书 A" and paint.x==l.title.x then
            eq(paint.options.gray,255);eq(paint.options.bgcolor,0)
            assert(paint.y>=l.footer.y);title_seen=true
        elseif paint.text=="正文在上方" then
            eq(paint.x,l.body.x);eq(paint.y,l.body.y);body_seen=true
        end
    end
    for _,rect in ipairs(f.rectangles) do
        if rect.x==0 and rect.y==l.footer.y and rect.w==l.width and rect.gray==0 then footer_seen=true end
    end
    assert(title_seen and body_seen and footer_seen)
end)
test("Production drawing adapter applies DPI once and preserves cover aspect ratio",function()
    local raw_size, image_args, image_freed
    package.loaded["device"]={screen={scaleBySize=function(_,value)return value*2 end}}
    package.loaded["ffi/blitbuffer"]={Color8=function(v)return v end,COLOR_WHITE=255}
    package.loaded["ui/font"]={getFace=function(_,name,size)raw_size=size;return{size=size*2}end}
    package.loaded["ui/widget/textboxwidget"]={new=function(_,args)return args end}
    package.loaded["ui/widget/imagewidget"]={new=function(_,args)
        image_args=args
        return{paintTo=function()end,free=function()image_freed=true end}
    end}
    local draw=real_dofile(TEST_ROOT.."/liuju_draw.lua")
    local widget=draw:text("文字",772,46)
    eq(raw_size,23);eq(widget.face.size,46);eq(widget.height,nil,"no native clipping height")
    local white=draw:text("白字书名",572,40,{gray=255,bgcolor=0})
    eq(white.fgcolor,255);eq(white.bgcolor,0)
    assert(draw:cover({}, {getWidth=function()return 420 end,getHeight=function()return 600 end},
        {x=146,y=181,w=180,h=256}))
    eq(image_args.width,179);eq(image_args.height,256)
    eq(image_args.image_disposable,false);assert(image_freed)
end)
print(string.format("%d regression scenarios passed",test_count))
