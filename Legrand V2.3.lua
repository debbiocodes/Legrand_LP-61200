--[[
Legrand PDU Control Script for Q-SYS Designer
Version: 2.7
Description: Comprehensive control and monitoring for Legrand PDU devices via TCP/IP
Author: WAVE

Features:
- TCP/IP connection to Legrand PDU with automatic login
- Individual outlet control (On/Off/Cycle) with user confirmation
- Outlet group control (On/Off/Cycle) with user confirmation
- Cross-PDU broadcast communication for synchronized operations
- Real-time monitoring of:
  - RMS Current
  - Active Power
  - Temperature
  - Humidity
- Automatic polling and status updates
- User confirmation system (Yes/No buttons with 5-second timeout)
- Error handling and timeout management
- Command queuing and response processing
- Support for outlet ranges and efficient command batching

Required Q-Sys Controls:
- IP Address (String) - PDU IP address
- Port (Number) - PDU port (default: 23)
- Username (String) - Login username
- Password (String) - Login password
- Connect (Button) - Manual connect/disconnect
- Status (String) - Connection status display
- Power state (Boolean Array) - Individual outlet toggles
- Power State Groups (Boolean Array) - Group outlet toggles
- Processing (Boolean) - Processing state indicator
- Waiting Response (Boolean) - Response waiting indicator
- Confirm (Button Array) - Confirmation buttons [1]=Yes, [2]=No

Optional Q-Sys Controls (for monitoring):
- RMS Current (String) - Current reading display
- Active Power (String) - Power reading display
- Temperature (String) - Temperature reading display
- Humidity (String) - Humidity reading display

Optional Q-Sys Controls (for cycle functionality):
- Power Cycle Outlets (Button Array) - Individual outlet cycle buttons
- Power Cycle Groups (Button Array) - Group outlet cycle buttons

Optional Q-Sys Controls (for broadcast functionality):
- Broadcast Group Cycle (Boolean) - Broadcast trigger
- Broadcast Group Name (String) - Broadcast group name

Default Configuration:
- Connection Timeout: 5 seconds
- Polling Interval: 30 seconds
- Broadcast Cooldown: 1 second
- Expected Prompt: "[My PDU] #"

Usage:
1. Configure IP address, port, username, and password
2. Click Connect to establish connection
3. Use outlet toggles for individual control
4. Use group toggles for group control
5. Use cycle buttons for power cycling operations
6. Monitor real-time readings and status indicators

VERSION LOGS:
v2.7 - Enhanced status refresh after group operations - multiple refresh attempts with longer delays to ensure outlet states sync properly
v2.6 - Fixed group operation outlet state updates - ensures individual outlet states refresh after group commands
v2.5 - Improved state management: Waiting Response during confirmation, Processing after Y command
v2.4 - Restored user confirmation system with 5-second timeout and Yes/No button control
v2.3 - Implemented /y flag for immediate command execution, eliminated confirmation prompts
v2.2 - Enhanced broadcast communication and confirmation system
v2.1 - Added confirmation button to confirm outlet toggle
v2.0 - Added cross-PDU broadcast functionality
v1.0 - Initial version with basic PDU control
--]]

-- =============================================================================
-- CONFIGURATION AND CONSTANTS
-- =============================================================================

-- TCP Socket Initialization
local tcp = TcpSocket.New()

-- Connection Configuration
local timeout = 5
local PROMPT = "%[My PDU%] #"

-- Timers
local timeoutTimer = Timer.New()

-- =============================================================================
-- STATE MANAGEMENT VARIABLES
-- =============================================================================

-- Connection State
local isLoggedIn = false
local isWaitingForResponse = false
local isPollingActive = false
local isProcessingCommand = false

-- Broadcast Communication State
local isProcessingBroadcast = false
local isBroadcastReceiver = false
local isBroadcastCancelled = false
local lastBroadcastTime = 0
local lastBroadcastName = ""
local BROADCAST_COOLDOWN = 1  -- 1 second cooldown between broadcasts

-- Command Processing State
local pendingConfirmation = false
local isWaitingForCycle = false
local pendingCycleGroup = nil
local receiverGroupIndex = nil
local isGroupOperationInProgress = false  -- Track if we're in the middle of a group operation

-- Data Buffers
local responseBuffer = ""
local commandQueue = {}

-- =============================================================================
-- CONTROL REFERENCES
-- =============================================================================

-- Connection Controls
local IP = Controls["IP Address"]
local Port = Controls["Port"]
local Connect = Controls["Connect"]
local Status = Controls["Status"]
local Username = Controls["Username"]
local Password = Controls["Password"]

-- Monitoring Display Controls
local RMS_Current = Controls["RMS Current"]
local Active_Power = Controls["Active Power"]
local Temperature = Controls["Temperature"]
local Humidity = Controls["Humidity"]

-- Power Control Arrays
local Power_State = Controls["Power state"]              -- Individual outlet toggles
local Power_State_Group = Controls["Power State Groups"] -- Group outlet toggles
local Power_Cycle = Controls["Power Cycle Outlets"]      -- Individual outlet cycle buttons
local Power_Cycle_Group = Controls["Power Cycle Groups"] -- Group outlet cycle buttons

-- Status Indicators
local Processing = Controls["Processing"]        -- Processing state LED
local WaitingResponse = Controls["Waiting Response"] -- Response waiting LED
local ConfirmBtn = Controls.Confirm              -- Confirmation buttons [1]=Yes, [2]=No

-- Broadcast Communication Controls
local BroadcastGroupCycle = Controls["Broadcast Group Cycle"] -- Broadcast trigger
local BroadcastGroupName = Controls["Broadcast Group Name"]   -- Broadcast group name

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Function to enable/disable confirm buttons
local function SetConfirmButtonState(enabled)
    ConfirmBtn[1].IsDisabled = not enabled  -- Yes button
    ConfirmBtn[2].IsDisabled = not enabled  -- No button
end

-- Function to force refresh outlet states after group operations
local function ForceRefreshOutletStates()
    if not tcp.IsConnected then return end
    
    print("[DEBUG] Force refreshing outlet states...")
    
    -- Send multiple outlet status requests with delays
    sendTCP("show outlets")
    Timer.CallAfter(function()
        if tcp.IsConnected then
            sendTCP("show outlets")
            Timer.CallAfter(function()
                if tcp.IsConnected then
                    sendTCP("show outlets")
                    print("[DEBUG] Force refresh complete")
                end
            end, 2)
        end
    end, 2)
end

-- Function to cross-reference group and outlet states for debugging
local function CrossReferenceGroupOutletStates()
    print("[DEBUG] Cross-referencing group and outlet states:")
    
    -- Check each group state
    for i = 1, #Power_State_Group do
        if Power_State_Group[i].Legend and Power_State_Group[i].Legend ~= "Unused Group" then
            local groupState = Power_State_Group[i].Boolean and "ON" or "OFF"
            print(string.format("[DEBUG] Group %d (%s): %s", i, Power_State_Group[i].Legend, groupState))
        end
    end
    
    -- Check individual outlet states
    print("[DEBUG] Individual outlet states:")
    for i = 1, math.min(24, #Power_State) do
        local outletState = Power_State[i].Boolean and "ON" or "OFF"
        local outletName = Power_State[i].Legend or ""
        print(string.format("[DEBUG]   Outlet %d: %s (%s)", i, outletState, outletName))
    end
end

-- Function to Update Status Display
local function StatusUpdate(msg, state)
    Status.String = msg
    Status.Value = state
end

--[[
    UpdatePowerControls()
    Enables or disables power control buttons based on processing state
    Called whenever the processing or waiting response state changes
--]]
local function UpdatePowerControls()
    local shouldDisable = Processing.Boolean or WaitingResponse.Boolean
    for i = 1, #Power_State do
        Power_State[i].IsDisabled = shouldDisable
        if Power_Cycle and Power_Cycle[i] then Power_Cycle[i].IsDisabled = shouldDisable end
    end
    for i = 1, #Power_State_Group do
        Power_State_Group[i].IsDisabled = shouldDisable
        if Power_Cycle_Group and Power_Cycle_Group[i] then Power_Cycle_Group[i].IsDisabled = shouldDisable end
    end
end

-- Update the Processing state
local function SetProcessingState(state)
    Processing.Boolean = state  -- Update the Processing LED
    isProcessingCommand = state
    UpdatePowerControls()  -- Update toggle states whenever Processing changes
end

local function SetWaitingState(state)
    WaitingResponse.Boolean = state
    isWaitingForResponse = state
end

-- Initialize all states
local function InitializeStates()
    -- Reset all flags
    isLoggedIn = false
    isWaitingForResponse = false
    isPollingActive = false
    isProcessingCommand = false
    isProcessingBroadcast = false
    isBroadcastReceiver = false
    pendingConfirmation = false
    isWaitingForCycle = false
    isBroadcastCancelled = false
    
    -- Reset broadcast related variables
    lastBroadcastTime = 0
    lastBroadcastName = ""
    pendingCycleGroup = nil
    
    -- Reset UI controls
    Processing.Boolean = false
    WaitingResponse.Boolean = false
    if BroadcastGroupName then BroadcastGroupName.String = "" end
    if BroadcastGroupCycle then BroadcastGroupCycle.Boolean = false end
    
    -- Enable all controls (confirmation buttons handled separately)
    for i = 1, #Power_State do
        Power_State[i].IsDisabled = false
        if Power_Cycle and Power_Cycle[i] then Power_Cycle[i].IsDisabled = false end
    end
    for i = 1, #Power_State_Group do
        Power_State_Group[i].IsDisabled = false
        if Power_Cycle_Group and Power_Cycle_Group[i] then Power_Cycle_Group[i].IsDisabled = false end
    end
    
    -- Clear any pending responses and commands
    responseBuffer = ""
    commandQueue = {}
    
    -- Stop any running timers
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end
end

-- Initialize everything when script starts
InitializeStates()

-- Modify the timeout timer to handle confirmation timeout
timeoutTimer.EventHandler = function()
    if pendingConfirmation then
        print("[INFO] Confirmation timeout - sending 'n'")
        sendTCP("n")
        pendingConfirmation = false
        SetConfirmButtonState(false)
        SetWaitingState(false)  -- Clear waiting response
        InitializeStates()
    else
        print("[INFO] Command timeout - resetting states")
        InitializeStates()
    end
end

--[[
    sendTCP(command)
    Sends a TCP command to the PDU if connected
    @param command (string) - The command to send
--]]
local function sendTCP(command)
  if tcp.IsConnected then
    tcp:Write(command.."\r\n")
  else
    print("[ERROR] Socket not connected - cannot send command: " .. command)
  end
end

--[[
    DebugFormat(str)
    Formats binary data for readable debug output
    @param str (string) - Raw data string
    @return (string) - Formatted debug string
--]]
local function DebugFormat(str)
    local visual = ""
    for i = 1, #str do
        local byte = str:sub(i, i)
        if string.byte(byte) >= 32 and string.byte(byte) <= 126 then
            visual = visual .. byte
        else
            visual = visual .. string.format("[%02xh]", string.byte(byte))
        end
    end
    return visual
end

-- =============================================================================
-- COMMAND PROCESSING FUNCTIONS
-- =============================================================================

--[[
    ProcessNextCommand()
    Processes the next command in the queue if not waiting for response
    Manages command processing state and sends commands to PDU
--]]
local function ProcessNextCommand()
    if isWaitingForResponse or #commandQueue == 0 then
        isProcessingCommand = false
        return
    end

    isWaitingForResponse = true
    isProcessingCommand = true
    local command = table.remove(commandQueue, 1)
    print("[INFO] Sending command:", command)
    sendTCP(command)
end

-- Queue Commands for Execution
local function QueueCommands()
    -- Don't queue commands if we're waiting for a response
    if not isLoggedIn or isProcessingCommand or isWaitingForResponse or pendingConfirmation then
        return
    end

    commandQueue = {
        "show inlets",
        "show sensor externalsensor 1",
        "show sensor externalsensor 2",
        "show sensor inlet I1 activePower",  -- Add active power command
        "show outlets",
        "show outletgroups details",
    }
    ProcessNextCommand()
end

-- Poll Data Periodically
local function PollData()
    -- Don't poll if we're waiting for a response or processing a command
    if isWaitingForResponse or isProcessingCommand or pendingConfirmation then
        print("[DEBUG] Skipping poll - waiting for response or processing command")
        Timer.CallAfter(function()
            isPollingActive = false
            PollData()
        end, 30)
        return
    end

    if not isPollingActive and not isProcessingCommand then
        isPollingActive = true  
        print("Polling PDU for data...")
        QueueCommands()
    end

    Timer.CallAfter(function()
        isPollingActive = false
        PollData()
    end, 30) -- Poll every 30 seconds
end

-- Function to safely restart polling
local function SafeRestartPolling()
    if not tcp.IsConnected then return end
    
    -- Only restart polling if we're not waiting for anything
    if not isWaitingForResponse and not isProcessingCommand and not pendingConfirmation then
        isPollingActive = false
        PollData()
    else
        print("[DEBUG] Skipping poll restart - system busy")
    end
end

-- Function to force refresh outlet states after group operations
local function ForceRefreshOutletStates()
    if not tcp.IsConnected then return end
    
    print("[DEBUG] Force refreshing outlet states after group operation")
    sendTCP("show outlets")
    Timer.CallAfter(function()
        if tcp.IsConnected then
            sendTCP("show outletgroups details")
        end
    end, 1)
end

-- Command confirmation handler
local function confirmCommand()
    if not isWaitingForResponse or not pendingConfirmation then
        return
    end

    -- Stop any running timeout timer
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end

    -- Send "y" to confirm the command
    sendTCP("y")
    print("[INFO] Command confirmed - sending 'y'")

    -- Clear confirmation state and set processing state
    pendingConfirmation = false
    SetConfirmButtonState(false)
    SetWaitingState(false)  -- Clear waiting response
    SetProcessingState(true)  -- Set processing state

    -- Wait for operation to complete before sending status updates
    Timer.CallAfter(function()
        if not tcp.IsConnected then InitializeStates() return end
        
        -- Simplified status refresh after group operations
        -- Since we now parse individual outlet states from group response, we only need group status
        Timer.CallAfter(function()
            if not tcp.IsConnected then InitializeStates() return end
            
            print("[DEBUG] Starting simplified status refresh after group operation")
            
            -- Request group status which includes individual outlet states
            sendTCP("show outletgroups details")
            Timer.CallAfter(function()
                if not tcp.IsConnected then InitializeStates() return end
                
                -- Clear group operation flag after group status refresh
                isGroupOperationInProgress = false
                
                -- Reset all states
                InitializeStates()
                
                -- Cross-reference states for debugging
                Timer.CallAfter(function()
                    CrossReferenceGroupOutletStates()
                end, 2)
                
                -- Restart polling after a delay
                Timer.CallAfter(function()
                    SafeRestartPolling()
                end, 5)
            end, 3)
        end, 3)
    end, 3)
end

-- Command cancellation handler
local function cancelCommand()
    if not isWaitingForResponse or not pendingConfirmation then
        return
    end

    -- Stop any running timeout timer
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end

    -- Send "n" to cancel the command
    sendTCP("n")
    print("[INFO] Command cancelled - sending 'n'")

    -- Clear confirmation state and reset states
    pendingConfirmation = false
    SetConfirmButtonState(false)
    SetWaitingState(false)  -- Clear waiting response

    -- Reset all states
    InitializeStates()
end

-- Setup confirm button handlers
if ConfirmBtn and ConfirmBtn[1] and ConfirmBtn[2] then
    ConfirmBtn[1].EventHandler = confirmCommand  -- Yes button
    ConfirmBtn[2].EventHandler = cancelCommand   -- No button
end

-- =============================================================================
-- TCP SOCKET EVENT HANDLER
-- =============================================================================

--[[
    TCP Socket Event Handler
    Handles all TCP socket events including connection, data reception,
    errors, and timeouts. Manages login process and response parsing.
--]]
tcp.EventHandler = function(sock, evt, err)
    if evt == TcpSocket.Events.Connected then
        print("Socket connected successfully to", IP.String, Port.Value)
        StatusUpdate("Connected", 0)
        isLoggedIn = false  
        isWaitingForResponse = false
        isProcessingCommand = false
        responseBuffer = ""

    elseif evt == TcpSocket.Events.Data then
        local data = sock:Read(sock.BufferLength)
        -- Limit buffer size to prevent memory issues
        if #responseBuffer > 8192 then
            responseBuffer = ""
        end
        responseBuffer = responseBuffer .. data  
        print("[DEBUG] Received data:", DebugFormat(data))

        -- Check for confirmation prompts and handle them
        if string.find(responseBuffer, "Do you wish to") then
            print("[DEBUG] Detected confirmation prompt - waiting for user input")
            
            -- Enable confirmation buttons and set pending state
            pendingConfirmation = true
            SetWaitingState(true)
            SetConfirmButtonState(true)
            
            -- Start timeout timer (5 seconds)
            timeoutTimer:Start(5)
            
            responseBuffer = ""
            return
        end

        -- Rest of the event handler...
        if string.find(responseBuffer, "Username:") then
            print("Detected Username prompt, sending username...")
            Timer.CallAfter(function()
                if tcp.IsConnected then
                    sendTCP(Username.String)
                    print("Sent username:", Username.String)
                end
            end, 0.5)
            responseBuffer = ""

        elseif string.find(responseBuffer, "Password:") then
            print("Detected Password prompt, sending password...")
            Timer.CallAfter(function()
                if tcp.IsConnected then
                    sendTCP(Password.String)
                    print("Sent password:", string.rep("*", #Password.String))
                end
            end, 1.0)  -- Increased delay to 1 second
            responseBuffer = ""

        elseif string.find(responseBuffer, "Welcome") then
            print("Login successful!")
            StatusUpdate("Logged In", 0)
            isLoggedIn = true  
            responseBuffer = ""

            -- Start polling after login
            Timer.CallAfter(function()
                SafeRestartPolling()
            end, 5)

        elseif string.find(responseBuffer, "Authentication failed") then
            print("[ERROR] Login failed! Check credentials.")
            StatusUpdate("Authentication Failed", 2)
            responseBuffer = ""

        -- Process Commands After Login
        elseif isLoggedIn and string.find(responseBuffer, PROMPT) then
            print("Full response received:", DebugFormat(responseBuffer))

            -- **Extract and Update RMS Current**
            local current = string.match(responseBuffer, "RMS Current:%s*([%d%.]+)%s*A")
            if current and RMS_Current then
                RMS_Current.String = current .. " A"
                print("[DEBUG] Updated RMS Current:", RMS_Current.String)
            end

            -- **Extract and Update Active Power**
            local power = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*W")
            if power and Active_Power then
                Active_Power.String = power .. " W"
                print("[DEBUG] Updated Active Power:", Active_Power.String)
            end

            -- **Extract and Update Temperature**
            local temp = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*deg C")
            if temp and Temperature then
                Temperature.String = temp .. " °C"
                print("[DEBUG] Updated Temperature:", Temperature.String)
            end

            -- **Extract and Update Humidity**
            local humidity = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*%%")
            if humidity and Humidity then
                Humidity.String = humidity .. " %"
                print("[DEBUG] Updated Humidity:", Humidity.String)
            end

            -- **Extract and Update Power Outlet States and Names**
            -- Parse individual outlet states FIRST if this is a "show outlets" response
            if string.find(responseBuffer, "show outlets") then
                local outletCount = 0
                local outletStates = {}  -- Store parsed states for debugging
                
                print("[DEBUG] Parsing individual outlet states from response...")
                print("[DEBUG] Response contains 'show outlets': " .. tostring(string.find(responseBuffer, "show outlets") ~= nil))
                
                -- Enhanced regex pattern to handle various outlet name formats
                for outlet, name, state in string.gmatch(responseBuffer, "Outlet%s*(%d+)%s*%-?%s*([^:\r\n]*):%s*Power state:%s*(%a+)") do
                    local index = tonumber(outlet)
                    if index and Power_State[index] then
                        local isOn = (state == "On")
                        local oldState = Power_State[index].Boolean
                        Power_State[index].Boolean = isOn
                        outletCount = outletCount + 1
                        outletStates[index] = {name = name, state = state, isOn = isOn}
                        
                        -- Only update Legend if name is not empty
                        if name and name ~= "" then
                            Power_State[index].Legend = name
                            -- Copy name to cycle button
                            if Power_Cycle and Power_Cycle[index] then
                                Power_Cycle[index].Legend = name
                            end
                        end
                        print(string.format("[DEBUG] Outlet %d: %s -> %s (%s)", index, tostring(oldState), tostring(isOn), state))
                    end
                end
                
                -- Log how many outlets were updated and show summary
                if outletCount > 0 then
                    print("[DEBUG] Updated " .. outletCount .. " outlet states from individual outlet response")
                    print("[DEBUG] Outlet state summary:")
                    for i = 1, math.min(24, #Power_State) do
                        if outletStates[i] then
                            print(string.format("[DEBUG]   Outlet %d: %s (%s)", i, outletStates[i].state, outletStates[i].name ~= "" and outletStates[i].name or "No name"))
                        end
                    end
                    
                    -- Also show current Power State values
                    print("[DEBUG] Current Power State values after parsing:")
                    for i = 1, math.min(24, #Power_State) do
                        local state = Power_State[i].Boolean and "ON" or "OFF"
                        print(string.format("[DEBUG]   Power_State[%d]: %s", i, state))
                    end
                else
                    print("[DEBUG] No outlet states found in individual outlet response")
                end
            end

                        -- **Check if we received "show outletgroups details"**
            print("[DEBUG] Checking for group response...")
            print("[DEBUG] ResponseBuffer contains 'show outletgroups details': " .. tostring(string.find(responseBuffer, "show outletgroups details") ~= nil))
            print("[DEBUG] ResponseBuffer contains 'show outlets': " .. tostring(string.find(responseBuffer, "show outlets") ~= nil))
            
            if string.find(responseBuffer, "show outletgroups details") then
                print("[DEBUG] Detected outlet group details response. Processing groups...")
                print("[DEBUG] Full group response for debugging:")
                print(DebugFormat(responseBuffer))
                
                -- Also show the raw response for debugging
                print("[DEBUG] Raw group response:")
                print(responseBuffer)
                
                print("[DEBUG] Response contains 'show outletgroups details': " .. tostring(string.find(responseBuffer, "show outletgroups details") ~= nil))

                    -- **Extract and Update Power State Groups**
                    local detectedGroups = {}  -- Store valid group indexes
                    local groupCount = 0       -- Track the number of valid groups

                -- First pass: Extract group states and names
                print("[DEBUG] Attempting to match group patterns in response...")
                local groupMatches = 0
                for group, groupName, stateString in string.gmatch(responseBuffer, "Outlet Group (%d+) %- ([^:]+).-State:%s*([^\r\n]+)") do
                    groupMatches = groupMatches + 1
                    local groupIndex = tonumber(group)
                    groupCount = math.max(groupCount, groupIndex)  -- Keep track of the highest group index
                    detectedGroups[groupIndex] = true  -- Store detected group indexes

                    -- **Extract "X on" and "Y off" separately**
                    local onCount = stateString:match("(%d+) on")  -- Always extract "X on"
                    local offCount = stateString:match("(%d+) off") -- Extract "Y off" if present

                    -- Convert to numbers (default to 0 if nil)
                    onCount = tonumber(onCount) or 0
                    offCount = tonumber(offCount) or 0

                    -- **If any outlets are OFF, the group should be OFF**
                    local isGroupOn = (offCount == 0)

                    -- **Debug Output**
                    print(string.format("[DEBUG] Matched Group: %d | Name: %s | State String: '%s' | On: %d | Off: %d | IsGroupOn: %s", 
                        groupIndex, groupName, stateString, onCount, offCount, tostring(isGroupOn)))

                    if Power_State_Group[groupIndex] then
                        local oldGroupState = Power_State_Group[groupIndex].Boolean
                        Power_State_Group[groupIndex].Boolean = isGroupOn  -- If any OFF, group is OFF
                        Power_State_Group[groupIndex].IsDisabled = false   -- **Enable valid group toggles**
                        Power_State_Group[groupIndex].Legend = groupName   -- **Update UI with Group Name**
                        -- Copy name to cycle button
                        if Power_Cycle_Group and Power_Cycle_Group[groupIndex] then
                            Power_Cycle_Group[groupIndex].Legend = groupName
                            Power_Cycle_Group[groupIndex].IsDisabled = false
                        end
                        print(string.format("[DEBUG] Group %d (%s): %s -> %s", groupIndex, groupName, tostring(oldGroupState), tostring(isGroupOn)))
                    end
                end
                
                if groupMatches == 0 then
                    print("[DEBUG] No group patterns matched in response")
                else
                    print("[DEBUG] Matched " .. groupMatches .. " group patterns")
                end
                
                -- Second pass: Extract individual outlet states from group details
                -- Note: Individual outlet parsing from "show outlets" takes precedence
                print("[DEBUG] Extracting individual outlet states from group details...")
                local groupOutletStates = {}  -- Store for debugging
                
                -- Parse individual outlet states from group details
                for outlet, state in string.gmatch(responseBuffer, "Outlet (%d+)[^:]*:%s*(%a+)") do
                    local outletIndex = tonumber(outlet)
                    if outletIndex and Power_State[outletIndex] then
                        local isOn = (state == "On")
                        groupOutletStates[outletIndex] = state
                        print(string.format("[DEBUG] Found outlet %d as %s in group details", outletIndex, state))
                        
                        -- During group operations, apply outlet states from group details
                        if isGroupOperationInProgress then
                            local oldState = Power_State[outletIndex].Boolean
                            Power_State[outletIndex].Boolean = isOn
                            print(string.format("[DEBUG] Applied outlet %d state from group details: %s -> %s (%s)", outletIndex, tostring(oldState), tostring(isOn), state))
                        end
                    end
                end
                
                -- Log group outlet states for debugging
                if next(groupOutletStates) then
                    print("[DEBUG] Group-based outlet states found:")
                    for i = 1, math.min(24, #Power_State) do
                        if groupOutletStates[i] then
                            local applied = isGroupOperationInProgress and " (applied)" or " (reference only)"
                            print(string.format("[DEBUG]   Outlet %d: %s%s", i, groupOutletStates[i], applied))
                        end
                    end
                else
                    print("[DEBUG] No individual outlet states found in group details")
                end
                
                -- **Now disable only unused group toggles (AFTER getting all data)**
                for i = 1, #Power_State_Group do
                    if not detectedGroups[i] then
                        Power_State_Group[i].Boolean = false
                        Power_State_Group[i].IsDisabled = true  -- **Disable extra toggles**
                        Power_State_Group[i].String = "Unused Group"  -- **Indicate unused toggles**
                        if Power_Cycle_Group and Power_Cycle_Group[i] then 
                            Power_Cycle_Group[i].IsDisabled = true  -- Disable cycle button for unused groups
                            Power_Cycle_Group[i].String = "Unused Group"
                        end
                        print(string.format("[DEBUG] Group %d disabled (no associated group).", i))
                    else
                        -- Enable cycle button for valid groups
                        if Power_Cycle_Group and Power_Cycle_Group[i] then
                            Power_Cycle_Group[i].IsDisabled = false
                        end
                    end
                end

                -- **Clear responseBuffer after processing to prevent stale data**
                responseBuffer = ""
            end
            
            -- Individual outlet parsing already handled above

            -- **Ensure Values Are Updating**
            print("[DEBUG] Final Values Updated:")
            print("[DEBUG] RMS Current: " .. (RMS_Current and RMS_Current.String or ""))
            print("[DEBUG] Active Power: " .. (Active_Power and Active_Power.String or ""))
            print("[DEBUG] Temperature: " .. (Temperature and Temperature.String or ""))
            print("[DEBUG] Humidity: " .. (Humidity and Humidity.String or ""))

            -- **Reset buffer and process next command**
            print("[DEBUG] End of response detected.")
            isWaitingForResponse = false  
            isProcessingCommand = false
            responseBuffer = ""
            ProcessNextCommand()
        end

    elseif evt == TcpSocket.Events.Closed then
        print("[ERROR] Socket closed by remote")
        StatusUpdate("Socket Closed", 2)
        isLoggedIn = false  
        responseBuffer = ""

    elseif evt == TcpSocket.Events.Error then
        print("[ERROR] Socket error:", err)
        StatusUpdate("Socket Error: " .. err, 2)
        responseBuffer = ""

    elseif evt == TcpSocket.Events.Timeout then
        print("[ERROR] Socket timeout")
        StatusUpdate("Socket Timeout", 2)
        responseBuffer = ""
    end
end

-- Function to Establish TCP Connection
local function TcpOpen()
    if Connect.Boolean then
        if tcp.IsConnected then return end
        print("Connecting to PDU:", IP.String, Port.Value)
        tcp:Connect(IP.String, Port.Value)
    else
        if tcp.IsConnected then
            tcp:Disconnect()
            print("Disconnected from PDU")
            StatusUpdate("Disconnected", 3)
            isLoggedIn = false  
        end
    end
end

-- =============================================================================
-- EVENT HANDLERS
-- =============================================================================

-- Connection control event handlers
IP.EventHandler = TcpOpen
Port.EventHandler = TcpOpen 
Connect.EventHandler = TcpOpen

-- Initialize Connection
Timer.CallAfter(TcpOpen, 5)

-- =============================================================================
-- POWER CONTROL EVENT HANDLERS
-- =============================================================================

-- Individual outlet power control handlers
for i=1,#Power_State do
  Power_State[i].EventHandler = function(ctl)
    if not tcp.IsConnected then --check if socket is connected
      print("[ERROR] TCP connection is not available. Preventing power state toggle.")
      ctl.Boolean = not ctl.Boolean  -- Revert the change
      return
    end
    if not isProcessingCommand then
      print("[Action] : Power Toggle triggered")
      SetWaitingState(true)
      timeoutTimer:Start(timeout) -- start timeout timer

      local powerToggleState = ctl.Boolean -- Capture the state inside the function

      if powerToggleState then
        sendTCP("power outlets ".. i .. " on")
        print("Sent command: power outlets ".. i .. " on")
      else
        sendTCP("power outlets ".. i .. " off")
        print("Sent command: power outlets ".. i .. " off")
      end

    else
      -- Prevent the toggle from changing while processing
      ctl.Boolean = not ctl.Boolean
    end
  end
end

for i=1,#Power_State_Group do
  Power_State_Group[i].EventHandler = function(ctl)
    if not tcp.IsConnected then --check if socket is connected
      print("[ERROR] TCP connection is not available. Preventing group toggle.")
      ctl.Boolean = not ctl.Boolean  -- Revert the change
      return
    end
    
    local groupName = Power_State_Group[i].Legend or ("Group " .. i)
    local action = ctl.Boolean and "ON" or "OFF"
    
    print(string.format("[Action] Power Group Toggle triggered for group %d (%s) - turning %s", i, groupName, action))
    SetWaitingState(true)
    timeoutTimer:Start(timeout) -- start timeout timer
    
    -- Set group operation flag
    isGroupOperationInProgress = true

    if ctl.Boolean == true then
      sendTCP("power outletgroup ".. i .. " on")
      print("Sent command: power outletgroup ".. i .. " on")
    else
      sendTCP("power outletgroup ".. i .. " off")
      print("Sent command: power outletgroup ".. i .. " off")
    end
    
    -- Note: Individual outlet states will be updated from group status response
    -- No need for additional force refresh since we parse outlet states from group details
  end
end

-- Power Cycle Outlet Handler
if Power_Cycle then
for i=1,#Power_Cycle do
  Power_Cycle[i].EventHandler = function(ctl)
    if not tcp.IsConnected then
      print("[ERROR] TCP connection is not available. Preventing power cycle.")
      return
    end
    if not isProcessingCommand then
      print("[Action] : Power Cycle Outlet triggered")
      SetWaitingState(true)
      timeoutTimer:Start(timeout)

      sendTCP("power outlets ".. i .. " cycle")
      print("Sent command: power outlets ".. i .. " cycle")

      -- Request immediate status update after cycle command
      Timer.CallAfter(function()
        if tcp.IsConnected then
          sendTCP("show outlets")
          Timer.CallAfter(function()
            if tcp.IsConnected then
              sendTCP("show outletgroups details")
              print("[DEBUG] Sent status update commands after cycle")
            end
          end, 1) -- Delay between commands
        end
      end, 3) -- Longer delay after cycle command to allow for the cycle to complete
    end
  end
end
end

-- Add helper function to find group index by name
local function findGroupIndexByName(name)
    for i = 1, #Power_State_Group do
        if Power_State_Group[i].Legend == name then
            return i
        end
    end
    return nil
end

-- Modify Power Cycle Group Handler
if Power_Cycle_Group then
for i=1,#Power_Cycle_Group do
  Power_Cycle_Group[i].EventHandler = function(ctl)
    if not tcp.IsConnected then
      print("[ERROR] TCP connection is not available. Preventing group cycle.")
      return
    end
    
    -- Prevent multiple simultaneous operations
    if isProcessingCommand or isProcessingBroadcast or pendingConfirmation then
      print("[INFO] Already processing a command, please wait...")
      return
    end
    
    local groupName = Power_State_Group[i].Legend
    if groupName == "Unused Group" then return end
    
    print("[ACTION] Power Cycle Group triggered for group:", groupName)
    
    -- Store the pending cycle group
    pendingCycleGroup = i
    
    -- Reset flags
    isBroadcastReceiver = false
    isProcessingBroadcast = true
    isWaitingForCycle = true  -- Set this immediately since we're doing a cycle
    
    -- Set states
    SetWaitingState(true)
    timeoutTimer:Start(timeout * 2)  -- Reduced timeout since no confirmation needed

    -- Set broadcast name and trigger broadcast immediately
    if BroadcastGroupCycle and BroadcastGroupName then
        BroadcastGroupName.String = groupName
        print("[INFO] Broadcasting for group:", groupName)
        BroadcastGroupCycle:Trigger()
    end
    
    -- Send the cycle command directly
    print("[INFO] Sending cycle command for initiating PDU")
    sendTCP("power outletgroup ".. i .. " cycle")
  end
end
end

-- Modify the broadcast handler
if BroadcastGroupCycle then
BroadcastGroupCycle.EventHandler = function()
    local currentTime = os.time()
    local currentName = BroadcastGroupName and BroadcastGroupName.String or ""
    
    -- Ignore empty names or cancelled broadcasts
    if currentName == "" or isBroadcastCancelled then 
        return 
    end
    
    -- Check if this is a duplicate broadcast
    if currentName == lastBroadcastName and (currentTime - lastBroadcastTime) < BROADCAST_COOLDOWN then
        return
    end
    
    -- Check if already processing
    if isProcessingBroadcast then 
        return 
    end
    
    -- Update tracking variables
    lastBroadcastTime = currentTime
    lastBroadcastName = currentName
    isProcessingBroadcast = true
    
    print("[INFO] Processing broadcast for group:", currentName)
    
    -- Find matching group index
    local groupIndex = findGroupIndexByName(currentName)
    if not groupIndex then
        print("[INFO] No matching group found for name:", currentName)
        -- Clear broadcast name after a short delay
        Timer.CallAfter(function()
            if BroadcastGroupName then BroadcastGroupName.String = "" end
            isProcessingBroadcast = false
        end, 0.5)
        return
    end
    
    -- If we're not the initiator
    if pendingCycleGroup ~= groupIndex then
        -- Check broadcast status periodically before proceeding
        local checkBroadcastStatus
        checkBroadcastStatus = Timer.New()
        checkBroadcastStatus.EventHandler = function()
            -- If broadcast was cancelled or name cleared, abort
            if isBroadcastCancelled or (BroadcastGroupName and BroadcastGroupName.String == "") then
                print("[INFO] Broadcast cancelled, aborting receiver operation")
                checkBroadcastStatus:Stop()
                InitializeStates()
                return
            end
            
            -- If we've waited long enough, proceed with operation
            if os.time() - lastBroadcastTime >= 3 then
                checkBroadcastStatus:Stop()
                if tcp.IsConnected then
                    isBroadcastReceiver = true
                    receiverGroupIndex = groupIndex  -- Store group index for receiver
                    -- First turn on the outlets
                    sendTCP("power outletgroup ".. groupIndex .. " on")
                end
            end
        end
        checkBroadcastStatus:Start(0.5)  -- Check every 500ms
    end
end
end

-- =============================================================================
-- STATUS UPDATE HANDLERS
-- =============================================================================

-- Update power controls when waiting response state changes
WaitingResponse.EventHandler = function()
    UpdatePowerControls()
end

-- =============================================================================
-- SCRIPT INITIALIZATION COMPLETE
-- =============================================================================
print("[INFO] Legrand PDU Control Script v2.7 initialized successfully")
print("[INFO] Waiting for connection configuration...")
print("[INFO] Waiting for connection configuration...")