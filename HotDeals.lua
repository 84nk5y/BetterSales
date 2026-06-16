HotDealsMixin = {}

function HotDealsMixin:OnLoad()
    self.bagData = {}
    self.updatePending = false

    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", self.StartMoving)
    self:SetScript("OnDragStop", self.StopMovingOrSizing)

    self:RegisterEvent("ADDON_LOADED")
    self:RegisterEvent("BAG_UPDATE_DELAYED")
end

function HotDealsMixin:TriggerUpdate()
    if self.updatePending then return end

    self.updatePending = true
    C_Timer.After(0.1, function()
        self.updatePending = false
        self:UpdateList()
    end)
end

function HotDealsMixin:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "HotDeals" then
            if Auctionator and Auctionator.API and Auctionator.API.v1 then
                -- Hook into Auctionator database complete signals
                Auctionator.API.v1.RegisterForDBUpdate("BetterSales", function()
                    self:TriggerUpdate()
                end)
            else
                print("|cffB0C4DE[BetterSales]|r Auctionator API not found!")
            end
        end
    elseif self:IsVisible() then
        self:TriggerUpdate()
    end
end

function HotDealsMixin:GetAuctionatorCurrentPrice(itemLink)
    return tonumber(Auctionator.API.v1.GetAuctionPriceByItemLink("BetterSales", itemLink) or 0)
end

-- Extracts and calculates the baseline average from the latest 15 historical scans
function HotDealsMixin:GetAuctionatorInternalAverage(itemID, itemLink)
    if not Auctionator or not Auctionator.Database then return 0 end

    local itemKey = Auctionator.Utilities.BasicDBKeyFromLink(itemLink)

    return Auctionator.Database:GetMeanPrice(itemKey, 15) or 0
end

function HotDealsMixin:UpdateList()
    local container = ContinuableContainer:Create()
    local rawItems = {}

    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and info.hyperlink and not info.isBound then
                table.insert(rawItems, info)
                container:AddContinuable(Item:CreateFromItemID(info.itemID))
            end
        end
    end

    container:ContinueOnLoad(function()
        self:ProcessBagData(rawItems)
        self:RenderListElements()
    end)
end

function HotDealsMixin:ProcessBagData(rawItems)
    self.bagData = {}

    for _, info in ipairs(rawItems) do
        local id = info.itemID
        local link = info.hyperlink

        if not self.bagData[id] then
            local _, _, _, _, _, _, _, _, _, itemTexture, _, _, _, _, _, _, isCraftingReagent = C_Item.GetItemInfo(link)
            local craftingQualityInfo = isCraftingReagent and C_TradeSkillUI.GetItemReagentQualityInfo(id) or nil
            local currentPrice = self:GetAuctionatorCurrentPrice(link)
            local averagePrice = self:GetAuctionatorInternalAverage(id, link)
            local ratio = 0

            if averagePrice > 0 then
                ratio = ((currentPrice - averagePrice) / averagePrice) * 100
            end

            self.bagData[id] = {
                ID = id,
                name = info.itemName,
                locations = {},
                isCraftingReagent = isCraftingReagent,
                count = 0,
                quality = info.quality,
                craftingQualityInfo = craftingQualityInfo,
                texture = itemTexture,
                currentPrice = currentPrice,
                averagePrice = averagePrice,
                ratio = ratio
            }
        end

        table.insert(self.bagData[id].locations, { bag = info.bag, slot = info.slot })
        self.bagData[id].count = self.bagData[id].count + info.stackCount
    end
end

function HotDealsMixin:RenderListElements()
    local container = self.ScrollFrame.Content

    if not self.pool then
        self.pool = CreateFramePool("Button", container, "HotDealsEntryTemplate")
    end
    self.pool:ReleaseAll()

    local displayList = {}
    for _, item in pairs(self.bagData) do
        if item and item.ratio > 20 then
            table.insert(displayList, item)
        end
    end

    table.sort(displayList, function(a, b)
        if a.ratio ~= b.ratio then return a.ratio > b.ratio end`
        if a.name ~= b.name then return a.name < b.name end
        return (a.quality or 0) > (b.quality or 0)
    end)

    for i, data in ipairs(displayList) do
        local entry = self.pool:Acquire()

        entry.layoutIndex = i
        entry.item = data

        if data.quality then
            local r, g, b = C_Item.GetItemQualityColor(data.quality)
            entry.IconBorder:SetVertexColor(r, g, b)
            entry.IconBorder:Show()
        else
            entry.IconBorder:Hide()
        end

        entry.Icon:SetTexture(data.texture)

        if data.craftingQualityInfo then
            if not entry.QualityOverlay then
                entry.QualityOverlay = entry:CreateTexture(nil, "OVERLAY")
                entry.QualityOverlay:SetPoint("TOPLEFT", 6, 2)
                entry.QualityOverlay:SetDrawLayer("OVERLAY", 7)
            end

            entry.QualityOverlay:SetAtlas(data.craftingQualityInfo.iconInventory, TextureKitConstants.UseAtlasSize)
            entry.QualityOverlay:Show()
        elseif entry.QualityOverlay then
            entry.QualityOverlay:Hide()
        end

        entry.Name:SetText(data.name)
        entry.Ratio:SetText(string.format("+%.0f%%", data.ratio))

        if data.ratio < 25 then
            entry.Ratio:SetTextColor(0, 1, 0)     -- Green (< 25%)
        elseif data.ratio >= 25 and data.ratio < 50 then
            entry.Ratio:SetTextColor(1, 1, 0)     -- Yellow (>= 25% and < 50%)
        elseif data.ratio >= 50 and data.ratio < 75 then
            entry.Ratio:SetTextColor(1, 0.5, 0)   -- Orange (>= 50% and < 75%)
        else
            entry.Ratio:SetTextColor(1, 0, 0)     -- Red (>= 75%)
        end

        entry:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
            GameTooltip:AddLine(GetMoneyString(self.item.currentPrice, true) .. "  vs  " .. GetMoneyString(self.item.averagePrice, true), 1, 1, 1)
            GameTooltip:Show()
        end)

        entry:SetScript("OnLeave", GameTooltip_Hide)
        entry:Show()
    end

    container:Layout()
    container:Show()

    self.ScrollFrame:UpdateScrollChildRect()
end