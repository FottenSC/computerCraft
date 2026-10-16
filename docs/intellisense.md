# VS Code IntelliSense

Open this repository folder or `computerCraft.code-workspace` in VS Code. Install
the recommended **Lua** extension (`sumneko.lua`) and enable its **CC:Tweaked**
addon through **Lua: Open Addon Manager** in the command palette. The project's
settings load that addon and the small, tracked definitions in
`types/advanced-peripherals/`. Downloaded `.reference/` files and generated `dist/`
files are excluded from workspace scanning.

If the project was already open when these definitions were added, run
**Developer: Reload Window** once. Open [the example](../examples/advanced-peripherals.lua)
and type a dot after `bridge` to see its methods. **Ctrl+Space** opens completion,
**Ctrl+Shift+Space** opens parameter hints, and hovering shows types and descriptions.

```lua
local bridge = assert(peripheral.find("me_bridge"))
local items, reason = bridge.getItems()
if items then
    for _, item in ipairs(items) do
        print(item.name, item.count)
    end
else
    printError(reason)
end
```

Literal names passed to `peripheral.find` infer the corresponding AP type,
including the filter callback and multiple returned peripherals. Discovery may
return no peripheral, so use an `if` guard or `assert` before calling methods.
Peripheral and live craft-job methods use **dots**, not colons.

The side or network name passed to `peripheral.wrap` cannot tell the editor which
peripheral is attached. Assert the type when you know the hardware:

```lua
local bridge = assert(peripheral.wrap("back")) --[[@as AP.MEBridge]]
local items, reason = bridge.getItems()
```

This assertion only helps the editor; it does not check the device at runtime.
Use `peripheral.hasType("back", "me_bridge")` if a runtime check is needed.

## Version and coverage

The definitions target **Advanced Peripherals 0.7.62b on Minecraft 1.21.1**, checked
against source commit
[`d802ae5e964ac4f6e40e05a38157754570ffa5a1`](https://github.com/IntelligenceModding/AdvancedPeripherals/tree/d802ae5e964ac4f6e40e05a38157754570ffa5a1).
They cover these peripheral names:

| Peripheral name | LuaLS type |
| --- | --- |
| `me_bridge` | `AP.MEBridge` |
| `rs_bridge` | `AP.RSBridge` |
| `geo_scanner` | `AP.GeoScanner` |
| `environment_detector` | `AP.EnvironmentDetector` |
| `player_detector` | `AP.PlayerDetector` |
| `chat_box` | `AP.ChatBox` |
| `inventory_manager` | `AP.InventoryManager` |
| `energy_detector` | `AP.EnergyDetector` |
| `block_reader` | `AP.BlockReader` |
| `nbt_storage` | `AP.NBTStorage` |
| `compass` | `AP.Compass` |
| `chunky` | `AP.Chunky` |
| `colony_integrator` | `AP.ColonyIntegrator` |

Filters, stored resources, scanned blocks/entities, player positions, patterns,
crafting task descriptions, and live crafting jobs have accompanying types.
Complex colony records and storage cell/drive details remain open tables.
Automata cores and optional integrations supplied by other mods are not covered.
Older AP peripheral names and legacy methods such as `listItems` are deliberately
absent from this version's bridge completions; use `getItems` instead.

Scanner fuel methods depend on the hardware variant/configuration, so check that
the function exists when needed. Scanner calls can fail because of cooldown,
radius, or fuel limits. Player position detail fields depend on server settings.
The upstream 0.7.62b implementation of `sendFormattedMessageToPlayer` reads its
sixth argument as both a boolean and an integer; the definition omits that broken
optional argument and later positions. Its first five arguments remain available.

These are editor definitions, with no runtime implementation. They are not
included in ccpm's package manifest or release distribution and should never be
loaded with `require` on a computer or turtle. No Minecraft files are changed.

## Maintaining and verifying definitions

Keep the version/source pin above and in the definition headers aligned when
updating them. `docs/sources.json` includes the exact-release peripheral, owner
ability, storage-filter and crafting-job source needed to review signatures.
Refresh references with `python tools/fetch_docs.py` and consult the resulting
`.reference/index.md`. The official manual is a series reference, so confirm
names, arguments, nil/error returns and variant-dependent methods against source.

The real language-server smoke check uses a disposable workspace and the
installed CC:Tweaked addon. Run it with paths to your LuaLS executable and addon's
`library` directory:

```text
python tools/check_intellisense.py --server /path/to/lua-language-server --cc-library /path/to/cc-tweaked/module/library
```

It verifies AP/core completion, nested resource and job types, multiple discovery
results, explicit wrap assertions, hover text, signature help, invalid argument
diagnostics, and that fixing the invalid call clears the diagnostics. The normal
CI syntax check parses the definition files, but full editor behavior requires
this language-server check.
