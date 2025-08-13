-- Lapatronic Supercapacitor Power Controller
-- Monitors energy level and controls redstone output with hysteresis
-- Enable signal at low threshold, disable at high threshold

local component = require("component")
local event = require("event")
local os = require("os")
local unicode = require("unicode")
local filesystem = require("filesystem")

-- Configuration
local CHECK_INTERVAL = 5 -- seconds between energy checks
local LOW_THRESHOLD = 0.20 -- 20% - enable redstone signal
local HIGH_THRESHOLD = 0.90 -- 90% - disable redstone signal
local REDSTONE_SIDE = 1 -- (deprecated - now outputs to all sides automatically)

-- Component Addresses (Set these to your specific component addresses)
-- To find component addresses, run: controller list
-- or use: component.list() in lua console
local ENERGY_STORAGE_ADDRESS = "your-energy-storage-address-here" -- Adapter connected to supercapacitor controller
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
                    ENERGY_STORAGE_ADDRESS = config.ENERGY_STORAGE_ADDRESS or ENERGY_STORAGE_ADDRESS
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
local energyStorage = nil
local redstoneIO = nil
local gpu = nil
local screen = nil
local screenWidth, screenHeight = 0, 0

-- Energy tracking for usage analysis
local energyHistory = {} -- Table to store {timestamp, currentEnergy, maxEnergy}
local HISTORY_DURATION = 15 -- Keep 15 seconds of history for 10-second usage calculations
local MAX_HISTORY_SIZE = 20 -- Hard limit to prevent memory issues

-- Usage rate smoothing for stable display
local usageRateHistory = {} -- Store recent rate calculations for smoothing
local RATE_HISTORY_SIZE = 4 -- Number of recent rates to average for stable display

-- Memory management
local cycleCount = 0
local GC_INTERVAL = 20 -- Run garbage collector every 20 cycles (100 seconds)

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
    
    -- Initialize Energy Storage Adapter
    if ENERGY_STORAGE_ADDRESS and ENERGY_STORAGE_ADDRESS ~= "your-energy-storage-address-here" then
        energyStorage = component.proxy(ENERGY_STORAGE_ADDRESS)
        if not energyStorage then
            error("✗ Energy storage adapter not found at address: " .. ENERGY_STORAGE_ADDRESS)
        end
        print("✓ Found Energy Storage: " .. ENERGY_STORAGE_ADDRESS:sub(1, 8) .. "...")
    else
        error("✗ Please set ENERGY_STORAGE_ADDRESS in the configuration!\nRun 'component.list()' to find your energy storage adapter address.")
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

-- Debug flag for verbose energy logging
local DEBUG_ENERGY = false

-- Get current energy level as percentage (0.0 to 1.0)
local function getEnergyLevel()
    if not energyStorage then return 0 end
    
    -- Try different methods to get energy data from the energy storage adapter
    local currentEnergy, maxEnergy = 0, 0
    local methodUsed = "none"
    
    -- Helper function to safely call a method that might be a field
    local function safeCall(methodName)
        if energyStorage[methodName] then
            local success, result = pcall(function() return energyStorage[methodName]() end)
            if success and result ~= nil then
                if DEBUG_ENERGY then
                    print(string.format("🔍 %s() returned: %s (%s)", methodName, tostring(result), type(result)))
                end
                return result
            elseif DEBUG_ENERGY then
                print(string.format("🔍 Failed to call %s: %s", methodName, tostring(result)))
            end
        elseif DEBUG_ENERGY then
            print(string.format("🔍 Method %s not found", methodName))
        end
        return nil
    end
    
    -- Method 1: GT EU methods (most common for GT machines)
    local storedEU = safeCall("getEUStored")
    local capacityEU = safeCall("getEUCapacity")
    if storedEU and capacityEU then
        currentEnergy = storedEU
        maxEnergy = capacityEU
        methodUsed = "getEUStored/getEUCapacity"
        
        if DEBUG_ENERGY then
            print(string.format("🔍 Method 1 (GT EU): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
        end
        
    -- Method 2: Alternative GT EU methods
    else
        local storedEU2 = safeCall("getStoredEU")
        local capacityEU2 = safeCall("getCapacityEU")
        if storedEU2 and capacityEU2 then
            currentEnergy = storedEU2
            maxEnergy = capacityEU2
            methodUsed = "getStoredEU/getCapacityEU"
            
            if DEBUG_ENERGY then
                print(string.format("🔍 Method 2 (GT EU Alt): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
            end
            
        -- Method 3: Standard GT energy methods
        else
            local energyStored = safeCall("getEnergyStored")
            local maxEnergyStored = safeCall("getMaxEnergyStored")
            if energyStored and maxEnergyStored then
                currentEnergy = energyStored
                maxEnergy = maxEnergyStored
                methodUsed = "getEnergyStored/getMaxEnergyStored"
                
                if DEBUG_ENERGY then
                    print(string.format("🔍 Method 3 (GT Energy): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
                end
                
            -- Method 4: Alternative energy methods
            else
                local stored = safeCall("getStored")
                local capacity = safeCall("getCapacity")
                if stored and capacity then
                    currentEnergy = stored
                    maxEnergy = capacity
                    methodUsed = "getStored/getCapacity"
                    
                    if DEBUG_ENERGY then
                        print(string.format("🔍 Method 4 (Alternative): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
                    end
                    
                -- Method 5: Try energy tank methods (some GT blocks use tank-like systems)
                else
                    local tankInfo = safeCall("tank")
                    if tankInfo and type(tankInfo) == "table" and tankInfo.amount and tankInfo.capacity then
                        currentEnergy = tankInfo.amount
                        maxEnergy = tankInfo.capacity
                        methodUsed = "tank() method"
                        
                        if DEBUG_ENERGY then
                            print(string.format("🔍 Method 5 (Tank): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
                        end
                        
                    -- Method 6: Try getting tank info by index
                    else
                        local tankInfo2 = safeCall("getTankInfo")
                        if tankInfo2 and type(tankInfo2) == "table" and tankInfo2[1] then
                            currentEnergy = tankInfo2[1].amount or 0
                            maxEnergy = tankInfo2[1].capacity or 0
                            methodUsed = "getTankInfo(1)"
                            
                            if DEBUG_ENERGY then
                                print(string.format("🔍 Method 6 (getTankInfo): current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- If we still haven't found energy values, mark as no method found
    if currentEnergy == 0 and maxEnergy == 0 then
        -- List available methods for debugging
        print("⚠ Warning: No recognized energy methods found on energy storage adapter")
        print("Available fields that look like methods:")
        for methodName, value in pairs(energyStorage) do
            if string.match(methodName, "^get") or string.match(methodName, "^set") or string.match(methodName, "^is") then
                print("  - " .. methodName .. " (" .. type(value) .. ")")
            end
        end
        print("")
        print("💡 Try running 'controller test-energy' to test all methods")
        return 0
    end
    
    if DEBUG_ENERGY then
        print(string.format("🔍 Using method: %s", methodUsed))
        print(string.format("🔍 Raw values: current=%s, max=%s", tostring(currentEnergy), tostring(maxEnergy)))
    end
    
    if maxEnergy == 0 then 
        print("⚠ Warning: Maximum energy capacity is 0")
        if DEBUG_ENERGY then
            print("🔍 This usually means the method isn't returning valid data")
        end
        return 0 
    end
    
    local percentage = currentEnergy / maxEnergy
    
    if DEBUG_ENERGY then
        print(string.format("🔍 Calculated percentage: %.3f (%.1f%%)", percentage, percentage * 100))
    end
    
    return percentage
end

-- Update energy history for usage tracking (optimized)
local function updateEnergyHistory(currentEnergy, maxEnergy)
    local currentTime = os.time()
    
    -- Add new entry
    energyHistory[#energyHistory + 1] = {
        timestamp = currentTime,
        currentEnergy = currentEnergy,
        maxEnergy = maxEnergy
    }
    
    -- Efficient cleanup: remove old entries from front
    local cutoffTime = currentTime - HISTORY_DURATION
    local removeCount = 0
    
    for i = 1, #energyHistory do
        if energyHistory[i].timestamp >= cutoffTime then
            break
        end
        removeCount = removeCount + 1
    end
    
    -- Remove old entries in batch (more efficient than table.remove in loop)
    if removeCount > 0 then
        for i = 1, #energyHistory - removeCount do
            energyHistory[i] = energyHistory[i + removeCount]
        end
        for i = #energyHistory - removeCount + 1, #energyHistory do
            energyHistory[i] = nil
        end
    end
    
    -- Hard limit check to prevent runaway memory usage
    if #energyHistory > MAX_HISTORY_SIZE then
        local excess = #energyHistory - MAX_HISTORY_SIZE
        for i = 1, #energyHistory - excess do
            energyHistory[i] = energyHistory[i + excess]
        end
        for i = #energyHistory - excess + 1, #energyHistory do
            energyHistory[i] = nil
        end
    end
end

-- Calculate current EU usage rate (EU/second) over a 10-second period
local function calculateUsageRate()
    if #energyHistory < 2 then
        return 0, "insufficient data"
    end
    
    local current = energyHistory[#energyHistory]
    local targetPeriod = 10 -- seconds
    local oldestAcceptable = current.timestamp - targetPeriod
    
    -- Find the best entry that's approximately 10 seconds old
    local oldEntry = nil
    local bestTimeDiff = math.huge
    
    for i = 1, #energyHistory - 1 do
        local entry = energyHistory[i]
        local timeDiff = math.abs((current.timestamp - entry.timestamp) - targetPeriod)
        
        -- Prefer entries closer to exactly 10 seconds ago
        if timeDiff < bestTimeDiff and (current.timestamp - entry.timestamp) >= 3 then -- At least 3 seconds difference
            bestTimeDiff = timeDiff
            oldEntry = entry
        end
    end
    
    -- Fallback: if we don't have good 10-second data, use the oldest available
    if not oldEntry and #energyHistory >= 2 then
        oldEntry = energyHistory[1]
    end
    
    if not oldEntry then
        return 0, "insufficient data"
    end
    
    local actualTimeDiff = current.timestamp - oldEntry.timestamp
    if actualTimeDiff <= 0 then
        return 0, "insufficient time"
    end
    
    local energyDiff = current.currentEnergy - oldEntry.currentEnergy
    local rate = energyDiff / actualTimeDiff
    
    return rate, "ok"
end

-- Round values to ballpark figures to reduce fluctuation display
local function roundToBallpark(rate)
    local absRate = math.abs(rate)
    local sign = rate >= 0 and 1 or -1
    
    if absRate < 1000 then
        -- Under 1 kEU/s: round to nearest 10 EU/s
        return sign * math.floor((absRate + 5) / 10) * 10
    elseif absRate < 10000 then
        -- Under 10 kEU/s: round to nearest 100 EU/s  
        return sign * math.floor((absRate + 50) / 100) * 100
    elseif absRate < 100000 then
        -- Under 100 kEU/s: round to nearest 1 kEU/s
        return sign * math.floor((absRate + 500) / 1000) * 1000
    elseif absRate < 1000000 then
        -- Under 1 MEU/s: round to nearest 10 kEU/s
        return sign * math.floor((absRate + 5000) / 10000) * 10000
    elseif absRate < 10000000 then
        -- Under 10 MEU/s: round to nearest 100 kEU/s
        return sign * math.floor((absRate + 50000) / 100000) * 100000
    else
        -- Above 10 MEU/s: round to nearest 1 MEU/s
        return sign * math.floor((absRate + 500000) / 1000000) * 1000000
    end
end

-- Update usage rate history for smoothing (optimized)
local function updateUsageRateHistory(rate, status)
    if status == "ok" then
        -- Add new rate to history
        usageRateHistory[#usageRateHistory + 1] = rate
        
        -- Keep only recent rates (more efficient than table.remove)
        if #usageRateHistory > RATE_HISTORY_SIZE then
            for i = 1, RATE_HISTORY_SIZE do
                usageRateHistory[i] = usageRateHistory[i + (#usageRateHistory - RATE_HISTORY_SIZE)]
            end
            for i = RATE_HISTORY_SIZE + 1, #usageRateHistory do
                usageRateHistory[i] = nil
            end
        end
    end
end

-- Get smoothed usage rate for display (ballpark estimation)
local function getSmoothedUsageRate()
    local rawRate, status = calculateUsageRate()
    
    -- Update smoothing history
    updateUsageRateHistory(rawRate, status)
    
    if status ~= "ok" then
        return rawRate, status
    end
    
    if #usageRateHistory == 0 then
        return rawRate, status
    end
    
    -- Calculate weighted average (more recent rates have slightly more weight)
    local totalWeight = 0
    local weightedSum = 0
    
    for i, rate in ipairs(usageRateHistory) do
        local weight = i -- Simple linear weighting: 1, 2, 3, 4...
        weightedSum = weightedSum + (rate * weight)
        totalWeight = totalWeight + weight
    end
    
    local smoothedRate = weightedSum / totalWeight
    
    -- Apply ballpark rounding to reduce minor fluctuations
    local ballparkRate = roundToBallpark(smoothedRate)
    
    return ballparkRate, "ok"
end

-- Memory management and monitoring (with OpenComputers compatibility)
local function manageMemory()
    cycleCount = cycleCount + 1
    
    -- Check if garbage collection is available
    if not collectgarbage then
        -- Fallback for environments without collectgarbage
        if cycleCount % GC_INTERVAL == 0 then
            print("🧹 Memory cleanup: (GC not available in this environment)")
            
            -- Reset cycle counter to prevent overflow
            if cycleCount > 1000 then
                cycleCount = 0
            end
        end
        return
    end
    
    -- Run garbage collection periodically
    if cycleCount % GC_INTERVAL == 0 then
        local memBefore = collectgarbage("count")
        collectgarbage("collect")
        local memAfter = collectgarbage("count")
        
        print(string.format("🧹 Memory cleanup: %.1f KB → %.1f KB (freed %.1f KB)", 
              memBefore, memAfter, memBefore - memAfter))
        
        -- Reset cycle counter to prevent overflow
        if cycleCount > 1000 then
            cycleCount = 0
        end
    end
    
    -- Emergency cleanup if memory gets too high
    local currentMemory = collectgarbage("count")
    if currentMemory > 8192 then -- 8MB threshold
        print("⚠️ High memory usage detected (" .. math.floor(currentMemory) .. " KB), performing emergency cleanup...")
        
        -- Clear excess history if needed
        if #energyHistory > 10 then
            for i = 11, #energyHistory do
                energyHistory[i] = nil
            end
            print("   Trimmed energy history to 10 entries")
        end
        
        if #usageRateHistory > 2 then
            for i = 3, #usageRateHistory do
                usageRateHistory[i] = nil
            end
            print("   Trimmed usage rate history to 2 entries")
        end
        
        collectgarbage("collect")
        local afterEmergency = collectgarbage("count")
        print("   Emergency cleanup completed: " .. math.floor(afterEmergency) .. " KB")
    end
end

-- Format EU values with appropriate units (optimized)
local function formatEU(euValue)
    local absValue = math.abs(euValue)
    if absValue >= 1000000000 then
        local geu = euValue / 1000000000
        return math.floor(geu * 100 + 0.5) / 100 .. " GEU"
    elseif absValue >= 1000000 then
        local meu = euValue / 1000000
        return math.floor(meu * 100 + 0.5) / 100 .. " MEU"
    elseif absValue >= 1000 then
        local keu = euValue / 1000
        return math.floor(keu * 100 + 0.5) / 100 .. " kEU"
    else
        return math.floor(euValue + 0.5) .. " EU"
    end
end

-- Get EU input/output rates from GT machine (if available) with error handling
local function getEUInOutRates()
    if not energyStorage then
        return nil, nil
    end
    
    local safeCall = function(methodName)
        if energyStorage[methodName] then
            local success, result = pcall(function() return energyStorage[methodName]() end)
            if success and result ~= nil then
                return result
            elseif not success then
                print(string.format("⚠ Warning: Failed to call %s: %s", methodName, tostring(result)))
            end
        end
        return nil
    end
    
    local euIn, euOut = nil, nil
    
    -- Try various GT methods for input/output rates
    euIn = safeCall("getEUInputAverage") or safeCall("getAverageInputVoltage") or 
           safeCall("getInputVoltage") or safeCall("getEUInput") or safeCall("getInputEU")
    
    euOut = safeCall("getEUOutputAverage") or safeCall("getAverageOutputVoltage") or 
            safeCall("getOutputVoltage") or safeCall("getEUOutput") or safeCall("getOutputEU")
    
    -- Try getSensorInformation which might contain input/output data
    if not euIn or not euOut then
        local sensorInfo = safeCall("getSensorInformation")
        if sensorInfo and type(sensorInfo) == "table" then
            -- GT sensor information often has input/output as array elements
            -- Common patterns: [1] = input rate, [2] = output rate
            for i, info in ipairs(sensorInfo) do
                local infoStr = tostring(info)
                if string.find(infoStr, "Input") or string.find(infoStr, "input") then
                    local rate = tonumber(string.match(infoStr, "([%d%.]+)"))
                    if rate then euIn = rate end
                elseif string.find(infoStr, "Output") or string.find(infoStr, "output") then
                    local rate = tonumber(string.match(infoStr, "([%d%.]+)"))
                    if rate then euOut = rate end
                end
            end
        end
    end
    
    return euIn, euOut
end

-- Set redstone signal state with error handling (all sides)
local function setRedstoneSignal(active)
    if not redstoneIO then 
        print("⚠ Warning: No redstone I/O component available")
        return false
    end
    
    local strength = active and 15 or 0
    local success, error = pcall(function()
        -- Set all sides (0-5: down, up, north, south, west, east)
        for side = 0, 5 do
            redstoneIO.setOutput(side, strength)
        end
    end)
    
    if success then
        isRedstoneActive = active
        local status = active and "ENABLED" or "DISABLED"
        print(string.format("🔴 Redstone signal %s on ALL SIDES (strength: %d)", status, strength))
        return true
    else
        print(string.format("❌ Failed to set redstone signal on all sides: %s", tostring(error)))
        print("   Will retry on next cycle...")
        return false
    end
end

-- Main control logic with hysteresis and error handling
local function updatePowerControl(energyPercent)
    local prevState = isRedstoneActive
    
    if not isRedstoneActive and energyPercent <= LOW_THRESHOLD then
        -- Energy is low and signal is off -> turn on
        print(string.format("⚡ Energy low (%.1f%%) - Attempting to activate power systems", energyPercent * 100))
        local success = setRedstoneSignal(true)
        if not success then
            print("   ⚠ Redstone activation failed, will retry next cycle")
        end
        
    elseif isRedstoneActive and energyPercent >= HIGH_THRESHOLD then
        -- Energy is high and signal is on -> turn off
        print(string.format("🔋 Energy sufficient (%.1f%%) - Attempting to deactivate power systems", energyPercent * 100))
        local success = setRedstoneSignal(false)
        if not success then
            print("   ⚠ Redstone deactivation failed, will retry next cycle")
        end
    end
    
    -- No change in middle range - this is the hysteresis behavior
end

-- Safe GPU operation wrapper
local function safeGPU(operation, ...)
    if not gpu or not screen then return false end
    
    local success, error = pcall(operation, ...)
    if not success then
        print(string.format("❌ GPU operation failed: %s", tostring(error)))
        return false
    end
    return true
end

-- Clear screen with background (with error handling)
local function clearScreen()
    if not gpu or not screen then return false end
    
    local success = pcall(function()
        gpu.setBackground(0x000000) -- Black background
        gpu.setForeground(0x00A6FF) -- Light blue text
        gpu.fill(1, 1, screenWidth, screenHeight, " ")
    end)
    
    if not success then
        print("❌ Failed to clear screen, GUI may not display correctly")
        return false
    end
    return true
end

-- Draw a progress bar
local function drawProgressBar(x, y, width, height, percent, color)
    -- Draw border
    gpu.setForeground(0x00A6FF)
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
        return 0xFF00FF -- Magenta (low)
    elseif percent <= HIGH_THRESHOLD then
        return 0x00FF00 -- Green (good)
    else
        return 0x00FF00 -- Green (above high threshold)
    end
end

-- Draw the main GUI (with error handling)
local function drawGUI(energyPercent, currentEnergy, maxEnergy)
    -- Check if GPU/screen are available
    if not gpu or not screen then
        print("⚠ Warning: GUI not available, GPU or screen missing")
        return false
    end
    
    -- Wrap entire GUI drawing in error handling
    local success, error = pcall(function()
        clearScreen()
    
    -- Title
    gpu.setForeground(0x00FFFF)
    local title = "═══ LAPATRONIC SUPERCAPACITOR CONTROLLER ═══"
    local titleX = math.floor((screenWidth - unicode.len(title)) / 2) + 1
    gpu.set(titleX, 2, title)
    
    -- Current time
    gpu.setForeground(0x00A6FF)
    local timeStr = os.date("%Y-%m-%d %H:%M:%S")
    gpu.set(screenWidth - unicode.len(timeStr), 2, timeStr)
    
    -- Energy section
    gpu.setForeground(0xFF00FF)
    gpu.set(3, 5, "ENERGY LEVEL:")
    
    -- Progress bar
    local barWidth = screenWidth - 6
    local barX = 3
    local barY = 7
    local barHeight = 6  -- Double the height from 3 to 6
    
    local energyColor = getEnergyColor(energyPercent)
    drawProgressBar(barX, barY, barWidth, barHeight, energyPercent, energyColor)
    
    -- Energy percentage text (moved outside and above the progress bar)
    gpu.setForeground(0x00A6FF)
    local percentText = string.format("%.1f%%", energyPercent * 100)
    local percentX = math.floor((screenWidth - unicode.len(percentText)) / 2) + 1
    gpu.set(percentX, barY - 1, percentText)  -- Position above the bar instead of inside
    
    -- Threshold indicators
    gpu.setForeground(0xFF0000)
    local lowPos = math.floor(barX + (barWidth - 2) * LOW_THRESHOLD) + 1
    gpu.set(lowPos, barY + barHeight + 1, "↑ " .. math.floor(LOW_THRESHOLD * 100) .. "%")
    
    gpu.setForeground(0x00FF00)
    local highPos = math.floor(barX + (barWidth - 2) * HIGH_THRESHOLD) + 1
    gpu.set(highPos, barY + barHeight + 1, math.floor(HIGH_THRESHOLD * 100) .. "% ↑")
    
    -- Energy details and usage analysis
    gpu.setForeground(0x00A6FF)
    gpu.set(3, barY + barHeight + 3, "Current: " .. formatEU(currentEnergy) .. " / " .. formatEU(maxEnergy))
    
    -- Calculate variables for display
    local usageRate, status = getSmoothedUsageRate() -- For stable display
    local euIn, euOut = getEUInOutRates()
    
    local currentLine = barY + barHeight + 4
    
    -- Always display EU input/output rates first
    gpu.setForeground(0x00A6FF) -- Light blue for input
    local euInText = "Average EU In: "
    if euIn and euIn ~= 0 then
        euInText = euInText .. formatEU(euIn) .. "/s"
    elseif euIn == 0 then
        euInText = euInText .. "0 EU/s"
    else
        euInText = euInText .. "N/A"
    end
    gpu.set(3, currentLine, euInText)
    currentLine = currentLine + 1
    
    gpu.setForeground(0xFFB366) -- Light orange for output
    local euOutText = "Average EU Out: "
    if euOut and euOut ~= 0 then
        euOutText = euOutText .. formatEU(euOut) .. "/s"
    elseif euOut == 0 then
        euOutText = euOutText .. "0 EU/s"
    else
        euOutText = euOutText .. "N/A"
    end
    gpu.set(3, currentLine, euOutText)
    currentLine = currentLine + 1
    
    -- Add empty line
    currentLine = currentLine + 1
    
    -- Display usage information after EU rates
    if status == "ok" then
        if usageRate < 0 then
            -- Consuming energy (any negative rate)
            gpu.setForeground(0xFF8080) -- Light red
            gpu.set(3, currentLine, "Usage: " .. formatEU(-usageRate) .. "/s")
            currentLine = currentLine + 1
        else
            -- Charging energy (positive rate or zero)
            gpu.setForeground(0x80FF80) -- Light green
            gpu.set(3, currentLine, "Charging: " .. formatEU(usageRate) .. "/s")
            currentLine = currentLine + 1
        end
    else
        gpu.setForeground(0x808080) -- Gray
        if status == "insufficient data" then
            gpu.set(3, currentLine, "Stabilizing usage rate... (" .. #usageRateHistory .. "/" .. RATE_HISTORY_SIZE .. " samples)")
        else
            gpu.set(3, currentLine, "Energy rate: " .. formatEU(usageRate) .. "/s")
        end
        currentLine = currentLine + 1
    end
    
    -- Status section (positioned after energy info)
    local statusY = currentLine + 1
    gpu.setForeground(0xFF00FF)
    gpu.set(3, statusY, "REDSTONE STATUS:")
    
    local statusColor = isRedstoneActive and 0xFF0000 or 0x808080
    local statusText = isRedstoneActive and "  ACTIVE  " or " INACTIVE "
    gpu.setForeground(0x000000)
    gpu.setBackground(statusColor)
    gpu.set(21, statusY, statusText)
    gpu.setBackground(0x000000)
    
        -- Control information
        gpu.setForeground(0x808080)
        gpu.set(3, statusY + 2, "Control Logic: Enable at <" .. math.floor(LOW_THRESHOLD * 100) .. "%, Disable at >" .. math.floor(HIGH_THRESHOLD * 100) .. "%")
        gpu.set(3, statusY + 3, "Check Interval: " .. CHECK_INTERVAL .. " seconds")
        gpu.set(3, statusY + 4, "Redstone Output: All Sides")
        
        -- Instructions
        gpu.setForeground(0x00A6FF)
        gpu.set(3, screenHeight - 1, "Press Ctrl+C to stop the program")
    end)
    
    if not success then
        print(string.format("❌ GUI drawing failed: %s", tostring(error)))
        print("   Continuing with console-only mode...")
        return false
    end
    
    return true
end

-- Display current status (console fallback) - optimized
local function displayStatus(energyPercent)
    -- Reduce string.format calls by using concatenation where possible
    local energyDisplay = math.floor(energyPercent * 1000 + 0.5) / 10 .. "%"
    local stateDisplay = isRedstoneActive and "🔴 ON" or "⚫ OFF"
    local timeDisplay = os.date("%H:%M:%S")
    
    -- Get usage information (always displayed)  
    local usageInfo
    local usageRate, status = getSmoothedUsageRate()
    if status == "ok" then
        if usageRate < 0 then
            usageInfo = " | Usage: " .. formatEU(-usageRate) .. "/s"
        else
            usageInfo = " | Charging: " .. formatEU(usageRate) .. "/s"
        end
    elseif status == "insufficient data" then
        usageInfo = " | Stabilizing..."
    else
        usageInfo = " | Rate: " .. formatEU(usageRate) .. "/s"
    end
    
    -- Use concatenation instead of string.format for better performance
    print("[" .. timeDisplay .. "] Energy: " .. energyDisplay .. " | Redstone: " .. stateDisplay .. usageInfo)
    
    -- Always display EU in/out rates (on separate line for clarity)
    local euIn, euOut = getEUInOutRates()
    local inText, outText
    
    -- Format EU In rate
    if euIn and euIn ~= 0 then
        inText = formatEU(euIn) .. "/s"
    elseif euIn == 0 then
        inText = "0 EU/s"
    else
        inText = "N/A"
    end
    
    -- Format EU Out rate
    if euOut and euOut ~= 0 then
        outText = formatEU(euOut) .. "/s"
    elseif euOut == 0 then
        outText = "0 EU/s"
    else
        outText = "N/A"
    end
    
    print(string.format("[%s] EU In: %s | EU Out: %s", timeDisplay, inText, outText))
end

--[[
HOW TO FIND COMPONENT ADDRESSES:

1. Start your computer and open the Lua console
2. Type: component.list()
3. Look for your components in the output:
   - Energy Storage Adapter: Look for "adapter" (connected to your supercapacitor controller)
   - Redstone I/O: Look for "redstone" 
   - GPU: Look for "gpu"
   - Screen: Look for "screen"

4. Copy the full address (long string of characters) for each component
5. Update the configuration variables above with these addresses

Example addresses look like: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

You only need to set ENERGY_STORAGE_ADDRESS and REDSTONE_IO_ADDRESS.
GPU and Screen addresses are optional (will auto-detect if not set).

IMPORTANT: The energy storage adapter must be connected directly to your supercapacitor controller
to access its energy methods.
--]]

-- Main program loop
local function main()
    print("=== Lapatronic Supercapacitor Controller ===")
    print(string.format("Low threshold: %.0f%% | High threshold: %.0f%%", LOW_THRESHOLD * 100, HIGH_THRESHOLD * 100))
    print(string.format("Check interval: %ds | Redstone output: All sides", CHECK_INTERVAL))
    print("Memory optimization: Enabled | GC interval: " .. GC_INTERVAL .. " cycles")
    if collectgarbage then
        print("Initial memory usage: " .. math.floor(collectgarbage("count")) .. " KB")
    else
        print("Initial memory usage: (GC not available in this environment)")
    end
    print("Press Ctrl+C to stop")
    print("")
    
    -- Initialize hardware
    initializeComponents()
    
    -- Ensure redstone starts in known state
    setRedstoneSignal(false)
    
    print("\n🚀 Starting monitoring loop...\n")
    
    while true do
        local success, energyPercent = pcall(getEnergyLevel)
        
        if success and energyPercent then
            -- Update power control with error handling
            local controlSuccess, controlError = pcall(updatePowerControl, energyPercent)
            if not controlSuccess then
                print(string.format("❌ Power control update failed: %s", tostring(controlError)))
                print("   Continuing monitoring...")
            end
            
            -- Get raw energy values for usage tracking and display
            local currentEnergy, maxEnergy = 0, 0
            local energySuccess, energyError = pcall(function()
                if energyStorage then
                    local safeCall = function(methodName)
                        if energyStorage[methodName] then
                            local callSuccess, result = pcall(function() return energyStorage[methodName]() end)
                            if callSuccess and result ~= nil then
                                return result
                            end
                        end
                        return nil
                    end
                    
                    -- Try to get raw energy values using the same methods as getEnergyLevel
                    local storedEU = safeCall("getEUStored")
                    local capacityEU = safeCall("getEUCapacity")
                    if storedEU and capacityEU then
                        currentEnergy = storedEU
                        maxEnergy = capacityEU
                    else
                        -- Fallback: calculate from percentage if direct methods fail
                        currentEnergy = energyPercent * 1000000000 -- Assume typical capacity for calculation
                        maxEnergy = 1000000000
                    end
                end
            end)
            
            if energySuccess then
                -- Update energy history for usage tracking
                local historySuccess, historyError = pcall(updateEnergyHistory, currentEnergy, maxEnergy)
                if not historySuccess then
                    print(string.format("⚠ Warning: Failed to update energy history: %s", tostring(historyError)))
                end
            else
                print(string.format("⚠ Warning: Failed to get detailed energy values: %s", tostring(energyError)))
                currentEnergy, maxEnergy = 0, 0
            end
            
            -- Update GUI if available, otherwise fall back to console
            if gpu and screen then
                local guiSuccess = drawGUI(energyPercent, currentEnergy, maxEnergy)
                if not guiSuccess then
                    -- Fall back to console if GUI fails
                    print("   Falling back to console display...")
                    displayStatus(energyPercent)
                end
            else
                displayStatus(energyPercent)
            end
        else
            -- Energy reading failed - display error and continue
            local errorMsg = string.format("⚠ Error reading energy level: %s", tostring(energyPercent))
            print(errorMsg)
            print("   Retrying on next cycle...")
            
            if gpu and screen then
                local success = pcall(function()
                    gpu.setForeground(0xFF0000)
                    gpu.set(3, screenHeight - 3, errorMsg)
                end)
                if not success then
                    print("⚠ Warning: Could not display error on screen")
                end
            end
        end
        
        -- Memory management
        manageMemory()
        
        -- Wait for next check or handle interruption
        local eventType = event.pull(CHECK_INTERVAL, "interrupted")
        if eventType == "interrupted" then
            print("\n🛑 Program interrupted - cleaning up...")
            
            -- Safely disable redstone signal
            local success = setRedstoneSignal(false)
            if success then
                print("✓ Redstone signal disabled")
            else
                print("⚠ Warning: Could not disable redstone signal")
            end
            
            if gpu and screen then
                local guiSuccess = pcall(function()
                    clearScreen()
                    gpu.setForeground(0xFF0000)
                    gpu.set(3, 3, "🛑 Program interrupted - cleaning up...")
                    if success then
                        gpu.set(3, 4, "✓ Redstone signal disabled")
                    else
                        gpu.set(3, 4, "⚠ Could not disable redstone signal")
                    end
                    gpu.set(3, 6, "Press any key to exit...")
                end)
                
                if guiSuccess then
                    event.pull("key_down")
                else
                    print("⚠ Warning: Could not display shutdown message on screen")
                    print("Press Ctrl+C again to force exit...")
                end
            end
            
            -- Clear memory before exit
            energyHistory = nil
            usageRateHistory = nil
            if collectgarbage then
                collectgarbage("collect")
                print("✓ Memory cleared")
            else
                print("✓ Tables cleared (GC not available)")
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
        
        -- Try to safely disable redstone on fatal error
        print("Attempting emergency redstone shutdown...")
        local redstoneSuccess = pcall(setRedstoneSignal, false)
        if redstoneSuccess then
            print("✓ Emergency redstone shutdown successful")
        else
            print("⚠ Warning: Emergency redstone shutdown failed")
            print("   Please manually check redstone state!")
        end
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
    print("💡 Required: energy storage adapter (connected to supercapacitor) and redstone addresses")
    print("💡 Make sure your energy storage adapter is placed directly adjacent to the supercapacitor controller!")
    print("")
end

-- Helper function to inspect adapter connectivity
local function inspectAdapter()
    print("=== ADAPTER CONNECTIVITY INSPECTION ===")
    
    if not ENERGY_STORAGE_ADDRESS or ENERGY_STORAGE_ADDRESS == "your-energy-storage-address-here" then
        print("❌ ENERGY_STORAGE_ADDRESS not configured!")
        print("Please set your adapter address in the configuration.")
        return false
    end
    
    print("Checking adapter at address: " .. ENERGY_STORAGE_ADDRESS)
    print("")
    
    -- Check if component exists
    if not component.proxy(ENERGY_STORAGE_ADDRESS) then
        print("❌ COMPONENT NOT FOUND!")
        print("The component at address " .. ENERGY_STORAGE_ADDRESS .. " doesn't exist.")
        print("")
        print("Run 'controller list' to see available components.")
        print("Make sure you copied the correct adapter address.")
        return false
    end
    
    local adapter = component.proxy(ENERGY_STORAGE_ADDRESS)
    print("✅ Component found!")
    print("Component type: " .. (adapter.type or "unknown"))
    print("")
    
    -- List all methods/fields available on the adapter
    print("🔍 All available methods and fields:")
    local methodCount = 0
    local fieldCount = 0
    local callableFields = 0
    
    for name, value in pairs(adapter) do
        if type(value) == "function" then
            print("   📝 " .. name .. "() - function")
            methodCount = methodCount + 1
        else
            print("   📄 " .. name .. " = " .. tostring(value) .. " (" .. type(value) .. ")")
            fieldCount = fieldCount + 1
            
            -- Check if this field might be a callable method (GT style)
            if string.match(name, "^get") or string.match(name, "^set") or string.match(name, "^is") then
                -- Try calling it to see if it's actually a method
                local success, result = pcall(function() return adapter[name]() end)
                if success then
                    print("      ✅ Callable as method! Returns: " .. tostring(result))
                    callableFields = callableFields + 1
                else
                    print("      ❌ Not callable: " .. tostring(result))
                end
            end
        end
    end
    
    print("")
    print("Summary:")
    print("   True methods: " .. methodCount)
    print("   Fields: " .. fieldCount)
    print("   Callable fields (GT methods): " .. callableFields)
    print("")
    
    if methodCount == 0 and callableFields == 0 then
        print("🚨 NO CALLABLE METHODS FOUND!")
        print("This means the adapter is not connected to any block that exposes energy methods.")
        print("")
        print("Troubleshooting steps:")
        print("   1. Make sure the adapter is placed directly adjacent to the supercapacitor controller")
        print("   2. Try placing the adapter on different sides of the supercapacitor controller")
        print("   3. Check that the supercapacitor controller is the right type (Lapatronic)")
        print("   4. Verify the supercapacitor controller is properly formed/multiblock complete")
        print("   5. Try breaking and replacing the adapter")
        return false
    else
        print("✅ Found callable methods! GT machines often expose methods as fields.")
        print("This is normal for GT machine adapters.")
    end
    
    return true
end

-- Helper function to test energy methods (for debugging energy issues)
local function testEnergyMethods()
    print("=== ENERGY METHOD TESTING ===")
    
    if not energyStorage then
        print("❌ No energy storage adapter configured!")
        print("Please set ENERGY_STORAGE_ADDRESS and restart.")
        return
    end
    
    print("Testing all available energy methods on your energy storage adapter...")
    print("Address: " .. ENERGY_STORAGE_ADDRESS:sub(1, 8) .. "...")
    print("")
    
    -- First, inspect the adapter connectivity
    if not inspectAdapter() then
        print("❌ Adapter inspection failed. Cannot proceed with energy testing.")
        return
    end
    
    local methodsTested = 0
    local workingMethods = 0
    
    -- Test Method 1: GT Energy methods
    if energyStorage.getEnergyStored and energyStorage.getMaxEnergyStored then
        methodsTested = methodsTested + 1
        print("🧪 Testing Method 1: getEnergyStored/getMaxEnergyStored")
        local success1, current = pcall(energyStorage.getEnergyStored)
        local success2, max = pcall(energyStorage.getMaxEnergyStored)
        
        if success1 and success2 then
            print(string.format("   ✅ Current Energy: %s", tostring(current)))
            print(string.format("   ✅ Max Energy: %s", tostring(max)))
            if current and max and max > 0 then
                print(string.format("   ✅ Percentage: %.1f%%", (current/max)*100))
                workingMethods = workingMethods + 1
            else
                print("   ❌ Invalid values returned")
            end
        else
            print("   ❌ Method calls failed")
            print("   Error current: " .. tostring(current))
            print("   Error max: " .. tostring(max))
        end
        print("")
    end
    
    -- Test Method 2: Alternative methods
    if energyStorage.getStored and energyStorage.getCapacity then
        methodsTested = methodsTested + 1
        print("🧪 Testing Method 2: getStored/getCapacity")
        local success1, current = pcall(energyStorage.getStored)
        local success2, max = pcall(energyStorage.getCapacity)
        
        if success1 and success2 then
            print(string.format("   ✅ Current Stored: %s", tostring(current)))
            print(string.format("   ✅ Capacity: %s", tostring(max)))
            if current and max and max > 0 then
                print(string.format("   ✅ Percentage: %.1f%%", (current/max)*100))
                workingMethods = workingMethods + 1
            else
                print("   ❌ Invalid values returned")
            end
        else
            print("   ❌ Method calls failed")
            print("   Error current: " .. tostring(current))
            print("   Error max: " .. tostring(max))
        end
        print("")
    end
    
    -- Test Method 3: Tank method
    if energyStorage.tank and type(energyStorage.tank) == "function" then
        methodsTested = methodsTested + 1
        print("🧪 Testing Method 3: tank()")
        local success, tankInfo = pcall(energyStorage.tank)
        
        if success then
            print("   ✅ Tank method executed successfully")
            print("   Tank Info: " .. tostring(tankInfo))
            if tankInfo and type(tankInfo) == "table" then
                print("   Tank fields:")
                for key, value in pairs(tankInfo) do
                    print(string.format("     %s: %s", tostring(key), tostring(value)))
                end
                if tankInfo.amount and tankInfo.capacity and tankInfo.capacity > 0 then
                    print(string.format("   ✅ Percentage: %.1f%%", (tankInfo.amount/tankInfo.capacity)*100))
                    workingMethods = workingMethods + 1
                end
            end
        else
            print("   ❌ Tank method failed")
            print("   Error: " .. tostring(tankInfo))
        end
        print("")
    end
    
    -- Test Method 4: getTankInfo
    if energyStorage.getTankInfo and type(energyStorage.getTankInfo) == "function" then
        methodsTested = methodsTested + 1
        print("🧪 Testing Method 4: getTankInfo(1)")
        local success, tankInfo = pcall(energyStorage.getTankInfo, 1)
        
        if success then
            print("   ✅ getTankInfo method executed successfully")
            print("   Tank Info: " .. tostring(tankInfo))
            if tankInfo and type(tankInfo) == "table" and tankInfo[1] then
                print("   Tank[1] fields:")
                for key, value in pairs(tankInfo[1]) do
                    print(string.format("     %s: %s", tostring(key), tostring(value)))
                end
                local amount = tankInfo[1].amount
                local capacity = tankInfo[1].capacity
                if amount and capacity and capacity > 0 then
                    print(string.format("   ✅ Percentage: %.1f%%", (amount/capacity)*100))
                    workingMethods = workingMethods + 1
                end
            end
        else
            print("   ❌ getTankInfo method failed")
            print("   Error: " .. tostring(tankInfo))
        end
        print("")
    end
    
    -- Test GT-specific methods if this is a gt_machine
    if energyStorage.type == "gt_machine" then
        print("🔧 Detected GT Machine - Testing GT-specific methods:")
        print("")
        
        -- Test GT machine specific energy methods
        local gtMethods = {
            "getEUStored", "getEUCapacity", "getEUMaxStored", "getEUOutputVoltage", "getEUInputVoltage",
            "getStoredEU", "getCapacityEU", "getMaxStoredEU", "getOutputEU", "getInputEU",
            "getSensorInformation", "getMetaTileEntity", "getEnergyStored", "getMaxEnergyStored",
            "getEnergyCapacity", "getStoredEnergy", "getMaxEnergy", "getEnergyContainer",
            "getInfoData", "getSensorData", "getEUInputAverage", "getEUOutputAverage",
            "getAverageInputVoltage", "getAverageOutputVoltage", "getInputVoltage", "getOutputVoltage"
        }
        
        for _, methodName in ipairs(gtMethods) do
            if energyStorage[methodName] then
                print("🧪 Testing GT method: " .. methodName .. " (" .. type(energyStorage[methodName]) .. ")")
                local success, result = pcall(function() return energyStorage[methodName]() end)
                if success then
                    print("   ✅ Success: " .. tostring(result))
                    if type(result) == "table" then
                        print("   📋 Table contents:")
                        for key, value in pairs(result) do
                            print(string.format("      %s: %s", tostring(key), tostring(value)))
                        end
                    end
                    workingMethods = workingMethods + 1
                else
                    print("   ❌ Failed: " .. tostring(result))
                end
                methodsTested = methodsTested + 1
                print("")
            end
        end
        
        -- Test methods that might need parameters
        print("🔧 Testing GT methods with parameters:")
        
        if energyStorage.getSensorInformation then
            print("🧪 Testing getSensorInformation() (" .. type(energyStorage.getSensorInformation) .. ")")
            local success, result = pcall(function() return energyStorage.getSensorInformation() end)
            if success and result then
                print("   ✅ getSensorInformation() success")
                if type(result) == "table" then
                    for i, info in ipairs(result) do
                        print(string.format("   [%d]: %s", i, tostring(info)))
                    end
                else
                    print("   Result: " .. tostring(result))
                end
                workingMethods = workingMethods + 1
            else
                print("   ❌ getSensorInformation() failed: " .. tostring(result))
            end
            methodsTested = methodsTested + 1
            print("")
        end
        
        if energyStorage.getInfoData then
            print("🧪 Testing getInfoData() (" .. type(energyStorage.getInfoData) .. ")")
            local success, result = pcall(function() return energyStorage.getInfoData() end)
            if success and result then
                print("   ✅ getInfoData() success")
                if type(result) == "table" then
                    for key, value in pairs(result) do
                        print(string.format("   %s: %s", tostring(key), tostring(value)))
                    end
                else
                    print("   Result: " .. tostring(result))
                end
                workingMethods = workingMethods + 1
            else
                print("   ❌ getInfoData() failed: " .. tostring(result))
            end
            methodsTested = methodsTested + 1
            print("")
        end
        
        -- Test EU input/output rate methods specifically
        print("⚡ Testing EU Input/Output Rate Methods:")
        local euIn, euOut = getEUInOutRates()
        if euIn then
            print("   ✅ EU Input Rate: " .. formatEU(euIn) .. "/s")
        else
            print("   ❌ Could not read EU input rate")
        end
        if euOut then
            print("   ✅ EU Output Rate: " .. formatEU(euOut) .. "/s")
        else
            print("   ❌ Could not read EU output rate")
        end
        print("")
    end
    
    -- List all available methods and try calling them (including field-based methods)
    print("🔍 Testing ALL available fields/methods:")
    for methodName, value in pairs(energyStorage) do
        local valueType = type(value)
        
        -- Try calling anything that looks like a method
        if valueType == "function" or string.match(methodName, "^get") or string.match(methodName, "^set") or string.match(methodName, "^is") then
            print("   🧪 " .. methodName .. "() - " .. valueType)
            
            -- Try calling the method with no parameters
            local success, result = pcall(function() return energyStorage[methodName]() end)
            if success then
                print("      ✅ Returns: " .. tostring(result) .. " (" .. type(result) .. ")")
                if type(result) == "table" and result ~= nil then
                    local count = 0
                    for k, v in pairs(result) do
                        if count < 3 then  -- Limit output
                            print(string.format("         %s: %s", tostring(k), tostring(v)))
                        end
                        count = count + 1
                    end
                    if count > 3 then
                        print(string.format("         ... and %d more entries", count - 3))
                    end
                end
            else
                print("      ❌ Error: " .. tostring(result))
            end
        else
            print("   📄 " .. methodName .. " = " .. tostring(value) .. " (" .. valueType .. ")")
        end
    end
    print("")
    
    -- Summary
    print("📊 SUMMARY:")
    print(string.format("   Methods tested: %d", methodsTested))
    print(string.format("   Working methods: %d", workingMethods))
    
    if workingMethods == 0 then
        print("")
        print("🚨 NO WORKING ENERGY METHODS FOUND!")
        print("Possible issues:")
        print("   1. Energy storage adapter not adjacent to supercapacitor controller")
        print("   2. Wrong component address")
        print("   3. Supercapacitor controller not compatible with standard methods")
        print("   4. Try different adapter placement/orientation")
    else
        print("")
        print("✅ Found working energy methods! The controller should work.")
        print("If you're still seeing 0%, try enabling debug mode:")
        print("   Run: controller debug-energy")
    end
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
elseif args[1] == "inspect-adapter" then
    -- Just run adapter inspection without full initialization
    inspectAdapter()
    return
elseif args[1] == "test-energy" then
    -- Initialize components first for energy testing
    pcall(initializeComponents)
    testEnergyMethods()
    return
elseif args[1] == "debug-energy" then
    -- Enable debug mode and run one energy check
    DEBUG_ENERGY = true
    print("🔍 ENERGY DEBUG MODE ENABLED")
    print("Initializing components...")
    pcall(initializeComponents)
    print("Testing energy reading with debug output:")
    local level = getEnergyLevel()
    print(string.format("Final result: %.1f%%", level * 100))
    return
elseif args[1] == "help" then
    print("=== CONTROLLER HELP ===")
    print("Usage: controller [command]")
    print("")
    print("Commands:")
    print("  (no args)         - Start the power controller")
    print("  list              - Show available components and addresses")
    print("  components        - Same as 'list'")
    print("  files             - Show current directory files and config search")
    print("  debug             - Same as 'files'")
    print("  inspect-adapter   - Check if adapter is connected and what it sees")
    print("  test-energy       - Test all energy reading methods on your adapter")
    print("  debug-energy      - Run energy reading with detailed debug output")
    print("  help              - Show this help message")
    print("")
    print("Energy Troubleshooting (if showing 0%):")
    print("  1. Run 'controller inspect-adapter' to check adapter connectivity")
    print("  2. Run 'controller test-energy' to see which methods work")
    print("  3. Run 'controller debug-energy' for verbose energy reading")
    print("  4. Check adapter placement (must be adjacent to supercapacitor)")
    print("")
    return
end

-- Start the program
run()
