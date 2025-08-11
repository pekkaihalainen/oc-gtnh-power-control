-- Lapatronic Supercapacitor Power Controller
-- Monitors energy level and controls redstone output with hysteresis
-- Enable signal at <20%, disable at >90%

local component = require("component")
local event = require("event")
local os = require("os")
local unicode = require("unicode")
local filesystem = require("filesystem")

-- Configuration
local CHECK_INTERVAL = 5 -- seconds between energy checks
local LOW_THRESHOLD = 0.20 -- 20% - enable redstone signal
local HIGH_THRESHOLD = 0.90 -- 90% - disable redstone signal
local REDSTONE_SIDE = 1 -- redstone I/O side (1-6, or use sides.bottom etc)

-- Component Addresses (Set these to your specific component addresses)
-- To find component addresses, run: controller list
-- or use: component.list() in lua console
local ENERGY_DETECTOR_ADDRESS = "your-energy-detector-address-here" -- GT Energy Detector address
local REDSTONE_IO_ADDRESS = "your-redstone-io-address-here" -- Redstone I/O address
local GPU_ADDRESS = "your-gpu-address-here" -- GPU address (optional, will auto-detect if empty)
local SCREEN_ADDRESS = "your-screen-address-here" -- Screen address (optional, will auto-detect if empty)

-- Load configuration from external file if it exists
local function loadConfig()
    local configPaths = {
        "config.lua",           -- Current directory
        "/config.lua",          -- Root directory
        "/home/config.lua"      -- Home directory
    }
    
    for _, configPath in ipairs(configPaths) do
        if filesystem.exists(configPath) then
            print("📁 Loading configuration from " .. configPath .. "...")
            local configFile, err = loadfile(configPath)
            if configFile then
                local success, config = pcall(configFile)
                if success and config then
                    -- Override defaults with config file values
                    ENERGY_DETECTOR_ADDRESS = config.ENERGY_DETECTOR_ADDRESS or ENERGY_DETECTOR_ADDRESS
                    REDSTONE_IO_ADDRESS = config.REDSTONE_IO_ADDRESS or REDSTONE_IO_ADDRESS
                    GPU_ADDRESS = config.GPU_ADDRESS or GPU_ADDRESS
                    SCREEN_ADDRESS = config.SCREEN_ADDRESS or SCREEN_ADDRESS
                    CHECK_INTERVAL = config.CHECK_INTERVAL or CHECK_INTERVAL
                    LOW_THRESHOLD = config.LOW_THRESHOLD or LOW_THRESHOLD
                    HIGH_THRESHOLD = config.HIGH_THRESHOLD or HIGH_THRESHOLD
                    REDSTONE_SIDE = config.REDSTONE_SIDE or REDSTONE_SIDE
                    print("✅ Configuration loaded successfully from " .. configPath)
                    return true
                else
                    print("⚠️  Warning: " .. configPath .. " had errors: " .. tostring(config))
                end
            else
                print("⚠️  Warning: Could not load " .. configPath .. ": " .. tostring(err))
            end
        end
    end
    
    return false
end

-- Try to load configuration
if not loadConfig() then
    print("💡 No config.lua found in any location - using inline configuration")
    print("💡 Searched paths: config.lua (current dir), /config.lua (root), /home/config.lua")
    print("💡 Run 'controller list' to find component addresses")
    print("💡 See config_example.lua for external configuration setup")
end

-- Global state
local isRedstoneActive = false
local energyDetector = nil
local redstoneIO = nil
local gpu = nil
local screen = nil
local screenWidth, screenHeight = 0, 0

-- Helper function to get component by address with fallback
local function getComponentByAddress(address, componentType, fallbackType)
    if address and address ~= "" and address ~= "your-" .. componentType .. "-address-here" then
        if component.proxy(address) then
            return component.proxy(address)
        else
            error(string.format("✗ Component not found at address: %s", address))
        end
    else
        -- Fallback to automatic detection
        if component.isAvailable(fallbackType) then
            return component[fallbackType]
        else
            error(string.format("✗ No %s found! Please set %s_ADDRESS or connect component.", componentType, componentType:upper()))
        end
    end
end

-- Initialize components
local function initializeComponents()
    print("Initializing components...")
    print("Note: Run 'component.list()' to find component addresses")
    print("")
    
    -- Initialize GPU
    gpu = getComponentByAddress(GPU_ADDRESS, "gpu", "gpu")
    print("✓ Found GPU: " .. gpu.address:sub(1, 8) .. "...")
    
    -- Initialize Screen
    screen = getComponentByAddress(SCREEN_ADDRESS, "screen", "screen")
    gpu.bind(screen.address)
    screenWidth, screenHeight = gpu.getResolution()
    print(string.format("✓ Found Screen (%dx%d): %s...", screenWidth, screenHeight, screen.address:sub(1, 8)))
    
    -- Initialize Energy Detector
    if ENERGY_DETECTOR_ADDRESS and ENERGY_DETECTOR_ADDRESS ~= "your-energy-detector-address-here" then
        energyDetector = component.proxy(ENERGY_DETECTOR_ADDRESS)
        if not energyDetector then
            error("✗ Energy detector not found at address: " .. ENERGY_DETECTOR_ADDRESS)
        end
        print("✓ Found Energy Detector: " .. ENERGY_DETECTOR_ADDRESS:sub(1, 8) .. "...")
    else
        error("✗ Please set ENERGY_DETECTOR_ADDRESS in the configuration!\nRun 'component.list()' to find your energy detector address.")
    end
    
    -- Initialize Redstone I/O
    if REDSTONE_IO_ADDRESS and REDSTONE_IO_ADDRESS ~= "your-redstone-io-address-here" then
        redstoneIO = component.proxy(REDSTONE_IO_ADDRESS)
        if not redstoneIO then
            error("✗ Redstone I/O not found at address: " .. REDSTONE_IO_ADDRESS)
        end
        print("✓ Found Redstone I/O: " .. REDSTONE_IO_ADDRESS:sub(1, 8) .. "...")
    else
        error("✗ Please set REDSTONE_IO_ADDRESS in the configuration!\nRun 'component.list()' to find your redstone I/O address.")
    end
    
    print("")
    print("All components initialized successfully!")
    os.sleep(2) -- Give user time to read initialization messages
end

-- Get current energy level as percentage (0.0 to 1.0)
local function getEnergyLevel()
    if not energyDetector then return 0 end
    
    -- Try different methods to get energy data
    local current, max = 0, 0
    
    if energyDetector.getEnergyStored and energyDetector.getMaxEnergyStored then
        current = energyDetector.getEnergyStored()
        max = energyDetector.getMaxEnergyStored()
    elseif energyDetector.getStored and energyDetector.getCapacity then
        current = energyDetector.getStored()
        max = energyDetector.getCapacity()
    else
        print("⚠ Warning: Unknown energy detector methods")
        return 0
    end
    
    if max == 0 then return 0 end
    return current / max
end

-- Set redstone signal state
local function setRedstoneSignal(active)
    if not redstoneIO then return end
    
    local strength = active and 15 or 0
    redstoneIO.setOutput(REDSTONE_SIDE, strength)
    isRedstoneActive = active
    
    local status = active and "ENABLED" or "DISABLED"
    print(string.format("🔴 Redstone signal %s (strength: %d)", status, strength))
end

-- Main control logic with hysteresis
local function updatePowerControl(energyPercent)
    local prevState = isRedstoneActive
    
    if not isRedstoneActive and energyPercent <= LOW_THRESHOLD then
        -- Energy is low and signal is off -> turn on
        setRedstoneSignal(true)
        print(string.format("⚡ Energy low (%.1f%%) - Activating power systems", energyPercent * 100))
        
    elseif isRedstoneActive and energyPercent >= HIGH_THRESHOLD then
        -- Energy is high and signal is on -> turn off
        setRedstoneSignal(false)
        print(string.format("🔋 Energy sufficient (%.1f%%) - Deactivating power systems", energyPercent * 100))
    end
    
    -- No change in middle range - this is the hysteresis behavior
end

-- Clear screen with background
local function clearScreen()
    gpu.setBackground(0x000000) -- Black background
    gpu.setForeground(0xFFFFFF) -- White text
    gpu.fill(1, 1, screenWidth, screenHeight, " ")
end

-- Draw a progress bar
local function drawProgressBar(x, y, width, height, percent, color)
    -- Draw border
    gpu.setForeground(0xFFFFFF)
    gpu.fill(x, y, width, 1, "═")
    gpu.fill(x, y + height - 1, width, 1, "═")
    gpu.fill(x, y, 1, height, "║")
    gpu.fill(x + width - 1, y, 1, height, "║")
    
    -- Draw corners
    gpu.set(x, y, "╔")
    gpu.set(x + width - 1, y, "╗")
    gpu.set(x, y + height - 1, "╚")
    gpu.set(x + width - 1, y + height - 1, "╝")
    
    -- Fill interior
    local fillWidth = width - 2
    local fillHeight = height - 2
    local filledWidth = math.floor(fillWidth * percent)
    
    -- Clear interior
    gpu.setBackground(0x000000)
    gpu.fill(x + 1, y + 1, fillWidth, fillHeight, " ")
    
    -- Fill progress
    if filledWidth > 0 then
        gpu.setBackground(color)
        gpu.fill(x + 1, y + 1, filledWidth, fillHeight, " ")
    end
    
    gpu.setBackground(0x000000)
end

-- Get color based on energy level
local function getEnergyColor(percent)
    if percent <= LOW_THRESHOLD then
        return 0xFF0000 -- Red (critical)
    elseif percent <= 0.5 then
        return 0xFFFF00 -- Yellow (low)
    elseif percent <= HIGH_THRESHOLD then
        return 0x00FF00 -- Green (good)
    else
        return 0x00FFFF -- Cyan (full)
    end
end

-- Draw the main GUI
local function drawGUI(energyPercent)
    clearScreen()
    
    -- Title
    gpu.setForeground(0x00FFFF)
    local title = "═══ LAPATRONIC SUPERCAPACITOR CONTROLLER ═══"
    local titleX = math.floor((screenWidth - unicode.len(title)) / 2) + 1
    gpu.set(titleX, 2, title)
    
    -- Current time
    gpu.setForeground(0xFFFFFF)
    local timeStr = os.date("%Y-%m-%d %H:%M:%S")
    gpu.set(screenWidth - unicode.len(timeStr), 2, timeStr)
    
    -- Energy section
    gpu.setForeground(0xFFFF00)
    gpu.set(3, 5, "ENERGY LEVEL:")
    
    -- Progress bar
    local barWidth = screenWidth - 6
    local barX = 3
    local barY = 7
    local barHeight = 3
    
    local energyColor = getEnergyColor(energyPercent)
    drawProgressBar(barX, barY, barWidth, barHeight, energyPercent, energyColor)
    
    -- Energy percentage text
    gpu.setForeground(0xFFFFFF)
    local percentText = string.format("%.1f%%", energyPercent * 100)
    local percentX = math.floor((screenWidth - unicode.len(percentText)) / 2) + 1
    gpu.set(percentX, barY + 1, percentText)
    
    -- Threshold indicators
    gpu.setForeground(0xFF0000)
    local lowPos = math.floor(barX + (barWidth - 2) * LOW_THRESHOLD) + 1
    gpu.set(lowPos, barY + barHeight + 1, "↑ 20%")
    
    gpu.setForeground(0x00FF00)
    local highPos = math.floor(barX + (barWidth - 2) * HIGH_THRESHOLD) + 1
    gpu.set(highPos, barY + barHeight + 1, "90% ↑")
    
    -- Status section
    gpu.setForeground(0xFFFF00)
    gpu.set(3, 13, "REDSTONE STATUS:")
    
    local statusColor = isRedstoneActive and 0xFF0000 or 0x808080
    local statusText = isRedstoneActive and "  ACTIVE  " or " INACTIVE "
    gpu.setForeground(0x000000)
    gpu.setBackground(statusColor)
    gpu.set(21, 13, statusText)
    gpu.setBackground(0x000000)
    
    -- Control information
    gpu.setForeground(0x808080)
    gpu.set(3, 15, "Control Logic: Enable at <20%, Disable at >90%")
    gpu.set(3, 16, "Check Interval: " .. CHECK_INTERVAL .. " seconds")
    gpu.set(3, 17, "Redstone Side: " .. REDSTONE_SIDE)
    
    -- Instructions
    gpu.setForeground(0x00FF00)
    gpu.set(3, screenHeight - 1, "Press Ctrl+C to stop the program")
end

-- Display current status (console fallback)
local function displayStatus(energyPercent)
    local energyDisplay = string.format("%.1f%%", energyPercent * 100)
    local stateDisplay = isRedstoneActive and "🔴 ON" or "⚫ OFF"
    local timeDisplay = os.date("%H:%M:%S")
    
    print(string.format("[%s] Energy: %s | Redstone: %s", timeDisplay, energyDisplay, stateDisplay))
end

--[[
HOW TO FIND COMPONENT ADDRESSES:

1. Start your computer and open the Lua console
2. Type: component.list()
3. Look for your components in the output:
   - Energy Detector: Look for "gt_energydetector" or similar
   - Redstone I/O: Look for "redstone" 
   - GPU: Look for "gpu"
   - Screen: Look for "screen"

4. Copy the full address (long string of characters) for each component
5. Update the configuration variables above with these addresses

Example addresses look like: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

You only need to set ENERGY_DETECTOR_ADDRESS and REDSTONE_IO_ADDRESS.
GPU and Screen addresses are optional (will auto-detect if not set).
--]]

-- Main program loop
local function main()
    print("=== Lapatronic Supercapacitor Controller ===")
    print(string.format("Low threshold: %.0f%% | High threshold: %.0f%%", LOW_THRESHOLD * 100, HIGH_THRESHOLD * 100))
    print(string.format("Check interval: %ds | Redstone side: %d", CHECK_INTERVAL, REDSTONE_SIDE))
    print("Press Ctrl+C to stop")
    print("")
    
    -- Initialize hardware
    initializeComponents()
    
    -- Ensure redstone starts in known state
    setRedstoneSignal(false)
    
    print("\n🚀 Starting monitoring loop...\n")
    
    while true do
        local success, energyPercent = pcall(getEnergyLevel)
        
        if success then
            updatePowerControl(energyPercent)
            
            -- Update GUI if available, otherwise fall back to console
            if gpu and screen then
                drawGUI(energyPercent)
            else
                displayStatus(energyPercent)
            end
        else
            if gpu and screen then
                gpu.setForeground(0xFF0000)
                gpu.set(3, screenHeight - 3, "⚠ Error reading energy level: " .. tostring(energyPercent))
            else
                print("⚠ Error reading energy level: " .. tostring(energyPercent))
            end
        end
        
        -- Wait for next check or handle interruption
        local eventType = event.pull(CHECK_INTERVAL, "interrupted")
        if eventType == "interrupted" then
            if gpu and screen then
                clearScreen()
                gpu.setForeground(0xFF0000)
                gpu.set(3, 3, "🛑 Program interrupted - cleaning up...")
                setRedstoneSignal(false)
                gpu.set(3, 4, "✓ Redstone signal disabled")
                gpu.set(3, 6, "Press any key to exit...")
                event.pull("key_down")
            else
                print("\n🛑 Program interrupted - cleaning up...")
                setRedstoneSignal(false)
                print("✓ Redstone signal disabled")
            end
            break
        end
    end
end

-- Error handling wrapper
local function run()
    local success, error = pcall(main)
    if not success then
        print("💥 Fatal error: " .. tostring(error))
        print("Ensure all components are properly connected!")
        -- Try to disable redstone on error
        pcall(setRedstoneSignal, false)
    end
end

-- Helper function to list all components (for configuration)
local function listComponents()
    print("=== COMPONENT DISCOVERY ===")
    print("Available components in your system:")
    print("")
    
    local components = {}
    for address, name in component.list() do
        if not components[name] then
            components[name] = {}
        end
        table.insert(components[name], address)
    end
    
    for componentType, addresses in pairs(components) do
        print(string.format("📦 %s:", componentType))
        for i, address in ipairs(addresses) do
            print(string.format("   %d. %s", i, address))
        end
        print("")
    end
    
    print("💡 Copy the full address for the components you want to use.")
    print("💡 Update the configuration section at the top of this script.")
    print("💡 Required: gt_energydetector (or similar) and redstone addresses")
    print("")
end

-- Helper function to show file listing (for debugging config issues)
local function showFiles()
    print("=== FILE SYSTEM DEBUG ===")
    print("Files in current directory:")
    
    local files = filesystem.list(".")
    for file in files do
        local path = "./" .. file
        if filesystem.isDirectory(path) then
            print("📁 " .. file)
        else
            print("📄 " .. file .. " (" .. filesystem.size(path) .. " bytes)")
        end
    end
    print("")
    
    print("Configuration file search results:")
    local configPaths = {"config.lua", "/config.lua", "/home/config.lua"}
    for _, path in ipairs(configPaths) do
        if filesystem.exists(path) then
            print("✅ Found: " .. path)
        else
            print("❌ Missing: " .. path)
        end
    end
    print("")
end

-- Check if first argument is 'list' to show component discovery
local args = {...}
if args[1] == "list" or args[1] == "components" then
    listComponents()
    return
elseif args[1] == "files" or args[1] == "debug" then
    showFiles()
    return
elseif args[1] == "help" then
    print("=== CONTROLLER HELP ===")
    print("Usage: controller [command]")
    print("")
    print("Commands:")
    print("  (no args)     - Start the power controller")
    print("  list          - Show available components and addresses")
    print("  components    - Same as 'list'")
    print("  files         - Show current directory files and config search")
    print("  debug         - Same as 'files'")
    print("  help          - Show this help message")
    print("")
    return
end

-- Start the program
run()
