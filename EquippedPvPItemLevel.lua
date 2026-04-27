--[[
  Equipped PvP Item Level (Retail)

  Install: copy this folder to World of Warcraft\_retail_\Interface\AddOns\
  Bump ## Interface: in the .toc if the addon does not load after a patch.

  Behavior:
  - Tooltip: your PvP iLvl from the game API when available.
  - Other players: inspect gives equipped; PvP has no API — ~ guess if inspect shows likely PvP gear (Item API, ilvl-detail PvP fields, stat keys, then name+expansion heuristics). Otherwise PvP shows N/A.
  - Character panel: same line for your character.
  - Other players: may require a successful inspect; tooltip refreshes after INSPECT_READY.
  - Colors follow WoW item-quality palette (common white through legendary orange) from equipped/PvP values.
  - Debug: /epvpilvl help | /epvpilvl snapshot | /epvpilvl debug on|off | /epvpilvl verbose on|off
]]

--- Matches ## Version in .toc (GetAddOnMetadata when available).
local ADDON_VERSION = "1.3.7"
local ADDON_NAME = "EquippedPvPItemLevel"

local EquippedPvPItemLevel = {}
_G.EquippedPvPItemLevel = EquippedPvPItemLevel

local cacheByGUID = {}
local lastInspectAtByGUID = {}
local INSPECT_COOLDOWN_SEC = 1.6
--- For other players only: guess PvP ilvl as eq * ratio, where ratio comes from your GetAverageItemLevel() PvP/equipped.
local pvpEquippedRatioForEstimate = 1

local function GetAddOnVersionMeta()
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    local v = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    if v and v ~= "" then
      return v
    end
  end
  if GetAddOnMetadata then
    local v = GetAddOnMetadata(ADDON_NAME, "Version")
    if v and v ~= "" then
      return v
    end
  end
  return ADDON_VERSION
end

local function Trim(s)
  if not s then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Dbg(msg, ...)
  local sv = rawget(_G, "EquippedPvPItemLevelSV")
  if not sv or not sv.debug then
    return
  end
  local out = msg
  if select("#", ...) > 0 then
    out = string.format(msg, ...)
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[EPvPILVL]|r " .. out, 1, 1, 1)
end

local function DbgVerbose(msg, ...)
  local sv = rawget(_G, "EquippedPvPItemLevelSV")
  if not sv or not sv.debug or not sv.debugVerbose then
    return
  end
  local out = msg
  if select("#", ...) > 0 then
    out = string.format(msg, ...)
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[EPvPILVL]|r " .. out, 1, 1, 1)
end

-- Post Midnight stat/ilvl squish: endgame Myth track tops out around ~289 (6/6). Tracks are roughly
-- Adventurer ~224-237, Veteran ~237-250, Champion ~250-263, Hero ~263-276, Myth ~276-289. Thresholds
-- below step up by track so orange matches top-tier myth gear. Adjust after future squishes or seasons.
local ILVL_QUALITY_UNCOMMON_AT = 235
local ILVL_QUALITY_RARE_AT = 250
local ILVL_QUALITY_EPIC_AT = 263
local ILVL_QUALITY_LEGENDARY_AT = 276

local lastTooltipUnit

local charFontString
local charAnchor

local UpdateCharacterPanel

local function FormatMaybeNumber(value, approx)
  if value == nil then
    return "N/A"
  end
  if type(value) ~= "number" then
    return "N/A"
  end
  local s = string.format("%.1f", value)
  if approx then
    return "~" .. s
  end
  return s
end

local IQ = Enum and Enum.ItemQuality
local IQ_COMMON = IQ and IQ.Common or 1
local IQ_UNCOMMON = IQ and IQ.Uncommon or 2
local IQ_RARE = IQ and IQ.Rare or 3
local IQ_EPIC = IQ and IQ.Epic or 4
local IQ_LEGENDARY = IQ and IQ.Legendary or 5
local IQ_POOR = IQ and IQ.Poor or 0

--- @return integer wowItemQualityIndex (Common..Legendary)
local function GetItemLevelQualityIndex(ilvl)
  if type(ilvl) ~= "number" then
    return IQ_COMMON
  end
  if ilvl < ILVL_QUALITY_UNCOMMON_AT then
    return IQ_COMMON
  end
  if ilvl < ILVL_QUALITY_RARE_AT then
    return IQ_UNCOMMON
  end
  if ilvl < ILVL_QUALITY_EPIC_AT then
    return IQ_RARE
  end
  if ilvl < ILVL_QUALITY_LEGENDARY_AT then
    return IQ_EPIC
  end
  return IQ_LEGENDARY
end

local function GetQualityColorRGB(qualityIndex)
  local entry = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[qualityIndex]
  if not entry then
    return 1, 1, 1
  end
  if entry.color then
    return entry.color:GetRGB()
  end
  if entry.GetRGB then
    return entry:GetRGB()
  end
  if entry.r then
    return entry.r, entry.g, entry.b
  end
  return 1, 1, 1
end

local function GetQualityHexPrefix(qualityIndex)
  local entry = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[qualityIndex]
  if entry and entry.color and entry.color.GenerateHexColor then
    local hex = entry.color:GenerateHexColor()
    if type(hex) == "string" and #hex == 8 then
      return "|c" .. hex
    end
  end
  local r, g, b = GetQualityColorRGB(qualityIndex)
  return string.format("|cFF%02X%02X%02X", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

--- Wrap display text (number or N/A) using quality colors; N/A uses poor-tier grey.
local function ColorizeIlvlToken(display, ilvlForBand)
  if display == "N/A" then
    if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[IQ_POOR] then
      return GetQualityHexPrefix(IQ_POOR) .. display .. "|r"
    end
    return "|cFF808080" .. display .. "|r"
  end
  local q = GetItemLevelQualityIndex(ilvlForBand)
  return GetQualityHexPrefix(q) .. display .. "|r"
end

local function FormatLineColored(equipped, pvp, pvpIsApprox)
  local eqDisp = FormatMaybeNumber(equipped, false)
  local pvpDisp = FormatMaybeNumber(pvp, pvpIsApprox == true)
  return string.format(
    "Equipped iLvl: %s | PvP iLvl: %s",
    ColorizeIlvlToken(eqDisp, equipped),
    ColorizeIlvlToken(pvpDisp, pvp)
  )
end

local function N(x)
  local v = tonumber(x)
  if not v or v <= 0 then
    return nil
  end
  return v
end

local function LinkEffectiveItemLevel(itemLink)
  if not itemLink or itemLink == "" then
    return nil
  end
  local ok, ilvl = pcall(function()
    if C_Item and C_Item.GetDetailedItemLevelInfo then
      local t = C_Item.GetDetailedItemLevelInfo(itemLink)
      if type(t) == "table" then
        local v = t.effectiveItemLevel or t.itemLevel or t.currentItemLevel
        return N(v)
      end
      if type(t) == "number" then
        return N(t)
      end
    end
    if GetDetailedItemLevelInfo then
      local eff = select(1, GetDetailedItemLevelInfo(itemLink))
      return N(eff)
    end
    return nil
  end)
  if ok then
    return ilvl
  end
  return nil
end

local EQUIPMENT_INVENTORY_SLOTS = {
  INVSLOT_HEAD,
  INVSLOT_NECK,
  INVSLOT_SHOULDER,
  INVSLOT_CHEST,
  INVSLOT_WAIST,
  INVSLOT_LEGS,
  INVSLOT_FEET,
  INVSLOT_WRIST,
  INVSLOT_HANDS,
  INVSLOT_FINGER1,
  INVSLOT_FINGER2,
  INVSLOT_TRINKET1 or 13,
  INVSLOT_TRINKET2 or 14,
  INVSLOT_BACK,
  INVSLOT_MAINHAND,
  INVSLOT_OFFHAND,
}

local function ItemLinkToItemId(link)
  if not link or link == "" then
    return nil
  end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

local function GetCurrentContentExpansionId()
  if type(EXPANSION_ID_CURRENT) == "number" then
    return EXPANSION_ID_CURRENT
  end
  if type(LE_EXPANSION_MIDNIGHT) == "number" then
    return LE_EXPANSION_MIDNIGHT
  end
  if type(LE_EXPANSION_WAR_WITHIN) == "number" then
    return LE_EXPANSION_WAR_WITHIN
  end
  return 10
end

local function GetItemExpacId(itemId)
  if not itemId then
    return nil
  end
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, r = pcall(C_Item.GetItemInfoInstant, itemId)
    if ok and type(r) == "table" then
      return N(r.expansionID) or N(r.expacID)
    end
    local ok2, exp = pcall(function()
      return select(15, C_Item.GetItemInfoInstant(itemId))
    end)
    if ok2 then
      return N(exp)
    end
  end
  if GetItemInfoInstant then
    local ok, exp = pcall(function()
      return select(15, GetItemInfoInstant(itemId))
    end)
    if ok then
      return N(exp)
    end
  end
  return nil
end

local function GetItemNameById(itemId)
  if not itemId then
    return nil
  end
  local name
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, r = pcall(C_Item.GetItemInfoInstant, itemId)
    if ok and type(r) == "table" then
      name = r.itemName or r.name
    elseif ok and type(r) == "string" and r ~= "" then
      name = r
    else
      local ok2, nm = pcall(function()
        return select(1, C_Item.GetItemInfoInstant(itemId))
      end)
      if ok2 and type(nm) == "string" and nm ~= "" then
        name = nm
      end
    end
  end
  if (not name or name == "") and GetItemInfoInstant then
    local ok, n = pcall(function()
      return select(1, GetItemInfoInstant(itemId))
    end)
    if ok and type(n) == "string" and n ~= "" then
      name = n
    end
  end
  return name
end

--- Some builds expose one of these on ItemMixin; not all are documented publicly.
local PVP_ITEM_MIXIN_METHODS = {
  "IsItemPvPItem",
  "IsPvPItem",
  "IsRatedPvpItem",
  "IsPvpItem",
}

local function ItemMixinIndicatesPvp(itemLink)
  if not Item or not itemLink or itemLink == "" then
    return false
  end
  local ok, isPvp = pcall(function()
    local item = Item:CreateFromItemLink(itemLink)
    if not item or item.IsItemEmpty and item:IsItemEmpty() then
      return false
    end
    for i = 1, #PVP_ITEM_MIXIN_METHODS do
      local m = PVP_ITEM_MIXIN_METHODS[i]
      local fn = item[m]
      if type(fn) == "function" and fn(item) == true then
        return true
      end
    end
    return false
  end)
  return ok and isPvp == true
end

local function ItemStatsTableSuggestsPvp(stats)
  if type(stats) ~= "table" then
    return false
  end
  for k in pairs(stats) do
    if type(k) == "string" then
      local l = string.lower(k)
      if string.find(l, "pvp", 1, true) or string.find(l, "arena", 1, true) then
        return true
      end
    end
  end
  return false
end

local function ItemStatsSuggestPvp(itemLink)
  if C_Item and C_Item.GetItemStats then
    local ok, stats = pcall(C_Item.GetItemStats, itemLink)
    if ok and ItemStatsTableSuggestsPvp(stats) then
      return true
    end
  end
  if GetItemStats then
    local ok, stats = pcall(GetItemStats, itemLink)
    if ok and ItemStatsTableSuggestsPvp(stats) then
      return true
    end
  end
  return false
end

local function DetailedItemLevelSuggestsPvp(itemLink)
  if not C_Item or not C_Item.GetDetailedItemLevelInfo then
    return false
  end
  local ok, t = pcall(C_Item.GetDetailedItemLevelInfo, itemLink)
  if not ok or type(t) ~= "table" then
    return false
  end
  local eff = N(t.effectiveItemLevel or t.itemLevel or t.currentItemLevel)
  for k, v in pairs(t) do
    if type(k) == "string" and type(v) == "number" then
      local kl = string.lower(k)
      if string.find(kl, "pvp", 1, true) then
        local pv = N(v)
        if pv and ((not eff) or math.abs(pv - eff) > 0.25) then
          return true
        end
      end
    end
  end
  return false
end

--- Tier names that are almost certainly current PvP naming (English); extend for your locale if needed.
local PVP_NAME_FRAGMENTS_STRICT = {
  "galactic",
  "thalassian",
}

--- Also match common English PvP tier words, but only if item expac matches current expansion (avoids old Gladiator xmog).
local PVP_NAME_FRAGMENTS_BROAD = {
  "gladiator",
  "aspirant",
  "warmonger",
  "combatant",
  "drakebreaker",
}

local function ItemNameHeuristicsSuggestPvp(itemLink)
  local itemId = ItemLinkToItemId(itemLink)
  if not itemId then
    return false
  end
  local name = GetItemNameById(itemId)
  if not name or name == "" then
    return false
  end
  local lower = string.lower(name)
  for i = 1, #PVP_NAME_FRAGMENTS_STRICT do
    if string.find(lower, PVP_NAME_FRAGMENTS_STRICT[i], 1, true) then
      return true
    end
  end
  local expItem = GetItemExpacId(itemId)
  local expCur = GetCurrentContentExpansionId()
  if expItem and expCur and expItem == expCur then
    for i = 1, #PVP_NAME_FRAGMENTS_BROAD do
      if string.find(lower, PVP_NAME_FRAGMENTS_BROAD[i], 1, true) then
        return true
      end
    end
  end
  return false
end

--- True if this item link is likely PvP gear for the ~ ilvl estimate gate (inspect-visible gear only).
local function ItemIsLikelyPvpGear(itemLink)
  if not itemLink or itemLink == "" then
    return false
  end
  if ItemMixinIndicatesPvp(itemLink) then
    return true
  end
  if ItemStatsSuggestPvp(itemLink) then
    return true
  end
  if DetailedItemLevelSuggestsPvp(itemLink) then
    return true
  end
  if ItemNameHeuristicsSuggestPvp(itemLink) then
    return true
  end
  return false
end

local function UnitQualifiesForPvpIlvlEstimate(unit)
  if not unit or not UnitExists(unit) then
    return false
  end
  for _, slot in ipairs(EQUIPMENT_INVENTORY_SLOTS) do
    if slot then
      local link = GetInventoryItemLink(unit, slot)
      if link and link ~= "" and ItemIsLikelyPvpGear(link) then
        return true
      end
    end
  end
  return false
end

--- Rough mean item level from visible inventory (player or post-inspect unit).
local function GetEquippedAverageFromItemLinks(unit)
  if not unit or not UnitExists(unit) then
    return nil
  end
  local sum, count = 0, 0
  for _, slot in ipairs(EQUIPMENT_INVENTORY_SLOTS) do
    if slot then
      local link = GetInventoryItemLink(unit, slot)
      local ilvl = LinkEffectiveItemLevel(link)
      if ilvl then
        sum = sum + ilvl
        count = count + 1
      end
    end
  end
  if count == 0 then
    return nil
  end
  return sum / count
end

local function CleanTooltipLineText(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
  text = text:gsub("|r", "")
  text = text:gsub("|H.-|h(.-)|h", "%1")
  text = text:gsub("%s+", " ")
  return Trim(text)
end

local function TooltipTextMentionsPvpScaling(lower)
  return string.find(lower, "pvp", 1, true)
    or string.find(lower, "arena", 1, true)
    or string.find(lower, "battleground", 1, true)
    or string.find(lower, "war mode", 1, true)
end

local function ExtractPvpItemLevelFromTooltipText(text)
  text = CleanTooltipLineText(text)
  if not text or text == "" then
    return nil
  end
  local lower = string.lower(text)
  if not TooltipTextMentionsPvpScaling(lower) then
    return nil
  end
  if not (string.find(lower, "item level", 1, true) or string.find(lower, "ilvl", 1, true)) then
    return nil
  end

  local value = N(lower:match("item level%s+to%s+(%d+%.?%d*)"))
    or N(lower:match("ilvl%s+to%s+(%d+%.?%d*)"))
    or N(lower:match("to%s+(%d+%.?%d*)"))
    or N(lower:match("item level%s+(%d+%.?%d*)"))
    or N(lower:match("ilvl%s+(%d+%.?%d*)"))
  return value
end

local function GetInventorySlotPvpItemLevel(unit, slot)
  if not C_TooltipInfo or not C_TooltipInfo.GetInventoryItem then
    return nil
  end
  local ok, data = pcall(C_TooltipInfo.GetInventoryItem, unit, slot)
  if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
    return nil
  end
  local best
  for _, line in ipairs(data.lines) do
    if type(line) == "table" then
      local left = ExtractPvpItemLevelFromTooltipText(line.leftText)
      local right = ExtractPvpItemLevelFromTooltipText(line.rightText)
      local combined
      if type(line.leftText) == "string" and type(line.rightText) == "string" then
        combined = ExtractPvpItemLevelFromTooltipText(line.leftText .. " " .. line.rightText)
      end
      local value = left or right or combined
      if value and (not best or value > best) then
        best = value
      end
    end
  end
  return best
end

--- Estimate the unit's PvP average by reading each inspected item tooltip.
--- PvP gear contributes its PvP-scaled item level; non-PvP gear contributes
--- normal item level because it does not gain a PvP bump.
local function GetPvpAverageFromInventoryTooltips(unit)
  if not unit or not UnitExists(unit) then
    return nil, false
  end
  local sum, count, foundPvpScaledSlot = 0, 0, false
  for _, slot in ipairs(EQUIPMENT_INVENTORY_SLOTS) do
    if slot then
      local link = GetInventoryItemLink(unit, slot)
      if link and link ~= "" then
        local normalIlvl = LinkEffectiveItemLevel(link)
        local pvpIlvl = GetInventorySlotPvpItemLevel(unit, slot)
        local slotIlvl = pvpIlvl or normalIlvl
        if slotIlvl then
          sum = sum + slotIlvl
          count = count + 1
          if pvpIlvl then
            foundPvpScaledSlot = true
          end
        end
      end
    end
  end
  if count == 0 or not foundPvpScaledSlot then
    return nil, false
  end
  return sum / count, true
end

--- Update scaling factor from your own character only (both values from Blizzard's average-ilvl APIs).
local function RefreshPvpEquippedRatio()
  local eq, pvp = nil, nil
  if GetAverageItemLevel then
    local ok, overall, equipped, pvpIlvl = pcall(GetAverageItemLevel)
    if ok then
      eq = N(equipped) or N(overall)
      pvp = N(pvpIlvl)
    end
  end
  if (not eq or not pvp) and C_PlayerInfo and C_PlayerInfo.GetAverageItemLevel then
    local ok, a, b, c = pcall(C_PlayerInfo.GetAverageItemLevel)
    if ok then
      if type(a) == "table" then
        local info = a
        eq = eq or N(info.avgItemLevelEquipped or info.equippedAvgItemLevel or info.equippedItemLevel or info.equippedItemLevelAverage)
        pvp = pvp or N(info.avgItemLevelPvP or info.pvpAvgItemLevel or info.pvpItemLevel or info.avgPvpItemLevel)
      elseif type(a) == "number" and type(b) == "number" and type(c) == "number" then
        eq = eq or N(b)
        pvp = pvp or N(c)
      elseif type(a) == "number" and type(b) == "number" then
        eq = eq or N(b)
      end
    end
  end
  if eq and pvp and eq > 0 then
    pvpEquippedRatioForEstimate = pvp / eq
  elseif eq and eq > 0 then
    pvpEquippedRatioForEstimate = 1
  end
end

--- @return number|nil equipped
--- @return number|nil pvpExact (nil when API does not provide an exact PvP value)
local function GetPlayerEquippedAndPvp()
  local eq, pvp

  if GetAverageItemLevel then
    local ok, overall, equipped, pvpIlvl = pcall(GetAverageItemLevel)
    if ok then
      eq = N(equipped) or N(overall)
      pvp = N(pvpIlvl)
    end
  end

  if (not eq or not pvp) and C_PlayerInfo and C_PlayerInfo.GetAverageItemLevel then
    local ok, a, b, c = pcall(C_PlayerInfo.GetAverageItemLevel)
    if ok then
      if type(a) == "table" then
        local info = a
        eq = eq or N(info.avgItemLevelEquipped or info.equippedAvgItemLevel or info.equippedItemLevel or info.equippedItemLevelAverage)
        pvp = pvp or N(info.avgItemLevelPvP or info.pvpAvgItemLevel or info.pvpItemLevel or info.avgPvpItemLevel)
      elseif type(a) == "number" and type(b) == "number" and type(c) == "number" then
        eq = eq or N(b)
        pvp = pvp or N(c)
      elseif type(a) == "number" and type(b) == "number" then
        eq = eq or N(b)
      end
    end
  end

  if not eq then
    eq = GetEquippedAverageFromItemLinks("player")
  end

  return eq, pvp
end

--- @return number|nil equipped, number|nil pvp, boolean pvpIsApprox
--- pvp uses exact inspect/API or parsed item tooltip PvP scaling when present.
--- If Blizzard does not expose PvP scaling for the inspected unit, omit PvP.
local function GetInspectEquippedAndPvp(unit)
  if not unit or not UnitExists(unit) then
    return nil, nil, false
  end

  local eq, pvp
  local pvpIsApprox = false

  if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
    local ok, v = pcall(C_PaperDollInfo.GetInspectItemLevel, unit)
    if ok then
      eq = N(v)
    end
  end

  if GetInspectAverageItemLevel then
    local ok, overall, equipped, pvpIlvl = pcall(GetInspectAverageItemLevel, unit)
    if ok then
      local apiEq = N(equipped) or N(overall)
      if apiEq then
        eq = eq or apiEq
      end
      pvp = pvp or N(pvpIlvl)
    end
  end

  if not eq then
    eq = GetEquippedAverageFromItemLinks(unit)
  end

  if not pvp then
    local tooltipPvp, tooltipHadPvp = GetPvpAverageFromInventoryTooltips(unit)
    if tooltipPvp then
      pvp = tooltipPvp
      pvpIsApprox = tooltipHadPvp == true
    end
  end

  return eq, pvp, pvpIsApprox
end

local function GetCached(guid)
  if not guid then
    return nil, nil, false
  end
  local row = cacheByGUID[guid]
  if not row then
    return nil, nil, false
  end
  return row.equipped, row.pvp, row.pvpApprox == true
end

local function SetCached(guid, equipped, pvp, pvpApprox)
  if not guid then
    return
  end
  cacheByGUID[guid] = {
    equipped = equipped,
    pvp = pvp,
    pvpApprox = pvpApprox == true,
  }
end

local function CanThrottleInspect(guid)
  local now = GetTime()
  local last = lastInspectAtByGUID[guid] or 0
  if (now - last) < INSPECT_COOLDOWN_SEC then
    return false
  end
  lastInspectAtByGUID[guid] = now
  return true
end

local function RequestInspectIfNeeded(unit)
  if not unit or not UnitExists(unit) then
    return
  end
  if UnitIsUnit(unit, "player") then
    return
  end
  if not CanInspect(unit, false) then
    return
  end

  local guid = UnitGUID(unit)
  if not guid then
    return
  end

  local eqNow, pvpNow, approxNow = GetInspectEquippedAndPvp(unit)
  if eqNow then
    SetCached(guid, eqNow, pvpNow, approxNow)
    return
  end

  if not CanThrottleInspect(guid) then
    return
  end

  NotifyInspect(unit)
end

local function GetDisplayedUnitToken(tooltip, tooltipData)
  if TooltipUtil and TooltipUtil.GetDisplayedUnit then
    local _, unit = TooltipUtil.GetDisplayedUnit(tooltip)
    if unit and UnitExists(unit) then
      return unit
    end
  end
  if tooltipData and tooltipData.guid and UnitTokenFromGUID then
    local token = UnitTokenFromGUID(tooltipData.guid)
    if token and UnitExists(token) then
      return token
    end
  end
  if tooltip.GetUnit then
    local _, unit = tooltip:GetUnit()
    if unit and UnitExists(unit) then
      return unit
    end
  end
  return nil
end

--- Mainline tooltips expose TextLeft1..N on the frame; fall back to global names.
local function GetTooltipTextLeftFS(tooltip, index)
  if not tooltip or not index then
    return nil
  end
  local fs = tooltip["TextLeft" .. index]
  if fs and fs.GetText then
    return fs
  end
  local tipName = tooltip.GetName and tooltip:GetName()
  if tipName then
    return _G[tipName .. "TextLeft" .. index]
  end
  return nil
end

local ILVL_LINE_MARKER = "Equipped iLvl:"
local ILVL_LINE_MARKER_LEGACY = "Equipped iLvl:"
local PVP_ILVL_LINE_MARKER = "PvP iLvl:"

local function FindTooltipIlvlLineFS(tooltip)
  if not tooltip or not tooltip.NumLines then
    return nil, nil
  end
  local num = tooltip:NumLines()
  if num < 1 then
    return nil, nil
  end
  local scanFrom = math.max(1, num - 6)
  for i = scanFrom, num do
    local fs = GetTooltipTextLeftFS(tooltip, i)
    if fs and fs.GetText then
      local t = fs:GetText()
      if
        type(t) == "string"
        and (string.find(t, ILVL_LINE_MARKER, 1, true) or string.find(t, ILVL_LINE_MARKER_LEGACY, 1, true))
      then
        return fs, i
      end
    end
  end
  return nil, nil
end

local function FormatTooltipLines(equipped, pvp, pvpIsApprox)
  local eqDisp = FormatMaybeNumber(equipped, false)
  local equippedLine = "Equipped iLvl: " .. ColorizeIlvlToken(eqDisp, equipped)
  if type(pvp) ~= "number" then
    return equippedLine, nil
  end
  local pvpDisp = FormatMaybeNumber(pvp, pvpIsApprox == true)
  return equippedLine, "PvP iLvl: " .. ColorizeIlvlToken(pvpDisp, pvp)
end

--- Keep layout handling passive. On Retail we add lines during the tooltip data
--- processor pass, before Blizzard finalizes the tooltip size; calling Show()
--- here can restart cursor-owned unit tooltips and cause flicker.
local function FinalizeUnitTooltipAfterIlvl(tooltip)
  if not tooltip then
    return
  end
  if GameTooltip_CalculatePadding then
    pcall(GameTooltip_CalculatePadding, tooltip)
  end
  local num = tooltip.NumLines and tooltip:NumLines() or 0
  if num < 1 then
    return
  end
  for i = 1, num do
    local left = GetTooltipTextLeftFS(tooltip, i)
    if left and left.SetWordWrap then
      pcall(left.SetWordWrap, left, false)
    end
  end
  if GameTooltip_CalculatePadding then
    pcall(GameTooltip_CalculatePadding, tooltip)
  end
end

local function UpdateTooltipForUnit(tooltip, unit)
  if not unit or not UnitExists(unit) then
    return
  end

  local guid = UnitGUID(unit)
  local equipped, pvp
  local pvpIsApprox = false

  if UnitIsUnit(unit, "player") then
    equipped, pvp = GetPlayerEquippedAndPvp()
  else
    local approx
    equipped, pvp, approx = GetInspectEquippedAndPvp(unit)
    pvpIsApprox = approx == true
    if not equipped then
      local ca
      equipped, pvp, ca = GetCached(guid)
      pvpIsApprox = ca == true
    end
    RequestInspectIfNeeded(unit)
  end

  local equippedLine, pvpLine = FormatTooltipLines(equipped, pvp, pvpIsApprox)
  local existingLine, existingLineIndex = FindTooltipIlvlLineFS(tooltip)
  if existingLine then
    existingLine:SetText(equippedLine)
    local existingPvpLine = existingLineIndex and GetTooltipTextLeftFS(tooltip, existingLineIndex + 1)
    if existingPvpLine and existingPvpLine.GetText then
      local text = existingPvpLine:GetText()
      if type(text) == "string" and (string.find(text, PVP_ILVL_LINE_MARKER, 1, true) or string.find(text, "PvP:", 1, true)) then
        existingPvpLine:SetText(pvpLine or "")
      elseif tooltip.AddLine then
        if pvpLine then
          tooltip:AddLine(pvpLine, 1, 1, 1, false)
        end
      end
    elseif tooltip.AddLine then
      if pvpLine then
        tooltip:AddLine(pvpLine, 1, 1, 1, false)
      end
    end
    FinalizeUnitTooltipAfterIlvl(tooltip)
    return
  end
  if not tooltip.AddLine then
    return
  end
  tooltip:AddLine(equippedLine, 1, 1, 1, false)
  if pvpLine then
    tooltip:AddLine(pvpLine, 1, 1, 1, false)
  end
  FinalizeUnitTooltipAfterIlvl(tooltip)
end

local function UnitTokenIsUnsafe(unit)
  return type(issecretvalue) == "function" and issecretvalue(unit)
end

local function ResolvePlayerUnitToken(tooltip, tooltipData)
  local unit
  if tooltip and tooltip.GetUnit then
    local ok, a, b = pcall(function()
      return tooltip:GetUnit()
    end)
    if ok and type(b) == "string" and b ~= "" then
      unit = b
    end
  end
  if (not unit or UnitTokenIsUnsafe(unit)) and tooltip then
    unit = GetDisplayedUnitToken(tooltip, tooltipData)
  end
  if not unit or UnitTokenIsUnsafe(unit) then
    return nil
  end
  if not UnitExists(unit) or not UnitIsPlayer(unit) then
    return nil
  end
  return unit
end

local tooltipHooksRegistered
local characterPanelHooksRegistered
local characterPanelShowHooksRegistered

local function ApplyIlvlToTooltip(tooltip, tooltipData)
  if not tooltip then
    return
  end
  local unit = ResolvePlayerUnitToken(tooltip, tooltipData)
  if not unit then
    return
  end
  local tname = "?"
  if tooltip.GetName then
    local ok, n = pcall(function()
      return tooltip:GetName()
    end)
    if ok and type(n) == "string" then
      tname = n
    end
  end
  local applyOk, applyErr = pcall(function()
    Dbg("ApplyIlvl tip=%s unit=%s", tname, unit)
    lastTooltipUnit = unit
    UpdateTooltipForUnit(tooltip, unit)
  end)
  if not applyOk then
    Dbg("ApplyIlvlToTooltip failed: %s", tostring(applyErr))
  end
end

--- Processor: has tooltipData (GUID) and runs for Retail unit tooltips. SetUnit: next-frame fallback
--- when unit/token is not ready during the processor pass (world/nameplates). No shared cancelable
--- timer — that was dropping applies and breaking other players + self paper doll.
local function RegisterUnitTooltipHooks()
  if tooltipHooksRegistered then
    return
  end
  tooltipHooksRegistered = true

  local hasTooltipDataProcessor = TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
  if hasTooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, tooltipData)
      ApplyIlvlToTooltip(tooltip, tooltipData)
    end)
  end

  if GameTooltip and not hasTooltipDataProcessor then
    hooksecurefunc(GameTooltip, "SetUnit", function(_, unitToken)
      if not unitToken or not UnitExists(unitToken) or not UnitIsPlayer(unitToken) then
        return
      end
      C_Timer.After(0, function()
        if GameTooltip:IsShown() then
          ApplyIlvlToTooltip(GameTooltip, nil)
        end
      end)
    end)

  end
end

local function RefreshMouseoverTooltipIfNeeded(inspectedGUID)
  if not inspectedGUID or not lastTooltipUnit or not UnitExists(lastTooltipUnit) then
    return
  end
  if UnitGUID(lastTooltipUnit) ~= inspectedGUID then
    return
  end
  if not GameTooltip:IsShown() then
    return
  end

  local inspectOk, eq, pvp, approx = pcall(GetInspectEquippedAndPvp, lastTooltipUnit)
  if not inspectOk then
    Dbg("GetInspectEquippedAndPvp failed: %s", tostring(eq))
    return
  end
  SetCached(inspectedGUID, eq, pvp, approx)

  C_Timer.After(0, function()
    if not GameTooltip:IsShown() then
      return
    end
    if not lastTooltipUnit or not UnitExists(lastTooltipUnit) then
      return
    end
    if UnitGUID(lastTooltipUnit) ~= inspectedGUID then
      return
    end
    local updateOk, updateErr = pcall(function()
      UpdateTooltipForUnit(GameTooltip, lastTooltipUnit)
    end)
    if not updateOk then
      Dbg("GameTooltip inspect refresh failed: %s", tostring(updateErr))
    end
  end)
end

--- Anchor under UIParent only so we are not a child of Character/PaperDoll (reduces panel/housing taint chains).
local function SyncCharacterPanelAnchorVisibilityAndPosition()
  DbgVerbose(
    "Sync PDshown=%s CFshown=%s",
    PaperDollFrame and tostring(PaperDollFrame:IsShown()) or "?",
    CharacterFrame and tostring(CharacterFrame:IsShown()) or "?"
  )
  if not charAnchor then
    return
  end
  if PaperDollFrame and CharacterFrame and CharacterFrame:IsShown() and PaperDollFrame:IsShown() then
    charAnchor:ClearAllPoints()
    charAnchor:SetPoint("TOPLEFT", PaperDollFrame, "TOPLEFT", 12, -4)
    charAnchor:SetPoint("TOPRIGHT", PaperDollFrame, "TOPRIGHT", -12, -4)
    charAnchor:Show()
  else
    charAnchor:Hide()
  end
end

local function EnsureCharacterPanelText()
  if charFontString then
    SyncCharacterPanelAnchorVisibilityAndPosition()
    return true
  end

  if not PaperDollFrame or not CharacterFrame then
    return false
  end

  local anchor = CreateFrame("Frame", "EquippedPvPItemLevelCharAnchor", UIParent)
  charAnchor = anchor
  anchor:SetHeight(40)
  anchor:Hide()

  charFontString = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  charFontString:SetAllPoints(anchor)
  charFontString:SetJustifyH("CENTER")
  charFontString:SetJustifyV("TOP")
  charFontString:SetWordWrap(true)

  SyncCharacterPanelAnchorVisibilityAndPosition()
  return true
end

UpdateCharacterPanel = function()
  local ok, err = pcall(function()
    RefreshPvpEquippedRatio()
    if not EnsureCharacterPanelText() then
      return
    end
    local eq, pvp = GetPlayerEquippedAndPvp()
    charFontString:SetText(FormatLineColored(eq, pvp, false))
  end)
  if not ok then
    Dbg("UpdateCharacterPanel failed: %s", tostring(err))
  end
end

local function TryInitCharacterPanelDeferred()
  if EnsureCharacterPanelText() then
    UpdateCharacterPanel()
    return true
  end
  return false
end

local eventFrame = CreateFrame("Frame", "EquippedPvPItemLevelEvents")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("INSPECT_READY")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON_NAME then
      EquippedPvPItemLevelSV = EquippedPvPItemLevelSV or {}
      if EquippedPvPItemLevelSV.debug == nil then
        EquippedPvPItemLevelSV.debug = false
      end
      if EquippedPvPItemLevelSV.debugVerbose == nil then
        EquippedPvPItemLevelSV.debugVerbose = false
      end
      RegisterUnitTooltipHooks()
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    RegisterUnitTooltipHooks()
    return
  end

  if event == "PLAYER_LOGIN" then
    RegisterUnitTooltipHooks()

    if not TryInitCharacterPanelDeferred() then
      C_Timer.After(0, function()
        TryInitCharacterPanelDeferred()
      end)
    end

    if not characterPanelHooksRegistered then
      characterPanelHooksRegistered = true
      if PaperDollFrame_SetLevel then
        hooksecurefunc("PaperDollFrame_SetLevel", function()
          UpdateCharacterPanel()
        end)
      end
      local function TryRegisterCharacterPanelShowHooks()
        if characterPanelShowHooksRegistered then
          return
        end
        if not PaperDollFrame or not CharacterFrame then
          return
        end
        characterPanelShowHooksRegistered = true
        hooksecurefunc(PaperDollFrame, "Show", function()
          SyncCharacterPanelAnchorVisibilityAndPosition()
          UpdateCharacterPanel()
        end)
        hooksecurefunc(PaperDollFrame, "Hide", function()
          SyncCharacterPanelAnchorVisibilityAndPosition()
        end)
        hooksecurefunc(CharacterFrame, "Show", function()
          TryInitCharacterPanelDeferred()
          SyncCharacterPanelAnchorVisibilityAndPosition()
        end)
        hooksecurefunc(CharacterFrame, "Hide", function()
          SyncCharacterPanelAnchorVisibilityAndPosition()
        end)
      end
      TryRegisterCharacterPanelShowHooks()
      if not characterPanelShowHooksRegistered then
        C_Timer.After(0.5, TryRegisterCharacterPanelShowHooks)
      end
    end
    return
  end

  if event == "INSPECT_READY" then
    local guid = ...
    RefreshMouseoverTooltipIfNeeded(guid)
    return
  end

  if event == "PLAYER_EQUIPMENT_CHANGED" then
    UpdateCharacterPanel()
    return
  end

  if event == "PLAYER_SPECIALIZATION_CHANGED" then
    local unit = ...
    if unit and UnitIsUnit(unit, "player") then
      UpdateCharacterPanel()
    end
  end
end)

local function EquippedPvPItemLevelSlashHandler(msg)
  msg = Trim(msg or "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  if not cmd then
    cmd = ""
  end
  cmd = string.lower(Trim(cmd))
  rest = Trim(rest or "")

  local function help()
    local C = DEFAULT_CHAT_FRAME
    local function line(t)
      C:AddMessage("|cffffcc00[EPvPILVL]|r " .. t, 1, 1, 1)
    end
    line("Bug / taint — collect this, then paste chat text + files:")
    line("|cff88ff881)|r |cff88ff88/console scriptErrors 1|r  (on-screen Lua errors)")
    line("|cff88ff882)|r |cff88ff88/console taintLog 2|r  (writes _retail_|Logs\\taint.log — try |cff88ff881|r if the file is huge)")
    line("|cff88ff883)|r Reproduce once, then |cff88ff88/reload|r  (flushes taint log)")
    line("|cff88ff884)|r Send: screenshot + last ~200 lines of Logs\\taint.log")
    line("|cff88ff885)|r Run |cff88ff88/epvpilvl snapshot|r  and copy every |cffffcc00[EPvPILVL snapshot]|r line")
    line("|cff88ff886)|r Optional: BugSack + BugGrabber for copyable stacks")
    line("|cff88ff887)|r |cff88ff88/console taintLog 0|r when done")
    line("This addon: |cff88ff88/epvpilvl debug on|off|r  |cff88ff88verbose on|off|r  snapshot  help")
    line("BugSack |cffff5555[Error …]|r messages: open BugSack and click the entry — the hex id is BugSack’s link, not a Blizzard code — the stack shows the real file/line.")
  end

  if cmd == "" or cmd == "help" or cmd == "?" then
    help()
    return
  end

  if cmd == "snapshot" then
    EquippedPvPItemLevelSV = EquippedPvPItemLevelSV or {}
    local sv2 = EquippedPvPItemLevelSV
    local ver = GetAddOnVersionMeta()
    local se = GetCVar and (GetCVar("scriptErrors") or "?") or "?"
    local tl = GetCVar and (GetCVar("taintLog") or "?") or "?"
    local loc = GetLocale and GetLocale() or "?"
    local C = DEFAULT_CHAT_FRAME
    local function snapline(t)
      C:AddMessage("|cffffcc00[EPvPILVL snapshot]|r " .. t, 1, 1, 1)
    end
    local ashow = "nil"
    if charAnchor then
      local ok, sh = pcall(function()
        return charAnchor:IsShown()
      end)
      ashow = ok and tostring(sh) or "?"
    end
    snapline("--- copy block start ---")
    snapline("version=" .. ver .. " bundled=" .. ADDON_VERSION .. " locale=" .. loc .. " WOW_PROJECT_ID=" .. tostring(WOW_PROJECT_ID))
    snapline("CVar scriptErrors=" .. se .. " taintLog=" .. tl)
    snapline(
      "hooks tooltipReg="
        .. tostring(tooltipHooksRegistered)
        .. " charPanelBlock="
        .. tostring(characterPanelHooksRegistered)
        .. " charShowReg="
        .. tostring(characterPanelShowHooksRegistered)
    )
    snapline("charAnchorExists=" .. tostring(charAnchor ~= nil) .. " charAnchorShown=" .. ashow .. " lastTooltipUnit=" .. tostring(lastTooltipUnit))
    snapline("savedvars debug=" .. tostring(sv2.debug) .. " verbose=" .. tostring(sv2.debugVerbose))
    snapline("--- copy block end ---")
    return
  end

  if cmd == "debug" then
    EquippedPvPItemLevelSV = EquippedPvPItemLevelSV or {}
    local s = EquippedPvPItemLevelSV
    local a = string.lower(Trim(rest))
    if a == "on" or a == "1" or a == "true" then
      s.debug = true
    elseif a == "off" or a == "0" or a == "false" then
      s.debug = false
      s.debugVerbose = false
    else
      s.debug = not s.debug
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[EPvPILVL]|r debug=" .. tostring(s.debug), 1, 1, 1)
    return
  end

  if cmd == "verbose" then
    EquippedPvPItemLevelSV = EquippedPvPItemLevelSV or {}
    local s = EquippedPvPItemLevelSV
    local a = string.lower(Trim(rest))
    if a == "on" or a == "1" or a == "true" then
      s.debugVerbose = true
      s.debug = true
    elseif a == "off" or a == "0" or a == "false" then
      s.debugVerbose = false
    else
      s.debugVerbose = not s.debugVerbose
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[EPvPILVL]|r verbose=" .. tostring(s.debugVerbose) .. " (needs debug on)", 1, 1, 1)
    return
  end

  help()
end

SLASH_EQUIPPEDPVPILEVEL1 = "/epvpilvl"
SLASH_EQUIPPEDPVPILEVEL2 = "/epilvl"
SlashCmdList["EQUIPPEDPVPILEVEL"] = EquippedPvPItemLevelSlashHandler

RegisterUnitTooltipHooks()
