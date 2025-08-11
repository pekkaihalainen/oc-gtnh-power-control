-- Lapatronic Supercapacitor Controller - Configuration Example
-- Copy this file to config.lua and update the addresses for your setup

--[[
HOW TO FIND YOUR COMPONENT ADDRESSES:

1. Run the controller with: controller list
   OR
2. In Lua console, type: component.list()
3. Find your component addresses and update the values below
4. Save this file as 'config.lua'

Example output from component.list():
📦 gt_energydetector:
   1. a1b2c3d4-e5f6-7890-abcd-ef1234567890

📦 redstone:
   1. b2c3d4e5-f6g7-8901-bcde-f01234567891
--]]

local config = {}

-- REQUIRED: Set these to your actual component addresses
config.ENERGY_DETECTOR_ADDRESS = "your-energy-detector-address-here"
config.REDSTONE_IO_ADDRESS = "your-redstone-io-address-here"

-- OPTIONAL: Leave empty for auto-detection
config.GPU_ADDRESS = ""
config.SCREEN_ADDRESS = ""

-- Control Settings
config.CHECK_INTERVAL = 5          -- seconds between energy checks
config.LOW_THRESHOLD = 0.20        -- 20% - enable redstone signal
config.HIGH_THRESHOLD = 0.90       -- 90% - disable redstone signal
config.REDSTONE_SIDE = 1           -- redstone I/O side (1-6)

return config
