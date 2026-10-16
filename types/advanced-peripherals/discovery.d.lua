---@meta
-- Add literal-type overloads to the existing CC:Tweaked peripheral API.
-- Side/network names used with wrap() need an explicit AP type assertion.

---@alias AP.PeripheralType
---| '"me_bridge"'
---| '"rs_bridge"'
---| '"geo_scanner"'
---| '"environment_detector"'
---| '"player_detector"'
---| '"chat_box"'
---| '"inventory_manager"'
---| '"energy_detector"'
---| '"block_reader"'
---| '"nbt_storage"'
---| '"compass"'
---| '"chunky"'
---| '"colony_integrator"'

---@alias AP.Peripheral AP.MEBridge|AP.RSBridge|AP.GeoScanner|AP.EnvironmentDetector|AP.PlayerDetector|AP.ChatBox|AP.InventoryManager|AP.EnergyDetector|AP.BlockReader|AP.NBTStorage|AP.Compass|AP.Chunky|AP.ColonyIntegrator

---Advanced Peripherals types available in AP 0.7.62b / Minecraft 1.21.1.
---@overload fun(peripheralType: '"me_bridge"', filter?: fun(name: string, wrapped: AP.MEBridge): boolean): ...: AP.MEBridge?
---@overload fun(peripheralType: '"rs_bridge"', filter?: fun(name: string, wrapped: AP.RSBridge): boolean): ...: AP.RSBridge?
---@overload fun(peripheralType: '"geo_scanner"', filter?: fun(name: string, wrapped: AP.GeoScanner): boolean): ...: AP.GeoScanner?
---@overload fun(peripheralType: '"environment_detector"', filter?: fun(name: string, wrapped: AP.EnvironmentDetector): boolean): ...: AP.EnvironmentDetector?
---@overload fun(peripheralType: '"player_detector"', filter?: fun(name: string, wrapped: AP.PlayerDetector): boolean): ...: AP.PlayerDetector?
---@overload fun(peripheralType: '"chat_box"', filter?: fun(name: string, wrapped: AP.ChatBox): boolean): ...: AP.ChatBox?
---@overload fun(peripheralType: '"inventory_manager"', filter?: fun(name: string, wrapped: AP.InventoryManager): boolean): ...: AP.InventoryManager?
---@overload fun(peripheralType: '"energy_detector"', filter?: fun(name: string, wrapped: AP.EnergyDetector): boolean): ...: AP.EnergyDetector?
---@overload fun(peripheralType: '"block_reader"', filter?: fun(name: string, wrapped: AP.BlockReader): boolean): ...: AP.BlockReader?
---@overload fun(peripheralType: '"nbt_storage"', filter?: fun(name: string, wrapped: AP.NBTStorage): boolean): ...: AP.NBTStorage?
---@overload fun(peripheralType: '"compass"', filter?: fun(name: string, wrapped: AP.Compass): boolean): ...: AP.Compass?
---@overload fun(peripheralType: '"chunky"', filter?: fun(name: string, wrapped: AP.Chunky): boolean): ...: AP.Chunky?
---@overload fun(peripheralType: '"colony_integrator"', filter?: fun(name: string, wrapped: AP.ColonyIntegrator): boolean): ...: AP.ColonyIntegrator?
---@param peripheralType string
---@param filter? fun(name: string, wrapped: AP.Peripheral|ccTweaked.peripherals.wrappedPeripheral): boolean
---@return AP.Peripheral|ccTweaked.peripherals.wrappedPeripheral|nil ...
function peripheral.find(peripheralType, filter) end

---@overload fun(wrapped: AP.Peripheral): string
---@param wrapped AP.Peripheral|ccTweaked.peripherals.wrappedPeripheral
---@return string
function peripheral.getName(wrapped) end

---@overload fun(wrapped: AP.Peripheral): string
---@param wrapped string|AP.Peripheral|ccTweaked.peripherals.wrappedPeripheral
---@return string? ...
function peripheral.getType(wrapped) end

---@overload fun(wrapped: string|AP.Peripheral, peripheralType: AP.PeripheralType): boolean?
---@param wrapped string|AP.Peripheral|ccTweaked.peripherals.wrappedPeripheral
---@param peripheralType string
---@return boolean?
function peripheral.hasType(wrapped, peripheralType) end
