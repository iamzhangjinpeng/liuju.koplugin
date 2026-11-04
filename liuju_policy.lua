-- A settings lease: yielding to a later user/plugin choice prevents screen
-- providers from repeatedly overwriting one another.
local Policy = {}
Policy.__index = Policy
Policy.ENABLED = "liuju_enabled"
Policy.LEASE = "liuju_screensaver_lease"
local keys = {
    "screensaver_type", "screensaver_dir", "screensaver_document_cover",
    "screensaver_stretch_images", "screensaver_show_message",
    "screensaver_cycle_images_alphabetically", "screensaver_max_files",
}
local target_keys = { random_image = "screensaver_dir", document_cover = "screensaver_document_cover" }

function Policy.new(settings)
    return setmetatable({ settings = settings }, Policy)
end

function Policy:enabled()
    return self.settings:readSetting(self.ENABLED) ~= false
end

function Policy:_matches(lease)
    if type(lease) ~= "table" or lease.version ~= 1 or type(lease.applied) ~= "table" then return false end
    for key, value in pairs(lease.applied) do
        if self.settings:readSetting(key) ~= value then return false end
    end
    return true
end

function Policy:owns()
    local lease = self.settings:readSetting(self.LEASE)
    return self:enabled() and self:_matches(lease) and next(lease.applied) ~= nil
end

function Policy:_restore_owned(lease)
    if type(lease) ~= "table" or lease.version ~= 1
            or type(lease.backup) ~= "table" or type(lease.applied) ~= "table" then return end
    local current_type = self.settings:readSetting("screensaver_type")
    local target_key = target_keys[current_type]
    local changed_active_target = target_key and self.settings:readSetting(target_key) ~= lease.applied[target_key]
    for _, key in ipairs(keys) do
        local applied, saved = lease.applied[key], lease.backup[key]
        if applied ~= nil and saved and self.settings:readSetting(key) == applied
                and (key ~= "screensaver_type" or not changed_active_target) then
            if saved.present then self.settings:saveSetting(key, saved.value)
            else self.settings:delSetting(key) end
        end
    end
end

function Policy:check()
    if not self:enabled() then return false end
    local lease = self.settings:readSetting(self.LEASE)
    if lease and not self:_matches(lease) then
        self:_restore_owned(lease)
        self.settings:delSetting(self.LEASE)
        self.settings:saveSetting(self.ENABLED, false)
        self.settings:flush()
        return false
    end
    return true
end

function Policy:apply(target)
    if not self:check() then return false end
    local lease = self.settings:readSetting(self.LEASE)
    if not lease then
        lease = { version = 1, backup = {}, applied = {} }
        for _, key in ipairs(keys) do
            local value = self.settings:readSetting(key)
            lease.backup[key] = { present = value ~= nil, value = value }
        end
        -- Persist recovery data before changing any system setting.
        self.settings:saveSetting(self.LEASE, lease)
        self.settings:flush()
    end
    local applied = {
        screensaver_type = target.image and "document_cover" or "random_image",
        screensaver_dir = target.dir,
        screensaver_document_cover = target.image or "",
        screensaver_stretch_images = true,
        screensaver_show_message = false,
        screensaver_cycle_images_alphabetically = false,
        screensaver_max_files = math.max(256, tonumber(target.count) or 0,
            tonumber(lease.backup.screensaver_max_files.value) or 0),
    }
    if next(lease.applied) and self:_matches{ version = 1, applied = applied } then return true end
    lease.applied = applied
    self.settings:saveSetting(self.LEASE, lease)
    for key, value in pairs(applied) do self.settings:saveSetting(key, value) end
    self.settings:flush()
    return true
end

function Policy:enable()
    self.settings:saveSetting(self.ENABLED, true)
    self.settings:flush()
end

function Policy:restore(disable)
    local lease = self.settings:readSetting(self.LEASE)
    if not lease and not disable then return end
    self:_restore_owned(lease)
    self.settings:delSetting(self.LEASE)
    if disable then self.settings:saveSetting(self.ENABLED, false) end
    self.settings:flush()
end
return Policy
