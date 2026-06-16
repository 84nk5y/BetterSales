local addonName, _ = ...

HotDealsMixin = {}

function HotDealsMixin:OnLoad()
    self.bagData = {}
    self.updatePending = false
    self.rendering = false
    self.manualClose = false

    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", self.StartMoving)
    self:SetScript("OnDragStop", self.StopMovingOrSizing)

    self:RegisterEvent("ADDON_LOADED")
    self:RegisterEvent("BAG_UPDATE_DELAYED")

    if self.CloseButton then
        self.CloseButton:HookScript("OnClick", function()
            self:OnClose()
        end)
    end
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
        local addonLoaded = ...
        if addonLoaded == addonName then
            if Auctionator and Auctionator.API and Auctionator.API.v1 then
                Auctionator.API.v1.RegisterForDBUpdate(addonName, function()
                    self:TriggerUpdate()
                end)
            else
                print("|cffB0C4DE[BetterSales]|r Auctionator API not found!")
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" and not self.manualClose then
        self:TriggerUpdate()
    end
end

function HotDealsMixin:OnClose()
    self.manualClose = true
    self:Hide()
end

function HotDealsMixin:GetAuctionatorCurrentPrice(itemLink)
    return tonumber(Auctionator.API.v1.GetAuctionPriceByItemLink(addonName, itemLink) or 0)
end

-- Extracts and calculates the baseline average from the latest 15 historical scans
function HotDealsMixin:GetAuctionatorInternalAverage(itemID, itemLink)
    if not Auctionator or not Auctionator.Database then return 0 end

    local itemKey = Auctionator.Utilities.BasicDBKeyFromLink(itemLink)

    return Auctionator.Database:GetMeanPrice(itemKey, 15) or 0
end

function HotDealsMixin:UpdateList()
    local container = ContinuableContainer:Create()

    local uniqueBagItems = {}

    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and info.hyperlink and not info.isBound then
                local link = info.hyperlink

                if not uniqueBagItems[link] then
                    uniqueBagItems[link] = {
                        itemID = info.itemID,
                        itemName = info.itemName,
                        quality = info.quality,
                        hyperlink = link,
                        stackCount = 0,
                        locations = {}
                    }
                    container:AddContinuable(Item:CreateFromItemID(info.itemID))
                end

                table.insert(uniqueBagItems[link].locations, { bag = bag, slot = slot })
                uniqueBagItems[link].stackCount = uniqueBagItems[link].stackCount + info.stackCount
            end
        end
    end

    container:ContinueOnLoad(function()
        self:ProcessBagData(uniqueBagItems)

        if self.rendering then return end

        self.rendering = true
        C_Timer.After(0.1, function()
            self.rendering = false
            self:RenderListElements()
        end)
    end)
end

function HotDealsMixin:ProcessBagData(uniqueBagItems)
    self.bagData = {}

    for link, info in pairs(uniqueBagItems) do
        local id = info.itemID

        local _, _, _, _, _, _, _, _, _, itemTexture, _, _, _, _, _, _, isCraftingReagent = C_Item.GetItemInfo(link)
        local craftingQualityInfo = isCraftingReagent and C_TradeSkillUI.GetItemReagentQualityInfo(id) or nil
        local currentPrice = self:GetAuctionatorCurrentPrice(link)
        local averagePrice = self:GetAuctionatorInternalAverage(id, link)
        local ratio = 0

        if averagePrice > 0 then
            ratio = ((currentPrice - averagePrice) / averagePrice) * 100
        end

        self.bagData[link] = {
            ID = id,
            name = info.itemName,
            locations = info.locations,
            isCraftingReagent = isCraftingReagent,
            count = info.stackCount,
            quality = info.quality,
            craftingQualityInfo = craftingQualityInfo,
            texture = itemTexture,
            currentPrice = currentPrice,
            averagePrice = averagePrice,
            ratio = ratio
        }
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

    if not next(displayList) then
        self:Hide()
        return
    elseif not self.manualClose then
        self:Show()
    end

    table.sort(displayList, function(a, b)
        if a.ratio ~= b.ratio then return a.ratio > b.ratio end
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