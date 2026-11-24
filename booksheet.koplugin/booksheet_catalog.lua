--[[--
Everything the Booksheet can show: sections, news sources and phone destinations.
]]

local Catalog = {}

-- Order here is the order in the section chooser, so it never jumps around.
Catalog.sections = {
    { id = "just_out", title = "Just out", heading = "Just out" },
    { id = "reviewed", title = "Reviewed this week", heading = "Reviewed this week" },
    { id = "scifi", title = "Science fiction", heading = "Top science fiction", genre = 10063 },
    { id = "fantasy", title = "Fantasy", heading = "Top fantasy", genre = 10044 },
    { id = "mystery", title = "Mysteries and thrillers", heading = "Top mysteries", genre = 9032 },
    { id = "historical", title = "Historical fiction", heading = "Top historical fiction", genre = 10047 },
    { id = "horror", title = "Horror", heading = "Top horror", genre = 10048 },
    { id = "literary", title = "Literary fiction", heading = "Top literary fiction", genre = 10049 },
    { id = "romance", title = "Romance", heading = "Top romance", genre = 9003 },
    { id = "biography", title = "Biography", heading = "Top biography", genre = 9008 },
    { id = "history", title = "History", heading = "Top history", genre = 9015 },
    { id = "science", title = "Science and nature", heading = "Top science", genre = 9019 },
    { id = "truecrime", title = "True crime", heading = "Top true crime", genre = 10149 },
    { id = "politics", title = "Politics", heading = "Top politics", genre = 9034 },
    { id = "business", title = "Business", heading = "Top business", genre = 9009 },
    { id = "comics", title = "Comics and manga", heading = "Top comics", genre = 9026 },
}

Catalog.sources = {
    { id = "nyt", title = "The New York Times", note = "nytimes.com", domain = "nytimes.com",
      url = "https://rss.nytimes.com/services/xml/rss/nyt/Books/Review.xml" },
    { id = "npr", title = "NPR Books", note = "npr.org", domain = "npr.org",
      url = "https://feeds.npr.org/1032/rss.xml" },
    { id = "lithub", title = "Lit Hub", note = "lithub.com", domain = "lithub.com",
      url = "https://lithub.com/feed/" },
    { id = "bookriot", title = "Book Riot", note = "bookriot.com", domain = "bookriot.com",
      url = "https://bookriot.com/feed/" },
    { id = "locus", title = "Locus", note = "Sci-fi and fantasy publishing", domain = "locusmag.com",
      url = "https://locusmag.com/feed/" },
    { id = "reactor", title = "Reactor", note = "Sci-fi and fantasy book reviews", domain = "reactormag.com",
      url = "https://reactormag.com/tag/book-reviews/feed/" },
    { id = "ebookreader", title = "The eBook Reader", note = "E-reader news and sales",
      domain = "the-ebook-reader.com", url = "https://blog.the-ebook-reader.com/feed/" },
}

-- referral: text appended to the link once a referral program is set up.
-- While it is empty, no commission disclosure is shown.
Catalog.stores = {
    { id = "bookshop", title = "Bookshop.org", url = "https://bookshop.org/search?keywords=%s", referral = "" },
    { id = "kobo", title = "Kobo", url = "https://www.kobo.com/us/en/search?query=%s", referral = "" },
    { id = "amazon", title = "Amazon", url = "https://www.amazon.com/s?k=%s", referral = "" },
    { id = "apple", title = "Apple Books", url = "https://books.apple.com/us/search?term=%s", referral = "" },
    { id = "libby", title = "Libby", url = "https://www.overdrive.com/search?q=%s", referral = "" },
    { id = "worldcat", title = "A library (WorldCat)", url = "https://search.worldcat.org/search?q=%s", referral = "" },
}

Catalog.update_modes = {
    { id = "open", title = "On open", note = "When you open it, at most once an hour" },
    { id = "daily", title = "Once a day", note = "Checks the first time you open it each day" },
    { id = "manual", title = "Manual only", note = "Updates only when you tap Update now" },
}

Catalog.text_sizes = {
    { id = "small", title = "Small", scale = 0.9 },
    { id = "medium", title = "Medium", scale = 1 },
    { id = "large", title = "Large", scale = 1.15 },
}

function Catalog.find(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then return entry end
    end
end

function Catalog.chartUrl(genre, limit)
    if genre then
        return ("https://itunes.apple.com/us/rss/toppaidebooks/limit=%d/genre=%d/json"):format(limit, genre)
    end
    return ("https://itunes.apple.com/us/rss/toppaidebooks/limit=%d/json"):format(limit)
end

local function urlEncode(text)
    return (text:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

--- Accepts a library name or a pasted Libby address.
function Catalog.libbyKey(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return text:match("/library/([%w%-_]+)") or text:match("/search/([%w%-_]+)") or text:match("^[%w%-_]+$") or ""
end

--- Where a book's QR code goes.
function Catalog.storeUrl(store_id, book, libby_key)
    local store = Catalog.find(Catalog.stores, store_id) or Catalog.stores[1]
    if store.id == "libby" then
        local query = urlEncode(book.author and book.author ~= "" and (book.title .. " " .. book.author) or book.title)
        if libby_key and libby_key ~= "" then
            return ("https://libbyapp.com/search/%s/search/query-%s/page-1"):format(libby_key, query), store
        end
        -- Libby links need a library. OverDrive, its parent service, can search without one.
        return "https://www.overdrive.com/search?q=" .. query, { title = "OverDrive", referral = "" }
    end
    if store.id == "apple" and book.link then
        return book.link .. store.referral, store
    end
    local query = book.title
    if book.author and book.author ~= "" then
        query = query .. " " .. book.author
    end
    local encoded = urlEncode(query)
    local url = store.url:gsub("%%s", function() return encoded end)
    return url .. store.referral, store
end

--- For reviews saved before they carried a direct link.
function Catalog.reviewSearchUrl(book)
    return "https://www.nytimes.com/search?query=" .. urlEncode(book.title .. " book review")
end

return Catalog
