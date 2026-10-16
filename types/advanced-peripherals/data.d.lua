---@meta
-- Editor definitions for Advanced Peripherals 0.7.62b, Minecraft 1.21.1.
-- Verified against upstream commit d802ae5e964ac4f6e40e05a38157754570ffa5a1.
-- These declarations describe runtime objects; never require this file.

---@class AP.Position
---@field x number
---@field y number
---@field z number

---Filter fields accepted by the 1.21.1 bridge API. Use components, not legacy NBT filters.
---@class AP.ItemFilter
---@field name? string Registry name, e.g. minecraft:iron_ingot.
---@field fingerprint? string Exact resource fingerprint returned by the bridge.
---@field components? string|table Data components as a table or SNBT string.
---@field count? integer Number of items to transfer or craft.
---@field fromSlot? integer Source inventory slot.
---@field toSlot? integer Destination inventory slot.
---@field type? 'item' Explicit type when using generic filter methods.

---@class AP.FluidFilter
---@field name? string Fluid registry name.
---@field fingerprint? string
---@field components? string|table
---@field amount? integer Fluid amount.
---@field count? integer Alternative to amount.
---@field type? 'fluid'

---@class AP.ChemicalFilter
---@field name? string Chemical registry name; requires the relevant Mekanism integration.
---@field fingerprint? string
---@field amount? integer
---@field count? integer Alternative to amount.
---@field fromSlot? integer
---@field toSlot? integer
---@field type? 'chemical'

---@alias AP.ResourceFilter AP.ItemFilter|AP.FluidFilter|AP.ChemicalFilter

---@class AP.StoredResource
---@field name string
---@field count number Stored amount (also used for fluids and chemicals).
---@field displayName? string
---@field fingerprint? string
---@field tags? string[]
---@field components? table
---@field isCraftable? boolean
---@field maxStackSize? integer Item resources only.
---@field fluidType? table Fluid resources only.
---@field isGaseous? boolean Chemical resources only.
---@field radioactivity? boolean Chemical resources only.

---@class AP.InventoryItem: AP.StoredResource
---@field slot? integer

---@class AP.ScannedBlock: AP.Position
---@field name string Block registry name. Coordinates are relative to the scanner.
---@field tags string[]

---@class AP.ScannedEntity: AP.Position
---@field id integer
---@field uuid string
---@field name string
---@field tags string[]
---@field health? number
---@field maxHealth? number
---@field canFreeze boolean
---@field isGlowing boolean
---@field isInWall boolean
---@field lastDamageSource? string
---@field baby? boolean
---@field inLove? boolean
---@field aggressive? boolean

---@class AP.PlayerPosition: AP.Position
---@field uuid? string
---@field name? string
---@field yaw? number
---@field pitch? number
---@field dimension? string
---@field eyeHeight? number
---@field health? number
---@field maxHealth? number
---@field airSupply? integer
---@field respawnPosition? AP.Position
---@field respawnDimension? string
---@field respawnAngle? number

---@class AP.PatternFilter
---@field input? AP.ResourceFilter
---@field output? AP.ResourceFilter

---@class AP.Pattern
---@field inputs table[]
---@field outputs AP.StoredResource[]
---@field primaryOutput AP.StoredResource
---@field patternType string
---@field id? string Refined Storage patterns only.

---A task description returned by a bridge, rather than the live craft job object.
---@class AP.CraftingTask
---@field bridge_id integer
---@field id? string
---@field quantity number
---@field crafted number
---@field resource AP.StoredResource
---@field completion number AE2 uses a fraction; Refined Storage uses a percentage.
---@field cpu? AP.CraftingCPU

---@class AP.CraftingCPU
---@field name string
---@field storage number
---@field coProcessors integer
---@field isBusy boolean
---@field selectionMode string
---@field craftingJob? AP.CraftingTask

---Live job returned by craftItem/craftFluid/craftChemical. Call methods with dots.
---@class AP.CraftJob
---@field getId fun(): integer
---@field isDone fun(): boolean
---@field isCanceled fun(): boolean
---@field isCraftingStarted fun(): boolean
---@field isCalculationStarted fun(): boolean
---@field isCalculationNotSuccessful fun(): boolean
---@field hasErrorOccurred fun(): boolean
---@field getDebugMessage fun(): string
---@field getRequestedItem fun(): AP.StoredResource
---@field getElapsedTime fun(): number
---@field getTotalItems fun(): number
---@field getItemProgress fun(): number
---@field getEmittedItems fun(): AP.StoredResource[]?
---@field getUsedItems fun(): AP.StoredResource[]?
---@field getMissingItems fun(): AP.StoredResource[]?
---@field hasMultiplePaths fun(): boolean
---@field getFinalOutput fun(): AP.StoredResource|AP.StoredResource[]|nil
---@field cancel fun(): boolean

---@class AP.MECraftJob: AP.CraftJob
---@field getCraftingCPU fun(): AP.CraftingCPU?
---@field getUsedBytes fun(): number
