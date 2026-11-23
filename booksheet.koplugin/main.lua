--[[--
The Booksheet: a one-page paper of book news for KOReader.

@module koplugin.Booksheet
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- Loaded on first open, so a damaged file shows a message instead of silently
-- removing The Booksheet from the Tools menu.
local Card, Catalog, Fetch, Parse, Settings, Sheet, Store

local function loadModules()
    if Store then return true end
    local ok, err = pcall(function()
        local card, catalog, fetch = require("booksheet_card"), require("booksheet_catalog"), require("booksheet_fetch")
        local parse, settings, sheet = require("booksheet_parse"), require("booksheet_settings"), require("booksheet_sheet")
        local store = require("booksheet_store")
        Card, Catalog, Fetch, Parse, Settings, Sheet, Store = card, catalog, fetch, parse, settings, sheet, store
    end)
    return ok, err
end

local HOUR = 3600
local CHART_LIMIT = 25
local SECTION_ITEMS = 10
local NEW_RELEASE_POOL = 100
local STEP_DELAY = 0.05
local CONTENT_SHARE = 0.6

-- Shared across plugin instances, because KOReader creates a new one when
-- moving between the file browser and a book.
local running = nil

local Booksheet = WidgetContainer:extend{
    name = "booksheet",
    is_doc_only = false,
}

function Booksheet:init()
    Dispatcher:registerAction("booksheet_open", {
        category = "none",
        event = "BooksheetOpen",
        title = _("The Booksheet"),
        general = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

function Booksheet:addToMainMenu(menu_items)
    menu_items.booksheet = {
        text = _("The Booksheet"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

function Booksheet:onBooksheetOpen()
    self:open()
    return true
end

function Booksheet:open()
    local loaded, err = loadModules()
    if not loaded then
        logger.warn("Booksheet: could not load", err)
        UIManager:show(InfoMessage:new{
            text = _("The Booksheet couldn't start. Try copying the plugin again.") .. "\n\n" .. tostring(err),
        })
        return
    end
    Store:init()
    if self.sheet then return end
    self.sheet = Sheet:new{ plugin = self, edition = Store:getEdition() }
    UIManager:show(self.sheet)
    if running then
        running.plugin = self
    elseif self:isDue() then
        UIManager:nextTick(function() self:update(false) end)
    end
end

function Booksheet:onSheetClosed(sheet)
    if self.sheet == sheet then self.sheet = nil end
end

function Booksheet:isDue()
    local edition = Store:getEdition()
    if not edition or not edition.updated_at then return true end
    local mode = Store:get("update_mode")
    if mode == "manual" then return false end
    -- Editions saved before reviews carried their own link need one refresh.
    local reviewed = edition.section_data and edition.section_data.reviewed
    if reviewed and reviewed.items[1] and reviewed.items[1].review_link == nil then return true end
    if mode == "daily" then
        return os.date("%Y%j", edition.updated_at) ~= os.date("%Y%j")
    end
    return os.time() - edition.updated_at >= HOUR
end

function Booksheet:openCard(item, from_list)
    UIManager:show(Card:new{ item = item, plugin = self, from_list = from_list })
end

function Booksheet:openSettings()
    self.settings_page = Settings:new{ plugin = self }
    UIManager:show(self.settings_page)
end

function Booksheet:onWantChanged()
    if self.sheet then self.sheet:redraw() end
    if self.settings_page then self.settings_page:redraw() end
    if self.want_menu then
        self.want_menu:switchItemTable(nil, self:wantItems(), -1)
    end
end

function Booksheet:onSettingsClosed(content_changed, sources_changed)
    self.settings_page = nil
    if not self.sheet then return end
    self.sheet:redraw()
    if sources_changed or (content_changed and self:isMissingSection()) then
        UIManager:nextTick(function() self:update(true) end)
    end
end

function Booksheet:isMissingSection()
    local edition = Store:getEdition() or {}
    local data = edition.section_data or {}
    for _, id in ipairs(Store:get("sections")) do
        if not data[id] then return true end
    end
    return false
end

function Booksheet:wantItems()
    local list = {}
    for _, book in ipairs(Store:get("want")) do
        list[#list + 1] = {
            text = book.author and book.author ~= "" and (book.title .. " · " .. book.author) or book.title,
            callback = function() self:openCard(book, true) end,
        }
    end
    if #list == 0 then
        list[1] = { text = _("Nothing saved yet"), dim = true }
    end
    return list
end

function Booksheet:openWantList()
    local menu
    menu = Menu:new{
        title = _("Want to read"),
        item_table = self:wantItems(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function()
            self.want_menu = nil
            UIManager:close(menu)
        end,
    }
    -- Menu closes itself after a choice. The list should stay open behind the card.
    menu.onMenuSelect = function(_, item)
        if item.callback then item.callback() end
        return true
    end
    self.want_menu = menu
    UIManager:show(menu)
end

--- Starts an update, turning on Wi-Fi according to the reader's KOReader setting.
function Booksheet:update(forced)
    if running then return end
    if not NetworkMgr:isOnline() and self.sheet then
        self.sheet:setStatus({ state = "offline" })
    end
    NetworkMgr:runWhenOnline(function()
        if not running then self:startUpdate(forced) end
    end)
end

local function copyTable(source)
    local out = {}
    for k, v in pairs(source or {}) do out[k] = v end
    return out
end

local function shortDate(epoch)
    if not epoch then return nil end
    return os.date("!%b ", epoch) .. tonumber(os.date("!%d", epoch))
end

function Booksheet:buildJobs(state)
    local jobs = {}
    local slots = Store:get("sections")
    local chosen = {}
    for _, id in ipairs(slots) do chosen[id] = true end

    for _, id in ipairs(slots) do
        local section = Catalog.find(Catalog.sections, id)
        if section and section.genre then
            jobs[#jobs + 1] = function()
                local body = Fetch.get(Catalog.chartUrl(section.genre, CHART_LIMIT))
                local ok, decoded = pcall(json.decode, body or "")
                if not ok then return end
                local books = Parse.chart(decoded)
                if #books == 0 then return end
                local items = {}
                for i = 1, math.min(SECTION_ITEMS, #books) do
                    local book = books[i]
                    book.kind = "book"
                    book.sub = book.author
                    book.meta = ("No. %d in %s on Apple Books"):format(i, section.title:lower())
                    items[i] = book
                end
                state.edition.section_data[id] = { items = items }
                state.succeeded = true
            end
        end
    end

    if chosen.just_out then
        jobs[#jobs + 1] = function()
            local body = Fetch.get(Catalog.chartUrl(nil, NEW_RELEASE_POOL))
            local ok, decoded = pcall(json.decode, body or "")
            if not ok then return end
            local items = Parse.justOut(Parse.chart(decoded), state.now, SECTION_ITEMS)
            if #items == 0 then return end
            for _, book in ipairs(items) do
                local date = shortDate(book.release)
                book.kind = "book"
                book.sub = date and (book.author .. " · " .. date) or book.author
                book.meta = date and ("Released " .. date) or nil
            end
            state.edition.section_data.just_out = { items = items }
            state.succeeded = true
        end
    end

    local sources = Store:get("sources")
    for _, source in ipairs(Catalog.sources) do
        local wants_news = sources[source.id]
        local wants_reviews = source.id == "nyt" and chosen.reviewed
        if wants_news or wants_reviews then
            jobs[#jobs + 1] = function()
                local xml = Fetch.get(source.url)
                if not xml then return end
                local articles = Parse.feed(xml)
                if #articles == 0 then return end
                state.succeeded = true
                if wants_news then
                    state.got_news = true
                    for _, article in ipairs(articles) do
                        article.source = source.id
                        article.domain = source.domain
                        state.articles[#state.articles + 1] = article
                    end
                end
                if wants_reviews then
                    local reviews = {}
                    for _, article in ipairs(articles) do
                        local title, author = Parse.reviewedBook(article.title)
                        if title and article.date and state.now - article.date <= 7 * 86400 then
                            reviews[#reviews + 1] = {
                                id = "review:" .. title, kind = "book", title = title, author = author,
                                sub = author .. " · " .. source.domain,
                                meta = "Reviewed on " .. source.domain,
                                review_link = article.link or false,
                                review_domain = source.domain,
                                summary = article.summary, date = article.date,
                            }
                        end
                    end
                    table.sort(reviews, function(a, b) return a.date > b.date end)
                    for i = #reviews, SECTION_ITEMS + 1, -1 do reviews[i] = nil end
                    if #reviews > 0 then
                        state.edition.section_data.reviewed = { items = reviews }
                    end
                end
            end
        end
    end

    jobs[#jobs + 1] = function()
        if state.got_news then
            state.edition.lead = nil
            state.edition.news = Parse.latestNews(state.articles, state.now)
        end
        state.articles = nil
    end
    return jobs
end

local function visibleBooks(edition)
    local books = {}
    for _, id in ipairs(Store:get("sections")) do
        local entry = edition.section_data[id]
        for _, item in ipairs(entry and entry.items or {}) do
            if item.kind == "book" then books[#books + 1] = item end
        end
    end
    return books
end

function Booksheet:startUpdate()
    local previous = Store:getEdition() or {}
    local state = {
        plugin = self,
        now = os.time(),
        articles = {},
        succeeded = false,
        edition = {
            updated_at = previous.updated_at,
            lead = previous.lead,
            news = previous.news,
            section_data = copyTable(previous.section_data),
        },
    }
    running = state
    local jobs = self:buildJobs(state)
    local index, covers_queued = 0, false
    -- Covers are only known once the lists arrive, so they get their own stretch
    -- of the bar. Otherwise adding them would make the bar jump backward.
    local content_jobs = #jobs
    local content_share = Store:get("covers") and CONTENT_SHARE or 1

    local function fraction()
        if index <= content_jobs then
            return content_share * index / math.max(content_jobs, 1)
        end
        local cover_jobs = math.max(#jobs - content_jobs, 1)
        return content_share + (1 - content_share) * (index - content_jobs) / cover_jobs
    end

    local function progress()
        local plugin = state.plugin
        if plugin and plugin.sheet then
            plugin.sheet:setStatus({ state = "updating", fraction = fraction() })
        end
    end

    local function finish()
        running = nil
        local plugin = state.plugin
        if state.succeeded then
            state.edition.updated_at = state.now
            Store:setEdition(state.edition)
            local ok, err = pcall(function() Store:pruneCovers(visibleBooks(state.edition)) end)
            if not ok then logger.warn("Booksheet: could not prune covers", err) end
            if plugin and plugin.sheet then plugin.sheet:setEdition(state.edition) end
        elseif plugin and plugin.sheet then
            plugin.sheet:setStatus({ state = "offline" })
        end
    end

    local function step()
        index = index + 1
        if index > #jobs and not covers_queued then
            covers_queued = true
            if state.succeeded and Store:get("covers") then
                for _, book in ipairs(visibleBooks(state.edition)) do
                    if book.cover and not Store:hasCover(book) then
                        jobs[#jobs + 1] = function()
                            Fetch.toFile(book.cover, Store:coverPath(book))
                        end
                    end
                end
            end
        end
        if index > #jobs then
            finish()
            return
        end
        local ok, err = pcall(jobs[index])
        if not ok then logger.warn("Booksheet: update step failed", err) end
        progress()
        UIManager:scheduleIn(STEP_DELAY, step)
    end

    progress()
    UIManager:scheduleIn(STEP_DELAY, step)
end

return Booksheet
