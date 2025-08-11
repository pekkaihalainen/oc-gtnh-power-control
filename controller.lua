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
local HISTORY_DURATION = 5 -- Keep 5 seconds of history for time estimates

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

-- Update energy history for usage tracking
local function updateEnergyHistory(currentEnergy, maxEnergy)
    local currentTime = os.time()
    
    -- Add new entry
    table.insert(energyHistory, {
        timestamp = currentTime,
        currentEnergy = currentEnergy,
        maxEnergy = maxEnergy
    })
    
    -- Remove old entries (older than HISTORY_DURATION seconds)
    local cutoffTime = currentTime - HISTORY_DURATION
    for i = #energyHistory, 1, -1 do
        if energyHistory[i].timestamp < cutoffTime then
            table.remove(energyHistory, i)
        else
            break -- entries are in chronological order
        end
    end
end

-- Calculate current EU usage rate (EU/second) from previous loop iteration
local function calculateUsageRate()
    if #energyHistory < 2 then
        return 0, "insufficient data"
    end
    
    -- Compare current reading with previous reading (last 2 entries)
    local previous = energyHistory[#energyHistory - 1]
    local current = energyHistory[#energyHistory]
    
    local timeDiff = current.timestamp - previous.timestamp
    if timeDiff <= 0 then
        return 0, "insufficient time"
    end
    
    local energyDiff = current.currentEnergy - previous.currentEnergy
    local rate = energyDiff / timeDiff
    
    return rate, "ok"
end

-- Format EU values with appropriate units
local function formatEU(euValue)
    local absValue = math.abs(euValue)
    if absValue >= 1000000000 then
        return string.format("%.2f GEU", euValue / 1000000000)
    elseif absValue >= 1000000 then
        return string.format("%.2f MEU", euValue / 1000000)
    elseif absValue >= 1000 then
        return string.format("%.2f kEU", euValue / 1000)
    else
        return string.format("%.0f EU", euValue)
    end
end

-- Format time duration in a readable format
local function formatTime(seconds)
    if seconds <= 0 then
        return "N/A"
    end
    
    if seconds < 60 then
        return string.format("%.0fs", seconds)
    elseif seconds < 3600 then
        local minutes = math.floor(seconds / 60)
        local remainingSeconds = seconds % 60
        return string.format("%dm %ds", minutes, remainingSeconds)
    elseif seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        return string.format("%dh %dm", hours, minutes)
    else
        local days = math.floor(seconds / 86400)
        local hours = math.floor((seconds % 86400) / 3600)
        return string.format("%dd %dh", days, hours)
    end
end

-- Get EU input/output rates from GT machine (if available)
local function getEUInOutRates()
    if not energyStorage then
        return nil, nil
    end
    
    local safeCall = function(methodName)
        if energyStorage[methodName] then
            local success, result = pcall(function() return energyStorage[methodName]() end)
            if success and result ~= nil then
                return result
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

-- Calculate time estimates based on current usage rate
local function getTimeEstimates(currentEnergy, maxEnergy, usageRate)
    local timeToEmpty, timeToFull = nil, nil
    
    if usageRate < -100 then -- Losing energy (threshold to avoid noise)
        timeToEmpty = currentEnergy / (-usageRate)
    elseif usageRate > 100 then -- Gaining energy (threshold to avoid noise)
        local remainingCapacity = maxEnergy - currentEnergy
        timeToFull = remainingCapacity / usageRate
    end
    
    return timeToEmpty, timeToFull
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
    gpu.setForeground(0x00A6FF) -- Light blue text
    gpu.fill(1, 1, screenWidth, screenHeight, " ")
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
        return 0x00FF00 -- Green (above 90%)
    end
end

-- Draw the main GUI
local function drawGUI(energyPercent, currentEnergy, maxEnergy)
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
    gpu.set(lowPos, barY + barHeight + 1, "↑ 20%")
    
    gpu.setForeground(0x00FF00)
    local highPos = math.floor(barX + (barWidth - 2) * HIGH_THRESHOLD) + 1
    gpu.set(highPos, barY + barHeight + 1, "90% ↑")
    
    -- Energy details and usage analysis
    gpu.setForeground(0x00A6FF)
    gpu.set(3, barY + barHeight + 3, "Current: " .. formatEU(currentEnergy) .. " / " .. formatEU(maxEnergy))
    
    -- Calculate and display usage information
    local usageRate, status = calculateUsageRate()
    local timeToEmpty, timeToFull = getTimeEstimates(currentEnergy, maxEnergy, usageRate)
    local euIn, euOut = getEUInOutRates()
    
    local currentLine = barY + barHeight + 4
    
    if status == "ok" and math.abs(usageRate) > 100 then
        if usageRate < 0 then
            -- Losing energy
            gpu.setForeground(0xFF8080) -- Light red
            gpu.set(3, currentLine, "Usage: " .. formatEU(-usageRate) .. "/s (consuming)")
            currentLine = currentLine + 1
            if timeToEmpty then
                gpu.setForeground(0xFF0000) -- Red for warning
                gpu.set(3, currentLine, "Time to empty: " .. formatTime(timeToEmpty))
                currentLine = currentLine + 1
            end
        else
            -- Gaining energy
            gpu.setForeground(0x80FF80) -- Light green
            gpu.set(3, currentLine, "Charge: " .. formatEU(usageRate) .. "/s (charging)")
            currentLine = currentLine + 1
            if timeToFull then
                gpu.setForeground(0x00FF00) -- Green
                gpu.set(3, currentLine, "Time to full: " .. formatTime(timeToFull))
                currentLine = currentLine + 1
            end
        end
    else
        gpu.setForeground(0x808080) -- Gray
        if status == "insufficient data" then
            gpu.set(3, currentLine, "Analyzing energy usage... (" .. #energyHistory .. "/2 samples)")
        else
            gpu.set(3, currentLine, "Energy stable (rate: " .. formatEU(usageRate) .. "/s)")
        end
        currentLine = currentLine + 1
    end
    
    -- Display EU input/output rates if available
    if euIn or euOut then
        gpu.setForeground(0x00A6FF) -- Light blue for info
        if euIn and euIn > 0 then
            gpu.set(3, currentLine, "Average EU In: " .. formatEU(euIn) .. "/s")
            currentLine = currentLine + 1
        end
        if euOut and euOut > 0 then
            gpu.setForeground(0xFFB366) -- Light orange for output
            gpu.set(3, currentLine, "Average EU Out: " .. formatEU(euOut) .. "/s")
            currentLine = currentLine + 1
        end
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
    gpu.set(3, statusY + 2, "Control Logic: Enable at <20%, Disable at >90%")
    gpu.set(3, statusY + 3, "Check Interval: " .. CHECK_INTERVAL .. " seconds")
    gpu.set(3, statusY + 4, "Redstone Side: " .. REDSTONE_SIDE)
    
    -- Instructions
    gpu.setForeground(0x00A6FF)
    gpu.set(3, screenHeight - 1, "Press Ctrl+C to stop the program")
end

-- Display current status (console fallback)
local function displayStatus(energyPercent)
    local energyDisplay = string.format("%.1f%%", energyPercent * 100)
    local stateDisplay = isRedstoneActive and "🔴 ON" or "⚫ OFF"
    local timeDisplay = os.date("%H:%M:%S")
    
    -- Get usage information
    local usageInfo = ""
    local usageRate, status = calculateUsageRate()
    if status == "ok" and math.abs(usageRate) > 100 then
        if usageRate < 0 then
            usageInfo = " | Usage: " .. formatEU(-usageRate) .. "/s"
        else
            usageInfo = " | Charge: " .. formatEU(usageRate) .. "/s"
        end
    end
    
    print(string.format("[%s] Energy: %s | Redstone: %s%s", timeDisplay, energyDisplay, stateDisplay, usageInfo))
    
    -- Display EU in/out rates if available (on separate line for clarity)
    local euIn, euOut = getEUInOutRates()
    if euIn or euOut then
        local inOutInfo = ""
        if euIn and euIn > 0 then
            inOutInfo = inOutInfo .. "In: " .. formatEU(euIn) .. "/s"
        end
        if euOut and euOut > 0 then
            if inOutInfo ~= "" then inOutInfo = inOutInfo .. " | " end
            inOutInfo = inOutInfo .. "Out: " .. formatEU(euOut) .. "/s"
        end
        if inOutInfo ~= "" then
            print(string.format("[%s] %s", timeDisplay, inOutInfo))
        end
    end
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
            
            -- Get raw energy values for usage tracking and display
            local currentEnergy, maxEnergy = 0, 0
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
            
            -- Update energy history for usage tracking
            updateEnergyHistory(currentEnergy, maxEnergy)
            
            -- Update GUI if available, otherwise fall back to console
            if gpu and screen then
                drawGUI(energyPercent, currentEnergy, maxEnergy)
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
