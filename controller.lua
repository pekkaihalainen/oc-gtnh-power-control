-- Lapatronic Supercapacitor Power Controller
-- Monitors energy level and controls redstone output with hysteresis
-- Enable signal at <20%, disable at >90%

local component = require("component")
local event = require("event")
local os = require("os")
local unicode = require("unicode")

-- Configuration
local CHECK_INTERVAL = 5 -- seconds between energy checks
local LOW_THRESHOLD = 0.20 -- 20% - enable redstone signal
local HIGH_THRESHOLD = 0.90 -- 90% - disable redstone signal
local REDSTONE_SIDE = 1 -- redstone I/O side (1-6, or use sides.bottom etc)

-- Global state
local isRedstoneActive = false
local energyDetector = nil
local redstoneIO = nil
local gpu = nil
local screen = nil
local screenWidth, screenHeight = 0, 0

-- Initialize components
local function initializeComponents()
    print("Initializing components...")
    
    -- Find GPU and screen
    if component.isAvailable("gpu") then
        gpu = component.gpu
        print("✓ Found GPU")
    else
        error("✗ No GPU found! Please install a graphics card.")
    end
    
    if component.isAvailable("screen") then
        screen = component.screen
        gpu.bind(screen.address)
        screenWidth, screenHeight = gpu.getResolution()
        print(string.format("✓ Found Screen (%dx%d)", screenWidth, screenHeight))
    else
        error("✗ No screen found! Please connect a screen.")
    end
    
    -- Find energy detector (try common component names)
    if component.isAvailable("gt_energydetector") then
        energyDetector = component.gt_energydetector
        print("✓ Found GT Energy Detector")
    elseif component.isAvailable("energy_device") then
        energyDetector = component.energy_device
        print("✓ Found Energy Device")
    else
        error("✗ No energy detector found! Please connect a GT Energy Detector or compatible component.")
    end
    
    -- Find redstone I/O
    if component.isAvailable("redstone") then
        redstoneIO = component.redstone
        print("✓ Found Redstone I/O")
    else
        error("✗ No redstone I/O found! Please connect a Redstone I/O block.")
    end
    
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

-- Start the program
run()
