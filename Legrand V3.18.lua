--[[
Legrand PDU Control Script for Q-SYS Designer
Version: 3.18
Description: Comprehensive control and monitoring for Legrand PDU devices via TCP/IP
Author: Daniel De Biasi

Features:
- TCP/IP connection to Legrand PDU with automatic login
- Individual outlet control (On/Off/Cycle) with user confirmation
- Outlet group control (On/Off/Cycle) with user confirmation
- Cross-PDU broadcast communication for synchronized operations
- String-based group trigger - send group name to toggle group power state
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
- NEW: Commands only sent when user confirms with Yes button
- NEW: Only one toggle can be selected at a time

Required Q-Sys Controls:
- IP Address (String) - PDU IP address
- Port (Number) - PDU port (default: 23)
- Username (String) - Login username
- Password (String) - Login password
- Connect (Button) - Manual connect/disconnect
- Status (String) - Connection status display
- Power state (Boolean Array) - Individual outlet toggles
- Power State Groups (Boolean Array) - Group outlet toggles
- Power_Operation (Boolean Array) - Operation mode selection [1]=ON/OFF, [2]=Cycle
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

Optional Q-Sys Controls (for string-based group triggering):
- Group Trigger String (String) - Send group name to trigger toggle

Default Configuration:
- Connection Timeout: 5 seconds
- Polling Interval: 30 seconds
- Broadcast Cooldown: 1 second
- Expected Prompt: "[My PDU] #"

Usage:
1. Configure IP address, port, username, and password
2. Click Connect to establish connection
3. Select Power Operation mode: [1]=ON/OFF or [2]=Cycle
4. Use outlet toggles for individual control (behavior depends on selected mode)
5. Use group toggles for group control (behavior depends on selected mode)
6. Use cycle buttons for power cycling operations (independent of mode)
7. Send group name to "Group Trigger String" to toggle group power state (case-insensitive)
8. Monitor real-time readings and status indicators
9. NEW: Toggle any outlet/group to prepare command, then press Yes to execute or No to cancel

VERSION LOGS:
v3.18 - FIXED: Waiting Response LED stuck ON - properly clear WaitingResponse control after PDU response
v3.17 - FIXED: Confirm buttons disabled issue - prevent UpdatePowerControls from disabling controls during user confirmation
v3.16 - FIXED: Double confirmation issue - properly maintain user confirmation state until PDU response is received
v3.15 - FIXED: Double confirmation issue - PDU confirmation prompts are now auto-confirmed when user has already confirmed through the UI
v3.14 - NEW: Implemented confirmation-based command system - commands only sent when user presses Yes button
v3.14 - NEW: Only one toggle can be selected at a time to prevent conflicts
v3.14 - NEW: Commands are prepared when toggles are pressed but not sent until confirmed
v3.13 - Modified string-based group trigger to default to power cycle instead of on/off toggle - now uses broadcast communication for synchronized cycling
v3.12 - Added Power_Operation control with mutual exclusivity - toggle between ON/OFF and Cycle modes for outlet and group operations
v3.11 - Added string-based group trigger functionality - send group name to toggle group power state
v3.10 - Fixed Raritan PDU compatibility, retry loop prevention, and confirmation button state management
v3.9 - Fixed toggle state reversion - now only reverts the specific item being operated on instead of all items
v3.8 - Enhanced error recovery, exponential backoff reconnection, command retry logic, and health monitoring
v3.7 - Code cleanup, debug flag, timer safety, accessibility notes, and bugfixes
v3.6 - Fixed group operation outlet states - now applies individual outlet states from group details during group operations instead of relying on show outlets command
v3.5 - Enhanced group operation status refresh - now sends multiple show outlets commands with increasing delays to ensure accurate individual outlet states
v3.4 - Fixed repeated group operations - added post-group operation period to prevent normal polling from sending show outlets commands for 30 seconds after group operations
v3.3 - Added enhanced debugging to track command sending and status refresh sequence execution
v3.2 - Fixed group operation sequence - now sends show outlets after group operations to verify individual outlet states, and processes the response correctly
v3.1 - Fixed polling during group operations - now prevents normal polling from running during group operations by checking isGroupOperationInProgress flag
v3.0 - Fixed normal polling during group operations - now skips individual outlet queries in normal polling during group operations and keeps group operation flag active longer
v2.9 - Fixed individual outlet parsing during group operations - now skips individual outlet parsing during group operations to prevent overriding correct group states
v2.8 - Fixed group operation outlet state updates - group operations now properly update individual outlet states from group details
v2.7 - Enhanced status refresh after group operations - multiple refresh attempts with longer delays to ensure outlet states sync properly
v2.6 - Fixed group operation outlet state updates - ensures individual outlet states refresh after group commands
v2.5 - Improved state management: Waiting Response during confirmation, Processing after Y command
v2.4 - Restored user confirmation system with 5-second timeout and Yes/No button control
v2.3 - Implemented /y flag for immediate command execution, eliminated confirmation prompts
v2.2 - Enhanced broadcast communication and confirmation system
v2.1 - Added confirmation button to confirm outlet toggle
v2.0 - Added cross-PDU broadcast functionality
v1.0 - Initial version with basic PDU control

Accessibility/UX Note:
- All Q-SYS UCI controls should have clear legends, tooltips, and be accessible for all users.
--]]

-- =============================================================================
-- CONFIGURATION AND CONSTANTS
-- =============================================================================

local DEBUG = true -- Set to false to disable debug prints (verbose logging has been reduced for cleaner output)

-- Configuration constants
local CONFIG = {
    TIMEOUT = 10,
    POLL_INTERVAL = 30,
    BUFFER_SIZE = 8192,
    BROADCAST_COOLDOWN = 1,
    PROMPT = "%[My PDU%] #",
    MAX_OUTLETS = 24,
    MAX_GROUPS = 10,
    -- Enhanced error recovery settings
    MAX_RECONNECT_ATTEMPTS = 5,
    RECONNECT_BASE_DELAY = 2,
    RECONNECT_MAX_DELAY = 60,
    COMMAND_RETRY_ATTEMPTS = 3,
    COMMAND_RETRY_DELAY = 1
}

-- Performance tracking
local performanceStats = {
    commandsSent = 0,
    responsesReceived = 0,
    errors = 0,
    lastResponseTime = 0,
    reconnectAttempts = 0,
    lastReconnectTime = 0
}

-- Error tracking
local errorStats = {
    connectionErrors = 0,
    authenticationErrors = 0,
    commandErrors = 0,
    timeoutErrors = 0,
    lastErrorTime = 0,
    lastErrorType = ""
}

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Standardize debug output
local function DebugLog(level, message, ...)
    if not DEBUG then return end
    local formatted = string.format(message, ...)
    print(string.format("[%s] %s", level:upper(), formatted))
end

-- Validate IP address format
local function IsValidIP(ip)
    if not ip or ip == "" then return false end
    local parts = {ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")}
    if #parts ~= 4 then return false end
    for _, part in ipairs(parts) do
        local num = tonumber(part)
        if not num or num < 0 or num > 255 then return false end
    end
    return true
end

-- Validate required controls exist with safe access
local function ValidateControls()
    local required = {"IP Address", "Port", "Connect", "Status", "Username", "Password"}
    for _, name in ipairs(required) do
        if not Controls[name] then
            DebugLog("ERROR", "Required control not found: %s", name)
            return false
        end
    end
    return true
end

-- Safe control access function
local function SafeGetControl(controlName)
    if not controlName or type(controlName) ~= "string" then
        return nil
    end
    return Controls[controlName]
end

-- Safe control value access
local function SafeGetControlValue(control, isString)
    if not control then return isString and "" or 0 end
    
    local success, result = pcall(function()
        if isString then
            return control.String or ""
        else
            return control.Value or 0
        end
    end)
    
    if not success then
        DebugLog("ERROR", "Failed to get control value: %s", tostring(result))
        return isString and "" or 0
    end
    
    return result
end

-- Create safe timer with cleanup and maximum limit
local activeTimers = {}
local MAX_ACTIVE_TIMERS = 50 -- Prevent timer explosion

local function CreateSafeTimer(delay, callback)
    -- Clean up any stopped timers first
    for i = #activeTimers, 1, -1 do
        if not activeTimers[i]:IsRunning() then
            table.remove(activeTimers, i)
        end
    end
    
    -- Prevent timer explosion
    if #activeTimers >= MAX_ACTIVE_TIMERS then
        DebugLog("WARNING", "Too many active timers (%d), cleaning up oldest", #activeTimers)
        if #activeTimers > 0 then
            activeTimers[1]:Stop()
            table.remove(activeTimers, 1)
        end
    end
    
    local timer = Timer.New()
    timer.EventHandler = function()
        callback()
        timer:Stop()
        -- Remove from active timers
        for i, t in ipairs(activeTimers) do
            if t == timer then
                table.remove(activeTimers, i)
                break
            end
        end
    end
    table.insert(activeTimers, timer)
    timer:Start(delay)
    return timer
end

-- Clean up all active timers
local function CleanupTimers()
    for _, timer in ipairs(activeTimers) do
        if timer:IsRunning() then
            timer:Stop()
        end
    end
    activeTimers = {}
end

-- =============================================================================
-- TCP SOCKET INITIALIZATION
-- =============================================================================

local tcp = TcpSocket.New()
local timeoutTimer = Timer.New()

-- =============================================================================
-- STATE MANAGEMENT
-- =============================================================================

-- Connection State
local isLoggedIn = false
local isWaitingForResponse = false
local isPollingActive = false
local isProcessingCommand = false
local isUserInitiatedCommand = false

-- Broadcast Communication State
local isProcessingBroadcast = false
local isBroadcastReceiver = false
local isBroadcastCancelled = false
local lastBroadcastTime = 0
local lastBroadcastName = ""

-- Command Processing State
local pendingConfirmation = false
local isWaitingForCycle = false
local pendingCycleGroup = nil
local receiverGroupIndex = nil
local isGroupOperationInProgress = false
local isPostGroupOperation = false
local previousGroupState = nil
local previousOutletState = nil
local isRevertingStates = false

-- NEW: Pending command system for confirmation-based execution
local pendingCommand = {
    type = nil,        -- "outlet", "group", "cycle_outlet", "cycle_group"
    index = nil,       -- outlet or group index
    command = nil,     -- the actual command string to send
    targetState = nil, -- the target state (true/false for on/off)
    description = nil  -- human-readable description of the operation
}
local isWaitingForUserConfirmation = false
local lastToggledControl = nil

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
local Power_State = Controls["Power state"]
local Power_State_Group = Controls["Power State Groups"]
local Power_Cycle = Controls["Power Cycle Outlets"]
local Power_Cycle_Group = Controls["Power Cycle Groups"]

-- Status Indicators
local Processing = Controls["Processing"]
local WaitingResponse = Controls["Waiting Response"]
local ConfirmBtn = Controls.Confirm

-- Power Operation Mode Control
local Power_Operation = Controls["Power_Operation"]

-- Broadcast Communication Controls
local BroadcastGroupCycle = Controls["Broadcast Group Cycle"]
local BroadcastGroupName = Controls["Broadcast Group Name"]

-- String-based Group Trigger Control
local GroupTriggerString = Controls["Group Trigger String"]

-- =============================================================================
-- CORE FUNCTIONS
-- =============================================================================

-- Function to enable/disable confirm buttons
local function SetConfirmButtonState(enabled)
    if ConfirmBtn and ConfirmBtn[1] and ConfirmBtn[2] then
        ConfirmBtn[1].IsDisabled = not enabled
        ConfirmBtn[2].IsDisabled = not enabled
    end
end

-- Function to set waiting state
local function SetWaitingState(state)
    if WaitingResponse then
        WaitingResponse.Boolean = state
    end
    isWaitingForResponse = state
end

-- NEW: Function to prepare a command for confirmation
local function PrepareCommand(commandType, index, command, targetState, description)
    if not tcp.IsConnected then
        DebugLog("ERROR", "TCP connection not available. Cannot prepare command.")
        return false
    end
    
    -- If already waiting for confirmation, update the pending command instead of showing warning
    if isWaitingForUserConfirmation then
        DebugLog("INFO", "Updating pending command from previous selection")
        
        -- Revert the previous toggle that was pressed
        if lastToggledControl then
            lastToggledControl.Boolean = not lastToggledControl.Boolean
        end
    end
    
    -- Store the new pending command
    pendingCommand = {
        type = commandType,
        index = index,
        command = command,
        targetState = targetState,
        description = description
    }
    
    isWaitingForUserConfirmation = true
    SetWaitingState(true)
    SetConfirmButtonState(true)
    
    -- Restart the timeout timer for the new command
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end
    timeoutTimer:Start(CONFIG.TIMEOUT)
    
    -- Auto-clear pending command after extended timeout (30 seconds) to prevent system lockup
    CreateSafeTimer(30, function()
        if isWaitingForUserConfirmation then
            DebugLog("WARNING", "Extended timeout reached - auto-cancelling pending command")
            CancelPendingCommand()
        end
    end)
    
    DebugLog("INFO", "Command prepared for confirmation: %s", description)
    return true
end

-- NEW: Function to execute the pending command
local function ExecutePendingCommand()
    if not pendingCommand.command then
        DebugLog("ERROR", "No pending command to execute")
        return false
    end
    
    DebugLog("INFO", "Executing pending command: %s", pendingCommand.description)
    
    -- Store current state for potential cancellation
    StoreCurrentState()
    currentOperation = {
        type = pendingCommand.type,
        index = pendingCommand.index,
        state = pendingCommand.targetState
    }
    
    isUserInitiatedCommand = true
    SetWaitingState(true)
    timeoutTimer:Start(CONFIG.TIMEOUT)
    
    -- Handle group operations
    if pendingCommand.type == "group" or pendingCommand.type == "cycle_group" then
        isGroupOperationInProgress = true
        
        -- Set up broadcast communication for cycle operations
        if pendingCommand.type == "cycle_group" then
            pendingCycleGroup = pendingCommand.index
            isBroadcastReceiver = false
            isProcessingBroadcast = true
            isWaitingForCycle = true
            
            -- Trigger broadcast for synchronized cycle across PDUs
            if BroadcastGroupCycle and BroadcastGroupName then
                local groupName = Power_State_Group and Power_State_Group[pendingCommand.index] and Power_State_Group[pendingCommand.index].Legend or ("Group " .. pendingCommand.index)
                BroadcastGroupName.String = groupName
                DebugLog("INFO", "Broadcasting for group: %s", groupName)
                BroadcastGroupCycle:Trigger()
            end
        end
    end
    
    -- Send the actual command
    sendTCP(pendingCommand.command)
    DebugLog("INFO", "Sent command: %s", pendingCommand.command)
    
    -- Clear pending command but keep isWaitingForUserConfirmation true until PDU responds
    pendingCommand = {
        type = nil,
        index = nil,
        command = nil,
        targetState = nil,
        description = nil
    }
    -- Don't set isWaitingForUserConfirmation = false here - let the PDU response handler do it
    
    return true
end

-- NEW: Function to cancel pending command
local function CancelPendingCommand()
    if not isWaitingForUserConfirmation then
        DebugLog("WARNING", "No pending command to cancel")
        return false
    end
    
    DebugLog("INFO", "Cancelling pending command: %s", pendingCommand.description or "Unknown")
    
    -- Revert the toggle that was pressed
    if lastToggledControl then
        lastToggledControl.Boolean = not lastToggledControl.Boolean
        lastToggledControl = nil
    end
    
    -- Clear pending command
    pendingCommand = {
        type = nil,
        index = nil,
        command = nil,
        targetState = nil,
        description = nil
    }
    isWaitingForUserConfirmation = false
    SetWaitingState(false)
    SetConfirmButtonState(false)
    
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end
    
    return true
end



-- Function to Update Status Display
local function StatusUpdate(msg, state)
    if Status then
        Status.String = msg
        Status.Value = state
    end
end

-- Update power controls based on processing state
local function UpdatePowerControls()
    -- Don't disable controls when waiting for user confirmation - only disable when processing actual commands
    local shouldDisable = (Processing and Processing.Boolean) or (WaitingResponse and WaitingResponse.Boolean and not isWaitingForUserConfirmation)
    
    -- Update individual outlets
    if Power_State then
        for i = 1, math.min(CONFIG.MAX_OUTLETS, #Power_State) do
            Power_State[i].IsDisabled = shouldDisable
            if Power_Cycle and Power_Cycle[i] then 
                Power_Cycle[i].IsDisabled = shouldDisable 
            end
        end
    end
    
    -- Update groups
    if Power_State_Group then
        for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_State_Group) do
            Power_State_Group[i].IsDisabled = shouldDisable
            if Power_Cycle_Group and Power_Cycle_Group[i] then 
                Power_Cycle_Group[i].IsDisabled = shouldDisable 
            end
        end
    end
end

-- Update the Processing state
local function SetProcessingState(state)
    DebugLog("DEBUG", "SetProcessingState called with: %s", tostring(state))
    
    if Processing then
        Processing.Boolean = state
        DebugLog("DEBUG", "Processing.Boolean set to: %s", tostring(Processing.Boolean))
    else
        DebugLog("DEBUG", "Processing control not found!")
    end
    
    isProcessingCommand = state
    UpdatePowerControls()
end

-- Handle Power Operation mode selection (mutual exclusivity)
local function HandlePowerOperationMode(selectedIndex)
    if not Power_Operation then return end
    
    -- Ensure only one toggle is selected at a time
    for i = 1, #Power_Operation do
        if Power_Operation[i] then
            if i == selectedIndex then
                Power_Operation[i].Boolean = true
                DebugLog("DEBUG", "Power Operation mode set to: %d", i)
            else
                Power_Operation[i].Boolean = false
            end
        end
    end
end

-- Initialize Power Operation mode without resetting existing selection
local function InitializePowerOperationMode()
    if not Power_Operation then return end
    
    -- Check if any toggle is already selected
    local hasSelection = false
    for i = 1, #Power_Operation do
        if Power_Operation[i] and Power_Operation[i].Boolean then
            hasSelection = true
            break
        end
    end
    
    -- Only set default if no toggle is currently selected
    if not hasSelection and Power_Operation[2] then
        HandlePowerOperationMode(2)
        DebugLog("DEBUG", "No Power Operation mode selected, setting default to Cycle mode")
    end
end

-- Get current power operation mode (1 = ON/OFF, 2 = Cycle)
local function GetPowerOperationMode()
    if not Power_Operation then return 2 end -- Default to Cycle mode
    
    for i = 1, #Power_Operation do
        if Power_Operation[i] and Power_Operation[i].Boolean then
            return i
        end
    end
    
    return 2 -- Default to Cycle mode if none selected
end

-- Initialize all states
local function InitializeStates()
    if isGroupOperationInProgress then
        DebugLog("WARNING", "Skipping reset - group operation in progress")
        return
    end
    
    -- Reset all flags
    isLoggedIn = false
    isWaitingForResponse = false
    isPollingActive = false
    isProcessingCommand = false
    isUserInitiatedCommand = false
    isProcessingBroadcast = false
    isBroadcastReceiver = false
    pendingConfirmation = false
    isWaitingForCycle = false
    isBroadcastCancelled = false
    
    -- NEW: Reset confirmation system states
    isWaitingForUserConfirmation = false
    lastToggledControl = nil
    pendingCommand = {
        type = nil,
        index = nil,
        command = nil,
        targetState = nil,
        description = nil
    }
    
    -- Reset broadcast related variables
    lastBroadcastTime = 0
    lastBroadcastName = ""
    pendingCycleGroup = nil
    
    -- Reset UI controls
    SetProcessingState(false)
    SetWaitingState(false)
    SetConfirmButtonState(false)
    
    if BroadcastGroupName then BroadcastGroupName.String = "" end
    if BroadcastGroupCycle then BroadcastGroupCycle.Boolean = false end
    
    -- Initialize Power Operation mode (preserves existing selection)
    InitializePowerOperationMode()
    
    -- Enable all controls
    UpdatePowerControls()
    
    -- Clear any pending responses and commands
    responseBuffer = ""
    commandQueue = {}
    
    -- Stop any running timers
    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end
end

-- Enhanced command sending with retry logic and safety checks
local commandRetryCount = 0
local lastCommandSent = ""
local lastCommandTime = 0
local maxRetryTime = 30  -- Maximum time to keep retrying (30 seconds)

-- Function to send login credentials (bypasses command sanitization)
local function sendLoginCredential(credential)
    if not credential or type(credential) ~= "string" then
        DebugLog("ERROR", "Invalid credential parameter")
        return
    end
    
    if not tcp then
        DebugLog("ERROR", "TCP socket not initialized")
        return
    end
    
    if tcp.IsConnected then
        DebugLog("DEBUG", "sendLoginCredential: Sending credential: %s", string.rep("*", #credential))
        
        -- Use pcall to catch write errors
        local success, err = pcall(function()
            tcp:Write(credential.."\r\n")
        end)
        
        if not success then
            DebugLog("ERROR", "Failed to send credential: %s", tostring(err))
            performanceStats.errors = performanceStats.errors + 1
            errorStats.commandErrors = errorStats.commandErrors + 1
            return
        end
        
        performanceStats.commandsSent = performanceStats.commandsSent + 1
    else
        DebugLog("ERROR", "Socket not connected - cannot send credential")
        performanceStats.errors = performanceStats.errors + 1
        errorStats.commandErrors = errorStats.commandErrors + 1
    end
end

function sendTCP(command)
    if not command or type(command) ~= "string" then
        DebugLog("ERROR", "Invalid command parameter")
        return
    end
    
    -- Sanitize PDU commands to prevent injection
    -- Skip sanitization for login credentials (usernames/passwords)
    if not command:match("^[a-zA-Z0-9!@#$%%^&*()_+=<>?\"'`~\\|]+$") then
        -- This is likely a PDU command, so sanitize it
        if string.find(command, "[^%w%s%-%.%:]") then
            DebugLog("ERROR", "PDU command contains invalid characters: %s", command)
            return
        end
    end
    
    if not tcp then
        DebugLog("ERROR", "TCP socket not initialized")
        return
    end
    
    if tcp.IsConnected then
        DebugLog("DEBUG", "sendTCP: Sending command: %s", command)
        
        -- Use pcall to catch write errors
        local success, err = pcall(function()
            tcp:Write(command.."\r\n")
        end)
        
        if not success then
            DebugLog("ERROR", "Failed to send command: %s", tostring(err))
            performanceStats.errors = performanceStats.errors + 1
            errorStats.commandErrors = errorStats.commandErrors + 1
            return
        end
        
        performanceStats.commandsSent = performanceStats.commandsSent + 1
        lastCommandSent = command
        commandRetryCount = 0
        lastCommandTime = os.time()
    else
        DebugLog("ERROR", "Socket not connected - cannot send command: %s", command)
        performanceStats.errors = performanceStats.errors + 1
        errorStats.commandErrors = errorStats.commandErrors + 1
        errorStats.lastErrorTime = os.time()
        errorStats.lastErrorType = "connection_lost"
        
        -- Attempt reconnection if this was a user-initiated command
        if isUserInitiatedCommand then
            DebugLog("INFO", "Connection lost during user command - attempting reconnection")
            AttemptReconnection()
        end
    end
end

-- Retry failed commands
local function RetryLastCommand()
    local currentTime = os.time()
    
    -- Check if we've been retrying too long
    if lastCommandTime > 0 and (currentTime - lastCommandTime) > maxRetryTime then
        DebugLog("WARNING", "Retry timeout reached (%d seconds), forcing cleanup", maxRetryTime)
        commandRetryCount = 0
        lastCommandSent = ""
        lastCommandTime = 0
        return false
    end
    
    if lastCommandSent ~= "" and commandRetryCount < CONFIG.COMMAND_RETRY_ATTEMPTS then
        commandRetryCount = commandRetryCount + 1
        DebugLog("INFO", "Retrying command (attempt %d/%d): %s", 
            commandRetryCount, CONFIG.COMMAND_RETRY_ATTEMPTS, lastCommandSent)
        
        CreateSafeTimer(CONFIG.COMMAND_RETRY_DELAY, function()
            if tcp.IsConnected then
                sendTCP(lastCommandSent)
            end
        end)
        return true
    else
        -- Reset retry state when max attempts reached
        commandRetryCount = 0
        lastCommandSent = ""
        lastCommandTime = 0
        DebugLog("WARNING", "Max retry attempts reached, clearing retry state")
        return false
    end
end

-- Format binary data for readable debug output
local function DebugFormat(str)
    if not str then return "" end
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

-- Process next command in queue
local function ProcessNextCommand()
    if isWaitingForResponse or #commandQueue == 0 then
        isProcessingCommand = false
        return
    end

    isWaitingForResponse = true
    isProcessingCommand = true
    isUserInitiatedCommand = false
    local command = table.remove(commandQueue, 1)
    DebugLog("INFO", "Sending command: %s", command)
    sendTCP(command)
end

-- Queue commands for execution
local function QueueCommands()
    if not isLoggedIn or isProcessingCommand or isWaitingForResponse or pendingConfirmation then
        return
    end

    -- During group operations, skip individual outlet queries
    if isGroupOperationInProgress or isPostGroupOperation then
        DebugLog("DEBUG", "Group operation or post-group period - skipping individual outlet queries in polling")
        commandQueue = {
            "show inlets",
            "show sensor externalsensor 1",
            "show sensor externalsensor 2",
            "show sensor inlet I1 activePower",
            "show outletgroups",
        }
    else
        commandQueue = {
            "show inlets",
            "show sensor externalsensor 1",
            "show sensor externalsensor 2",
            "show sensor inlet I1 activePower",
            "show outlets",
            "show outletgroups",
        }
    end
    ProcessNextCommand()
end

-- Poll data periodically with safety checks
local pollFailCount = 0
local MAX_POLL_FAILURES = 5

local function PollData()
    -- Prevent infinite polling loops
    if pollFailCount >= MAX_POLL_FAILURES then
        DebugLog("ERROR", "Too many poll failures (%d), stopping polling", pollFailCount)
        isPollingActive = false
        pollFailCount = 0
        return
    end
    
    if isWaitingForResponse or isProcessingCommand or pendingConfirmation or isGroupOperationInProgress or isRevertingStates then
        DebugLog("DEBUG", "Skipping poll - system busy")
        pollFailCount = pollFailCount + 1
        CreateSafeTimer(CONFIG.POLL_INTERVAL, function()
            isPollingActive = false
            PollData()
        end)
        return
    end

    if not isPollingActive and not isProcessingCommand then
        isPollingActive = true
        pollFailCount = 0 -- Reset failure count on successful poll
        DebugLog("INFO", "Polling PDU for data...")
        QueueCommands()
    end

    CreateSafeTimer(CONFIG.POLL_INTERVAL, function()
        isPollingActive = false
        PollData()
    end)
end

-- Store current state for potential cancellation
local currentOperation = {
    type = nil,  -- "outlet", "group", or "cycle"
    index = nil, -- which outlet/group
    state = nil  -- what state it was in before
}

function StoreCurrentState()
    -- Clear previous operation
    currentOperation = {
        type = nil,
        index = nil,
        state = nil
    }
    
    -- Store current group states (only for groups that exist)
    previousGroupState = {}
    if Power_State_Group then
        for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_State_Group) do
            if Power_State_Group[i].Legend and Power_State_Group[i].Legend ~= "Unused Group" then
                previousGroupState[i] = Power_State_Group[i].Boolean
            end
        end
    end
    
    -- Store current outlet states
    previousOutletState = {}
    if Power_State then
        for i = 1, math.min(CONFIG.MAX_OUTLETS, #Power_State) do
            previousOutletState[i] = Power_State[i].Boolean
        end
    end
    
    DebugLog("DEBUG", "Stored current state for potential cancellation")
end

-- Revert to previous state when operation is cancelled
function RevertToPreviousState()
    isRevertingStates = true

    -- Only revert the specific item that was being operated on
    if currentOperation and currentOperation.type and currentOperation.index then
        if currentOperation.type == "outlet" and Power_State and Power_State[currentOperation.index] then
            Power_State[currentOperation.index].Boolean = currentOperation.state
            DebugLog("DEBUG", "Reverted outlet %d to previous state: %s", currentOperation.index, tostring(currentOperation.state))
        elseif currentOperation.type == "group" and Power_State_Group and Power_State_Group[currentOperation.index] then
            Power_State_Group[currentOperation.index].Boolean = currentOperation.state
            DebugLog("DEBUG", "Reverted group %d to previous state: %s", currentOperation.index, tostring(currentOperation.state))
        elseif currentOperation.type == "cycle_outlet" and Power_State and Power_State[currentOperation.index] then
            -- For cycle operations, we don't revert the state since cycle is a temporary operation
            DebugLog("DEBUG", "Cycle operation cancelled for outlet %d - no state reversion needed", currentOperation.index)
        elseif currentOperation.type == "cycle_group" and Power_State_Group and Power_State_Group[currentOperation.index] then
            -- For cycle operations, we don't revert the state since cycle is a temporary operation
            DebugLog("DEBUG", "Cycle operation cancelled for group %d - no state reversion needed", currentOperation.index)
        end
    else
        -- Fallback: revert all states (old behavior for backward compatibility)
        DebugLog("WARNING", "No specific operation tracked, reverting all states")
        if previousGroupState then
            for i, state in pairs(previousGroupState) do
                if Power_State_Group and Power_State_Group[i] then
                    Power_State_Group[i].Boolean = not state
                    Power_State_Group[i].Boolean = state
                    DebugLog("DEBUG", "Reverted group %d to previous state: %s", i, tostring(state))
                end
            end
        end

        if previousOutletState then
            for i, state in pairs(previousOutletState) do
                if Power_State and Power_State[i] then
                    Power_State[i].Boolean = not state
                    Power_State[i].Boolean = state
                    DebugLog("DEBUG", "Reverted outlet %d to previous state: %s", i, tostring(state))
                end
            end
        end
    end

    -- Clear stored states
    previousGroupState = nil
    previousOutletState = nil
    currentOperation = {
        type = nil,
        index = nil,
        state = nil
    }

    DebugLog("DEBUG", "Reverted to previous state after cancellation")

    CreateSafeTimer(10, function()
        isRevertingStates = false
        DebugLog("DEBUG", "State reversion protection period ended")
    end)
end

-- Safely restart polling
local function SafeRestartPolling()
    if not tcp.IsConnected then return end
    
    if not isWaitingForResponse and not isProcessingCommand and not pendingConfirmation and not isGroupOperationInProgress then
        isPollingActive = false
        PollData()
    else
        DebugLog("DEBUG", "Skipping poll restart - system busy")
    end
end

-- =============================================================================
-- CONFIRMATION HANDLERS
-- =============================================================================

-- Command confirmation handler
local function confirmCommand()
    -- NEW: Handle user confirmation for pending commands
    if isWaitingForUserConfirmation then
        if timeoutTimer:IsRunning() then timeoutTimer:Stop() end
        
        DebugLog("INFO", "User confirmed pending command")
        
        if ExecutePendingCommand() then
            SetProcessingState(true)
            DebugLog("DEBUG", "Command executed - Processing LED turned ON")
            
            -- Wait for operation to complete before sending status updates
            CreateSafeTimer(1, function()
                if not tcp.IsConnected then 
                    InitializeStates() 
                    return 
                end
                
                DebugLog("DEBUG", "Command executed, waiting for operation to complete...")
                
                CreateSafeTimer(2, function()
                    if not tcp.IsConnected then 
                        InitializeStates() 
                        return 
                    end
                    
                    DebugLog("DEBUG", "Sending status refresh commands...")
                    
                    sendTCP("show outlets")
                    
                    CreateSafeTimer(1, function()
                        if tcp.IsConnected then
                            sendTCP("show outletgroups")
                        end
                    end)
                    
                    CreateSafeTimer(3, function()
                        if not tcp.IsConnected then 
                            InitializeStates() 
                            return 
                        end
                        
                        DebugLog("DEBUG", "Status refresh commands sent, waiting for responses...")
                        
                        CreateSafeTimer(5, function()
                            SafeRestartPolling()
                        end)
                        
                    end)
                    
                end)
                
            end)
            
            -- Safety timeout
            CreateSafeTimer(30, function()
                if Processing and Processing.Boolean then
                    DebugLog("WARNING", "Processing LED timeout - forcing OFF after 30 seconds")
                    SetProcessingState(false)
                    isWaitingForUserConfirmation = false
                    SetConfirmButtonState(false)
                    SetWaitingState(false)
                end
            end)
        end
        return
    end
    
    -- OLD: Handle PDU confirmation prompts (legacy support)
    if not isWaitingForResponse or not pendingConfirmation then
        return
    end

    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end

    sendTCP("y")
    DebugLog("INFO", "PDU command confirmed - sending 'y'")

    pendingConfirmation = false
    SetConfirmButtonState(false)
    SetWaitingState(false)
    SetProcessingState(true)
    
    DebugLog("DEBUG", "PDU command confirmed - Processing LED turned ON")

    -- Wait for operation to complete before sending status updates
    CreateSafeTimer(1, function()
        if not tcp.IsConnected then 
            InitializeStates() 
            return 
        end
        
        DebugLog("DEBUG", "PDU command confirmed, waiting for operation to complete...")
        
        CreateSafeTimer(2, function()
            if not tcp.IsConnected then 
                InitializeStates() 
                return 
            end
            
            DebugLog("DEBUG", "Sending status refresh commands...")
            
            sendTCP("show outlets")
            
            CreateSafeTimer(1, function()
                if tcp.IsConnected then
                    sendTCP("show outletgroups")
                end
            end)
            
            CreateSafeTimer(3, function()
                if not tcp.IsConnected then 
                    InitializeStates() 
                    return 
                end
                
                DebugLog("DEBUG", "Status refresh commands sent, waiting for responses...")
                
                CreateSafeTimer(5, function()
                    SafeRestartPolling()
                end)
                
            end)
            
        end)
        
    end)
    
    -- Safety timeout
    CreateSafeTimer(30, function()
        if Processing and Processing.Boolean then
            DebugLog("WARNING", "Processing LED timeout - forcing OFF after 30 seconds")
            SetProcessingState(false)
            pendingConfirmation = false
            SetConfirmButtonState(false)
            SetWaitingState(false)
        end
    end)
end

-- Command cancellation handler
local function cancelCommand()
    -- NEW: Handle user cancellation for pending commands
    if isWaitingForUserConfirmation then
        DebugLog("INFO", "User cancelled pending command")
        CancelPendingCommand()
        return
    end
    
    -- OLD: Handle PDU confirmation cancellation (legacy support)
    if not isWaitingForResponse or not pendingConfirmation then
        return
    end

    if timeoutTimer:IsRunning() then timeoutTimer:Stop() end

    sendTCP("n")
    DebugLog("INFO", "PDU command cancelled - sending 'n'")

    pendingConfirmation = false
    SetConfirmButtonState(false)
    SetWaitingState(false)
    SetProcessingState(false)

    RevertToPreviousState()
    InitializeStates()
end

-- Reset reconnection attempts on successful connection
local function ResetReconnectionAttempts()
    performanceStats.reconnectAttempts = 0
    performanceStats.lastReconnectTime = 0
    DebugLog("DEBUG", "Reconnection attempts reset after successful connection")
end

-- =============================================================================
-- TCP SOCKET EVENT HANDLER
-- =============================================================================

tcp.EventHandler = function(sock, evt, err)
    if evt == TcpSocket.Events.Connected then
        local ipAddress = SafeGetControlValue(IP, true)
        local portValue = SafeGetControlValue(Port, false)
        DebugLog("INFO", "Socket connected successfully to %s:%d", ipAddress, portValue)
        StatusUpdate("Connected", 0)
        isLoggedIn = false  
        isWaitingForResponse = false
        isProcessingCommand = false
        responseBuffer = ""
        
        -- Reset reconnection attempts on successful connection
        ResetReconnectionAttempts()

    elseif evt == TcpSocket.Events.Data then
        local data = sock:Read(sock.BufferLength)
        -- Prevent buffer overflow with hard limit
        if #responseBuffer > CONFIG.BUFFER_SIZE then
            DebugLog("WARNING", "Response buffer overflow, clearing buffer")
            responseBuffer = ""
        end
        
        -- Additional safety check for extremely large data
        if #data > CONFIG.BUFFER_SIZE then
            DebugLog("ERROR", "Received oversized data chunk (%d bytes), discarding", #data)
            return
        end
        
        responseBuffer = responseBuffer .. data

        -- Check for confirmation prompts
        if string.find(responseBuffer, "Do you wish to") then
            DebugLog("DEBUG", "Detected PDU confirmation prompt")
            
            -- If we're already in the NEW confirmation system, auto-confirm the PDU prompt
            if isWaitingForUserConfirmation then
                DebugLog("DEBUG", "Already in user confirmation mode - auto-confirming PDU prompt")
                sendTCP("y")
                responseBuffer = ""
                return
            else
                -- Legacy PDU confirmation handling
                DebugLog("DEBUG", "Legacy PDU confirmation prompt - waiting for user input")
                pendingConfirmation = true
                SetWaitingState(true)
                SetConfirmButtonState(true)
                timeoutTimer:Start(CONFIG.TIMEOUT)
                responseBuffer = ""
                return
            end
        end

        -- Handle login prompts
        if string.find(responseBuffer, "Username:") then
            DebugLog("INFO", "Detected Username prompt, sending username...")
            CreateSafeTimer(0.5, function()
                if tcp.IsConnected and Username then
                    local username = SafeGetControlValue(Username, true)
                    sendLoginCredential(username)
                    DebugLog("INFO", "Sent username: %s", username)
                end
            end)
            responseBuffer = ""

        elseif string.find(responseBuffer, "Password:") then
            DebugLog("INFO", "Detected Password prompt, sending password...")
            CreateSafeTimer(1.0, function()
                if tcp.IsConnected and Password then
                    local password = SafeGetControlValue(Password, true)
                    sendLoginCredential(password)
                    DebugLog("INFO", "Sent password: %s", string.rep("*", #password))
                end
            end)
            responseBuffer = ""

        elseif string.find(responseBuffer, "Welcome") then
            DebugLog("INFO", "Login successful!")
            StatusUpdate("Logged In", 0)
            isLoggedIn = true  
            responseBuffer = ""

            CreateSafeTimer(5, function()
                SafeRestartPolling()
            end)

        elseif string.find(responseBuffer, "Authentication failed") then
            DebugLog("ERROR", "Login failed! Check credentials.")
            StatusUpdate("Authentication Failed", 2)
            errorStats.authenticationErrors = errorStats.authenticationErrors + 1
            errorStats.lastErrorTime = os.time()
            errorStats.lastErrorType = "authentication_failed"
            responseBuffer = ""

        -- Process commands after login
        elseif isLoggedIn and string.find(responseBuffer, CONFIG.PROMPT) then
            -- DebugLog("DEBUG", "Full response received: %s", DebugFormat(responseBuffer))

                        -- Use pcall to catch parsing errors
            local success, err = pcall(function()
                -- Extract monitoring values
                local current = string.match(responseBuffer, "RMS Current:%s*([%d%.]+)%s*A")
                if current and RMS_Current then
                    RMS_Current.String = current .. " A"
                    DebugLog("DEBUG", "Updated RMS Current: %s", RMS_Current.String)
                end

                local power = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*W")
                if power and Active_Power then
                    Active_Power.String = power .. " W"
                    DebugLog("DEBUG", "Updated Active Power: %s", Active_Power.String)
                end

                local temp = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*deg C")
                if temp and Temperature then
                    Temperature.String = temp .. " °C"
                    DebugLog("DEBUG", "Updated Temperature: %s", Temperature.String)
                end

                local humidity = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*%%")
                if humidity and Humidity then
                    Humidity.String = humidity .. " %"
                    DebugLog("DEBUG", "Updated Humidity: %s", Humidity.String)
                end
            end)
            
            if not success then
                DebugLog("ERROR", "Failed to parse monitoring values: %s", tostring(err))
            end

            -- Parse outlet states
            if string.find(responseBuffer, "show outlets") then
                local outletCount = 0
                local outletStates = {}
                
                -- DebugLog("DEBUG", "Parsing individual outlet states from response...")
                
                for outlet, name, state in string.gmatch(responseBuffer, "Outlet%s*(%d+)%s*%-?%s*([^:\r\n]*):%s*Power state:%s*(%a+)") do
                    local index = tonumber(outlet)
                    if index and Power_State and Power_State[index] then
                        local isOn = (state == "On")
                        local oldState = Power_State[index].Boolean
                        
                        if not isRevertingStates then
                            Power_State[index].Boolean = isOn
                            outletCount = outletCount + 1
                            outletStates[index] = {name = name, state = state, isOn = isOn}
                            
                            -- Set outlet name, preserving original PDU names
                            if name and name ~= "" then
                                Power_State[index].Legend = name
                                if Power_Cycle and Power_Cycle[index] then
                                    Power_Cycle[index].Legend = name
                                end
                            end
                            -- DebugLog("DEBUG", "Outlet %d: %s -> %s (%s)", index, tostring(oldState), tostring(isOn), state)
                        else
                            DebugLog("DEBUG", "Skipping outlet %d update - state reversion in progress", index)
                        end
                    end
                end
                
                -- if outletCount > 0 then
                --     DebugLog("DEBUG", "Updated %d outlet states from individual outlet response", outletCount)
                -- else
                --     DebugLog("DEBUG", "No outlet states found in individual outlet response")
                -- end
            end

            -- Parse group states
            if string.find(responseBuffer, "show outletgroups") then
                -- DebugLog("DEBUG", "Detected outlet group details response. Processing groups...")

                local detectedGroups = {}
                local groupCount = 0

                -- Extract group states and names
                local groupMatches = 0
                for group, groupName, stateString in string.gmatch(responseBuffer, "Outlet Group (%d+) %- ([^:]+).-State:%s*([^\r\n]+)") do
                    groupMatches = groupMatches + 1
                    local groupIndex = tonumber(group)
                    groupCount = math.max(groupCount, groupIndex)
                    detectedGroups[groupIndex] = true

                    local onCount = tonumber(stateString:match("(%d+) on")) or 0
                    local offCount = tonumber(stateString:match("(%d+) off")) or 0
                    local isGroupOn = (offCount == 0)

                    -- DebugLog("DEBUG", "Matched Group: %d | Name: %s | State String: '%s' | On: %d | Off: %d | IsGroupOn: %s", 
                    --     groupIndex, groupName, stateString, onCount, offCount, tostring(isGroupOn))

                    if Power_State_Group and Power_State_Group[groupIndex] then
                        local oldGroupState = Power_State_Group[groupIndex].Boolean
                        
                        if not isRevertingStates then
                            Power_State_Group[groupIndex].Boolean = isGroupOn
                            Power_State_Group[groupIndex].IsDisabled = false
                            Power_State_Group[groupIndex].Legend = groupName
                            
                            if Power_Cycle_Group and Power_Cycle_Group[groupIndex] then
                                Power_Cycle_Group[groupIndex].Legend = groupName
                                Power_Cycle_Group[groupIndex].IsDisabled = false
                            end
                            -- DebugLog("DEBUG", "Group %d (%s): %s -> %s", groupIndex, groupName, tostring(oldGroupState), tostring(isGroupOn))
                        else
                            DebugLog("DEBUG", "Skipping group %d update - state reversion in progress", groupIndex)
                        end
                    end
                end
                
                -- if groupMatches == 0 then
                --     DebugLog("DEBUG", "No group patterns matched in response")
                -- else
                --     DebugLog("DEBUG", "Matched %d group patterns", groupMatches)
                -- end
                
                -- Extract individual outlet states from group details
                local groupOutletStates = {}
                
                for outlet, state in string.gmatch(responseBuffer, "Outlet (%d+)[^:]*:%s*(%a+)") do
                    local outletIndex = tonumber(outlet)
                    if outletIndex and Power_State and Power_State[outletIndex] then
                        local isOn = (state == "On")
                        groupOutletStates[outletIndex] = state
                        -- DebugLog("DEBUG", "Found outlet %d as %s in group details", outletIndex, state)
                        
                        if isGroupOperationInProgress and not isRevertingStates then
                            local oldState = Power_State[outletIndex].Boolean
                            Power_State[outletIndex].Boolean = isOn
                            
                            local name = Power_State[outletIndex].Legend or ""
                            if name and name ~= "" then
                                Power_State[outletIndex].Legend = name
                                if Power_Cycle and Power_Cycle[outletIndex] then
                                    Power_Cycle[outletIndex].Legend = name
                                end
                            end
                            -- DebugLog("DEBUG", "Applied outlet %d state from group details: %s -> %s (%s)", outletIndex, tostring(oldState), tostring(isOn), state)
                        elseif isRevertingStates then
                            DebugLog("DEBUG", "Skipping outlet %d update from group details - state reversion in progress", outletIndex)
                        end
                    end
                end
                
                -- DebugLog("DEBUG", "Group details parsing complete")

                -- Disable unused group toggles
                if Power_State_Group then
                    for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_State_Group) do
                        if not detectedGroups[i] then
                            Power_State_Group[i].Boolean = false
                            Power_State_Group[i].IsDisabled = true
                            Power_State_Group[i].String = "Unused Group"
                            if Power_Cycle_Group and Power_Cycle_Group[i] then 
                                Power_Cycle_Group[i].IsDisabled = true
                                Power_Cycle_Group[i].String = "Unused Group"
                            end
                            DebugLog("DEBUG", "Group %d disabled (no associated group).", i)
                        else
                            if Power_Cycle_Group and Power_Cycle_Group[i] then
                                Power_Cycle_Group[i].IsDisabled = false
                            end
                        end
                    end
                end

                responseBuffer = ""
            end

            -- Update performance stats
            performanceStats.responsesReceived = performanceStats.responsesReceived + 1
            performanceStats.lastResponseTime = os.time()

            -- Handle processing state
            if pendingConfirmation or (isProcessingCommand and isUserInitiatedCommand) then
                DebugLog("DEBUG", "Keeping Processing LED ON - confirmation or user command in progress")
            else
                SetProcessingState(false)
            end
            
            -- Clear user confirmation state after PDU response is received
            if isWaitingForUserConfirmation then
                DebugLog("DEBUG", "Clearing user confirmation state after PDU response")
                isWaitingForUserConfirmation = false
                SetConfirmButtonState(false)
                lastToggledControl = nil
            end
            
            isWaitingForResponse = false  
            isProcessingCommand = false
            
            -- Update the WaitingResponse control to reflect the cleared state
            SetWaitingState(false)
            
            -- Clear group operation flags
            if isGroupOperationInProgress then
                isGroupOperationInProgress = false
                isPostGroupOperation = true
                DebugLog("DEBUG", "Group operation flag cleared")
                
                CreateSafeTimer(30, function()
                    isPostGroupOperation = false
                    DebugLog("DEBUG", "Post-group operation period ended")
                end)
            end
            
            responseBuffer = ""
            ProcessNextCommand()
        end

    elseif evt == TcpSocket.Events.Closed then
        DebugLog("ERROR", "Socket closed by remote")
        StatusUpdate("Socket Closed", 2)
        errorStats.connectionErrors = errorStats.connectionErrors + 1
        errorStats.lastErrorTime = os.time()
        errorStats.lastErrorType = "socket_closed"
        isLoggedIn = false  
        responseBuffer = ""
        
        -- Attempt reconnection if this wasn't a manual disconnect
        if Connect and Connect.Boolean then
            AttemptReconnection()
        end

    elseif evt == TcpSocket.Events.Error then
        DebugLog("ERROR", "Socket error: %s", err)
        StatusUpdate("Socket Error: " .. err, 2)
        errorStats.connectionErrors = errorStats.connectionErrors + 1
        errorStats.lastErrorTime = os.time()
        errorStats.lastErrorType = "socket_error"
        responseBuffer = ""
        
        -- Attempt reconnection for recoverable errors
        if Connect and Connect.Boolean then
            AttemptReconnection()
        end

    elseif evt == TcpSocket.Events.Timeout then
        DebugLog("ERROR", "Socket timeout")
        StatusUpdate("Socket Timeout", 2)
        errorStats.timeoutErrors = errorStats.timeoutErrors + 1
        errorStats.lastErrorTime = os.time()
        errorStats.lastErrorType = "socket_timeout"
        responseBuffer = ""
        
        -- Attempt reconnection for timeout errors
        if Connect and Connect.Boolean then
            AttemptReconnection()
        end
    end
end

-- =============================================================================
-- CONNECTION MANAGEMENT
-- =============================================================================

-- Establish TCP connection with safety checks
local function TcpOpen()
    if not Connect then
        DebugLog("ERROR", "Connect control not available")
        return
    end
    
    if Connect.Boolean then
        if tcp.IsConnected then return end
        
        local ipAddress = SafeGetControlValue(IP, true)
        local portValue = SafeGetControlValue(Port, false)
        
        if not IsValidIP(ipAddress) then
            DebugLog("ERROR", "Invalid IP address: %s", ipAddress)
            return
        end
        
        if portValue <= 0 or portValue > 65535 then
            DebugLog("ERROR", "Invalid port number: %d", portValue)
            return
        end
        
        DebugLog("INFO", "Connecting to PDU: %s:%d", ipAddress, portValue)
        
        -- Use pcall to catch connection errors
        local success, err = pcall(function()
            tcp:Connect(ipAddress, portValue)
        end)
        
        if not success then
            DebugLog("ERROR", "Failed to initiate connection: %s", tostring(err))
            StatusUpdate("Connection Failed", 2)
        end
    else
        if tcp.IsConnected then
            tcp:Disconnect()
            DebugLog("INFO", "Disconnected from PDU")
            StatusUpdate("Disconnected", 3)
            isLoggedIn = false  
        end
    end
end

-- Auto-connect when script starts
local function AutoConnect()
    if not tcp.IsConnected and IP and IP.String and IP.String ~= "" then
        DebugLog("INFO", "Auto-connecting to PDU on startup...")
        if Connect then
            Connect.Boolean = true
        end
        TcpOpen()
    end
end

-- Enhanced reconnection with exponential backoff
local function AttemptReconnection()
    if not tcp.IsConnected and IP and IP.String and IP.String ~= "" then
        local currentTime = os.time()
        
        -- Check if we've exceeded max attempts
        if performanceStats.reconnectAttempts >= CONFIG.MAX_RECONNECT_ATTEMPTS then
            DebugLog("WARNING", "Maximum reconnection attempts reached (%d). Manual intervention required.", CONFIG.MAX_RECONNECT_ATTEMPTS)
            StatusUpdate("Max Reconnect Attempts Reached", 2)
            return
        end
        
        -- Calculate exponential backoff delay
        local delay = math.min(
            CONFIG.RECONNECT_BASE_DELAY * (2 ^ performanceStats.reconnectAttempts),
            CONFIG.RECONNECT_MAX_DELAY
        )
        
        -- Add some jitter to prevent thundering herd
        delay = delay + math.random() * 2
        
        DebugLog("INFO", "Attempting reconnection #%d in %.1f seconds...", 
            performanceStats.reconnectAttempts + 1, delay)
        
        performanceStats.reconnectAttempts = performanceStats.reconnectAttempts + 1
        performanceStats.lastReconnectTime = currentTime
        
        CreateSafeTimer(delay, function()
            if not tcp.IsConnected then
                TcpOpen()
            end
        end)
    end
end

-- =============================================================================
-- TIMEOUT HANDLER
-- =============================================================================

timeoutTimer.EventHandler = function()
    -- NEW: Handle user confirmation timeout
    if isWaitingForUserConfirmation then
        DebugLog("INFO", "User confirmation timeout - cancelling pending command")
        CancelPendingCommand()
        return
    end
    
    -- OLD: Handle PDU confirmation timeout (legacy support)
    if pendingConfirmation then
        DebugLog("INFO", "PDU confirmation timeout - sending 'n'")
        sendTCP("n")
        pendingConfirmation = false
        SetConfirmButtonState(false)
        SetWaitingState(false)
        SetProcessingState(false)
        RevertToPreviousState()
        InitializeStates()
    else
        DebugLog("INFO", "Command timeout - attempting retry or reverting to previous state")
        errorStats.timeoutErrors = errorStats.timeoutErrors + 1
        errorStats.lastErrorTime = os.time()
        errorStats.lastErrorType = "command_timeout"
        
        -- Try to retry the command first
        if RetryLastCommand() then
            DebugLog("INFO", "Command retry initiated")
            return
        end
        
        -- If retry failed or not possible, revert to previous state and cleanup
        DebugLog("INFO", "Retry failed or max attempts reached - reverting state and cleaning up")
        RevertToPreviousState()
        
        -- Ensure all states are properly reset
        SetWaitingState(false)
        SetProcessingState(false)
        SetConfirmButtonState(false)
        pendingConfirmation = false
        isWaitingForResponse = false
        isProcessingCommand = false
        isUserInitiatedCommand = false
        
        -- Clear retry state
        commandRetryCount = 0
        lastCommandSent = ""
        lastCommandTime = 0
        
        InitializeStates()
    end
end

-- =============================================================================
-- EVENT HANDLERS
-- =============================================================================

-- Connection control event handlers
if IP then IP.EventHandler = TcpOpen end
if Port then Port.EventHandler = TcpOpen end
if Connect then Connect.EventHandler = TcpOpen end

-- Individual outlet power control handlers
if Power_State then
    for i = 1, math.min(CONFIG.MAX_OUTLETS, #Power_State) do
        Power_State[i].EventHandler = function(ctl)
            if not tcp.IsConnected then
                DebugLog("ERROR", "TCP connection is not available. Preventing power state toggle.")
                ctl.Boolean = not ctl.Boolean
                return
            end
            
            local operationMode = GetPowerOperationMode()
            local outletName = ctl.Legend or tostring(i)
            
            if operationMode == 1 then
                -- ON/OFF mode
                local action = ctl.Boolean and "ON" or "OFF"
                local description = string.format("Turn %s %s", outletName, action)
                local command = string.format("power outlets %d %s", i, string.lower(action))
                
                DebugLog("INFO", "Power Toggle prepared for outlet %d (%s) - %s (ON/OFF mode)", i, outletName, action)
                
                if PrepareCommand("outlet", i, command, ctl.Boolean, description) then
                    DebugLog("INFO", "Command prepared: %s", command)
                    -- Store reference to the toggled control for potential reversion
                    lastToggledControl = ctl
                else
                    -- Revert the toggle if command preparation failed
                    ctl.Boolean = not ctl.Boolean
                    lastToggledControl = nil
                end
                
            elseif operationMode == 2 then
                -- Cycle mode
                local description = string.format("Power cycle %s", outletName)
                local command = string.format("power outlets %d cycle", i)
                
                DebugLog("INFO", "Power Cycle prepared for outlet %d (%s) (Cycle mode)", i, outletName)
                
                if PrepareCommand("cycle_outlet", i, command, ctl.Boolean, description) then
                    DebugLog("INFO", "Command prepared: %s", command)
                    -- Store reference to the toggled control for potential reversion
                    lastToggledControl = ctl
                else
                    -- Revert the toggle if command preparation failed
                    ctl.Boolean = not ctl.Boolean
                    lastToggledControl = nil
                end
            end
        end
    end
end

-- Group power control handlers
if Power_State_Group then
    for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_State_Group) do
        Power_State_Group[i].EventHandler = function(ctl)
            if not tcp.IsConnected then
                ctl.Boolean = not ctl.Boolean
                return
            end
            
            local operationMode = GetPowerOperationMode()
            local groupName = Power_State_Group[i].Legend or ("Group " .. i)
            
            if operationMode == 1 then
                -- ON/OFF mode
                local action = ctl.Boolean and "ON" or "OFF"
                local description = string.format("Turn %s %s", groupName, action)
                local command = string.format("power outletgroup %d %s", i, string.lower(action))
                
                DebugLog("INFO", "Power Group Toggle prepared for group %d (%s) - %s (ON/OFF mode)", i, groupName, action)
                
                if PrepareCommand("group", i, command, ctl.Boolean, description) then
                    DebugLog("INFO", "Command prepared: %s", command)
                    -- Store reference to the toggled control for potential reversion
                    lastToggledControl = ctl
                else
                    -- Revert the toggle if command preparation failed
                    ctl.Boolean = not ctl.Boolean
                    lastToggledControl = nil
                end
                
            elseif operationMode == 2 then
                -- Cycle mode
                local description = string.format("Power cycle %s", groupName)
                local command = string.format("power outletgroup %d cycle", i)
                
                DebugLog("INFO", "Power Group Cycle prepared for group %d (%s) (Cycle mode)", i, groupName)
                
                if PrepareCommand("cycle_group", i, command, ctl.Boolean, description) then
                    DebugLog("INFO", "Command prepared: %s", command)
                    -- Store reference to the toggled control for potential reversion
                    lastToggledControl = ctl
                else
                    -- Revert the toggle if command preparation failed
                    ctl.Boolean = not ctl.Boolean
                    lastToggledControl = nil
                end
            end
        end
    end
end

-- Power cycle outlet handlers
if Power_Cycle then
    for i = 1, math.min(CONFIG.MAX_OUTLETS, #Power_Cycle) do
        Power_Cycle[i].EventHandler = function(ctl)
            if not tcp.IsConnected then
                DebugLog("ERROR", "TCP connection is not available. Preventing power cycle.")
                return
            end
            if not isProcessingCommand then
                DebugLog("INFO", "Power Cycle Outlet triggered for outlet %d", i)
                
                StoreCurrentState()
                currentOperation = {
                    type = "cycle_outlet",
                    index = i,
                    state = Power_State[i].Boolean  -- Store current state for cycle operations
                }
                
                isUserInitiatedCommand = true
                SetWaitingState(true)
                timeoutTimer:Start(CONFIG.TIMEOUT)

                sendTCP("power outlets ".. i .. " cycle")
                DebugLog("INFO", "Sent command: power outlets %d cycle", i)

                CreateSafeTimer(3, function()
                    if tcp.IsConnected then
                        sendTCP("show outlets")
                                        CreateSafeTimer(1, function()
                    if tcp.IsConnected then
                        sendTCP("show outletgroups")
                        DebugLog("DEBUG", "Sent status update commands after cycle")
                    end
                end)
                    end
                end)
            end
        end
    end
end

-- Helper function to find group index by name (case-insensitive)
local function findGroupIndexByName(name)
    if not Power_State_Group or not name then return nil end
    local searchName = string.lower(name)
    for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_State_Group) do
        if Power_State_Group[i].Legend and string.lower(Power_State_Group[i].Legend) == searchName then
            return i
        end
    end
    return nil
end

-- Function to trigger group toggle by name
local function TriggerGroupByName(groupName)
    if not groupName or groupName == "" then
        DebugLog("WARNING", "Empty group name provided for trigger")
        return false
    end
    
    if not tcp.IsConnected then
        DebugLog("ERROR", "TCP connection not available for group trigger")
        return false
    end
    
    if isProcessingCommand or isProcessingBroadcast or pendingConfirmation then
        DebugLog("WARNING", "System busy - cannot process group trigger for: %s", groupName)
        return false
    end
    
    local groupIndex = findGroupIndexByName(groupName)
    if not groupIndex then
        DebugLog("WARNING", "Group not found: %s", groupName)
        return false
    end
    
    if not Power_State_Group or not Power_State_Group[groupIndex] then
        DebugLog("ERROR", "Group control not available for index: %d", groupIndex)
        return false
    end
    
    local groupControl = Power_State_Group[groupIndex]
    local currentState = groupControl.Boolean
    
    DebugLog("INFO", "String trigger: Group '%s' (index %d) - power cycling", groupName, groupIndex)
    
    -- Store current state for potential cancellation
    StoreCurrentState()
    currentOperation = {
        type = "cycle_group",
        index = groupIndex,
        state = currentState  -- Store current state for cycle operations
    }
    
    -- Set up broadcast communication for cycle operation
    pendingCycleGroup = groupIndex
    
    isBroadcastReceiver = false
    isProcessingBroadcast = true
    isWaitingForCycle = true
    
    -- Directly trigger the group cycle operation
    isUserInitiatedCommand = true
    SetWaitingState(true)
    timeoutTimer:Start(CONFIG.TIMEOUT * 2)
    
    isGroupOperationInProgress = true

    -- Trigger broadcast for synchronized cycle across PDUs
    if BroadcastGroupCycle and BroadcastGroupName then
        BroadcastGroupName.String = groupName
        DebugLog("INFO", "Broadcasting cycle for group: %s", groupName)
        BroadcastGroupCycle:Trigger()
    end
    
    -- Send cycle command for the initiating PDU
    sendTCP("power outletgroup ".. groupIndex .. " cycle")
    DebugLog("INFO", "String trigger sent command: power outletgroup %d cycle", groupIndex)
    
    return true
end

-- Power cycle group handlers
if Power_Cycle_Group then
    for i = 1, math.min(CONFIG.MAX_GROUPS, #Power_Cycle_Group) do
        Power_Cycle_Group[i].EventHandler = function(ctl)
            if not tcp.IsConnected then
                DebugLog("ERROR", "TCP connection is not available. Preventing group cycle.")
                return
            end
            
            if isProcessingCommand or isProcessingBroadcast or pendingConfirmation then
                DebugLog("INFO", "Already processing a command, please wait...")
                return
            end
            
            local groupName = Power_State_Group and Power_State_Group[i] and Power_State_Group[i].Legend
            if groupName == "Unused Group" then return end
            
            DebugLog("INFO", "Power Cycle Group triggered for group: %s", groupName)
            
            StoreCurrentState()
            currentOperation = {
                type = "cycle_group",
                index = i,
                state = Power_State_Group[i].Boolean  -- Store current state for cycle operations
            }
            
            pendingCycleGroup = i
            
            isBroadcastReceiver = false
            isProcessingBroadcast = true
            isWaitingForCycle = true
            
            isUserInitiatedCommand = true
            SetWaitingState(true)
            timeoutTimer:Start(CONFIG.TIMEOUT * 2)

            if BroadcastGroupCycle and BroadcastGroupName then
                BroadcastGroupName.String = groupName
                DebugLog("INFO", "Broadcasting for group: %s", groupName)
                BroadcastGroupCycle:Trigger()
            end
            
            DebugLog("INFO", "Sending cycle command for initiating PDU")
            sendTCP("power outletgroup ".. i .. " cycle")
        end
    end
end

-- Broadcast handler
if BroadcastGroupCycle then
    BroadcastGroupCycle.EventHandler = function()
        local currentTime = os.time()
        local currentName = BroadcastGroupName and BroadcastGroupName.String or ""
        
        if currentName == "" or isBroadcastCancelled then 
            return 
        end
        
        if currentName == lastBroadcastName and (currentTime - lastBroadcastTime) < CONFIG.BROADCAST_COOLDOWN then
            return
        end
        
        if isProcessingBroadcast then 
            return 
        end
        
        lastBroadcastTime = currentTime
        lastBroadcastName = currentName
        isProcessingBroadcast = true
        
        DebugLog("INFO", "Processing broadcast for group: %s", currentName)
        
        local groupIndex = findGroupIndexByName(currentName)
        if not groupIndex then
            DebugLog("INFO", "No matching group found for name: %s", currentName)
            CreateSafeTimer(0.5, function()
                if BroadcastGroupName then BroadcastGroupName.String = "" end
                isProcessingBroadcast = false
            end)
            return
        end
        
        if pendingCycleGroup ~= groupIndex then
            local checkBroadcastStatus = Timer.New()
            checkBroadcastStatus.EventHandler = function()
                if isBroadcastCancelled or (BroadcastGroupName and BroadcastGroupName.String == "") then
                    DebugLog("INFO", "Broadcast cancelled, aborting receiver operation")
                    checkBroadcastStatus:Stop()
                    InitializeStates()
                    return
                end
                
                if os.time() - lastBroadcastTime >= 3 then
                    checkBroadcastStatus:Stop()
                    if tcp.IsConnected then
                        isBroadcastReceiver = true
                        receiverGroupIndex = groupIndex
                        sendTCP("power outletgroup ".. groupIndex .. " on")
                    end
                end
            end
            checkBroadcastStatus:Start(0.5)
        end
    end
end

-- Status update handlers
if WaitingResponse then
    WaitingResponse.EventHandler = function()
        UpdatePowerControls()
    end
end

-- Setup confirm button handlers
if ConfirmBtn and ConfirmBtn[1] and ConfirmBtn[2] then
    ConfirmBtn[1].EventHandler = confirmCommand
    ConfirmBtn[2].EventHandler = cancelCommand
end

-- String-based group trigger handler
if GroupTriggerString then
    GroupTriggerString.EventHandler = function(ctl)
        local groupName = ctl.String
        if groupName and groupName ~= "" then
            DebugLog("INFO", "Group trigger string received: '%s'", groupName)
            
            local success = TriggerGroupByName(groupName)
            if success then
                -- Clear the string after successful trigger
                CreateSafeTimer(0.1, function()
                    ctl.String = ""
                end)
            else
                DebugLog("WARNING", "Failed to trigger group: %s", groupName)
            end
        end
    end
end

-- Power Operation mode handlers
if Power_Operation then
    for i = 1, #Power_Operation do
        Power_Operation[i].EventHandler = function(ctl)
            if ctl.Boolean then
                HandlePowerOperationMode(i)
                DebugLog("INFO", "Power Operation mode changed to: %d", i)
            else
                -- Prevent deselection - if user tries to deselect, reselect it
                ctl.Boolean = true
                DebugLog("DEBUG", "Prevented deselection of Power Operation mode %d", i)
            end
        end
    end
end

-- =============================================================================
-- PERFORMANCE MONITORING AND HEALTH CHECKS
-- =============================================================================

-- Get system health statistics
local function GetSystemHealth()
    local health = {
        connection = {
            isConnected = tcp.IsConnected,
            isLoggedIn = isLoggedIn,
            reconnectAttempts = performanceStats.reconnectAttempts,
            lastReconnectTime = performanceStats.lastReconnectTime
        },
        performance = {
            commandsSent = performanceStats.commandsSent,
            responsesReceived = performanceStats.responsesReceived,
            errors = performanceStats.errors,
            lastResponseTime = performanceStats.lastResponseTime,
            uptime = os.time() - (performanceStats.lastResponseTime or os.time())
        },
        errors = {
            connectionErrors = errorStats.connectionErrors,
            authenticationErrors = errorStats.authenticationErrors,
            commandErrors = errorStats.commandErrors,
            timeoutErrors = errorStats.timeoutErrors,
            lastErrorTime = errorStats.lastErrorTime,
            lastErrorType = errorStats.lastErrorType
        },
        state = {
            isWaitingForResponse = isWaitingForResponse,
            isProcessingCommand = isProcessingCommand,
            isPollingActive = isPollingActive,
            pendingConfirmation = pendingConfirmation,
            isGroupOperationInProgress = isGroupOperationInProgress
        }
    }
    return health
end

-- Log system health periodically
local function LogSystemHealth()
    local health = GetSystemHealth()
    DebugLog("INFO", "System Health - Connected: %s, LoggedIn: %s, Errors: %d, Commands: %d/%d", 
        tostring(health.connection.isConnected), 
        tostring(health.connection.isLoggedIn),
        health.errors.connectionErrors + health.errors.commandErrors + health.errors.timeoutErrors,
        health.performance.responsesReceived,
        health.performance.commandsSent)
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Global error handler to catch unhandled errors
local function GlobalErrorHandler(err)
    DebugLog("CRITICAL", "Unhandled error caught: %s", tostring(err))
    DebugLog("CRITICAL", "Stack trace: %s", debug.traceback())
    
    -- Emergency cleanup
    CleanupTimers()
    if tcp and tcp.IsConnected then
        tcp:Disconnect()
    end
    
    -- Reset all states
    InitializeStates()
    
    -- Attempt recovery after delay
    CreateSafeTimer(10, function()
        DebugLog("INFO", "Attempting recovery after error...")
        if Connect and Connect.Boolean then
            TcpOpen()
        end
    end)
end

-- Set up error handler
local oldErrorHandler = debug.getmetatable("").__index
debug.setmetatable("", {
    __index = function(t, k)
        if k == "error" then
            return GlobalErrorHandler
        end
        return oldErrorHandler[k]
    end
})

-- Validate controls on startup
if not ValidateControls() then
    DebugLog("ERROR", "Required controls not found. Script may not function properly.")
end

-- Initialize states
InitializeStates()

-- Safety mechanism: Periodic check to ensure processing LED doesn't get stuck
CreateSafeTimer(60, function()
    if Processing and Processing.Boolean and not pendingConfirmation and not isWaitingForResponse and not isProcessingCommand then
        DebugLog("WARNING", "Processing LED stuck ON without active operations - forcing OFF")
        SetProcessingState(false)
    end
end)

-- Periodic health monitoring
CreateSafeTimer(300, function() -- Every 5 minutes
    LogSystemHealth()
    
    -- Check for excessive errors and log warning
    local totalErrors = errorStats.connectionErrors + errorStats.commandErrors + errorStats.timeoutErrors
    if totalErrors > 10 then
        DebugLog("WARNING", "High error count detected: %d errors in session", totalErrors)
    end
    
    -- Check connection health
    if not tcp.IsConnected and Connect and Connect.Boolean then
        DebugLog("WARNING", "Connection lost but Connect button is ON - attempting reconnection")
        AttemptReconnection()
    end
end)

-- Initialize connection
CreateSafeTimer(0.1, AutoConnect)

-- =============================================================================
-- SCRIPT INITIALIZATION COMPLETE
-- =============================================================================
DebugLog("INFO", "Legrand PDU Control Script v3.18 initialized successfully")
DebugLog("INFO", "Waiting for connection configuration...")