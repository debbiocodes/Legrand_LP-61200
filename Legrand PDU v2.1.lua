--[[ VERSION LOGS

v2 - Added confirmation button to confirm outlet toggle
v1 - Initial version

--]]
-- Control References
local IP = Controls["IP Address"]
local Port = Controls["Port"]
local Connect = Controls["Connect"]
local Status = Controls["Status"]
local Username = Controls["Username"]
local Password = Controls["Password"]

-- Controls for Data Display
local RMS_Current = Controls["RMS Current"]
local Power_State = Controls["Power state"]
local Power_State_Group = Controls["Power State Groups"]
local Temperature = Controls["Temperature"]
local Humidity = Controls["Humidity"]
local Processing = Controls["Processing"] -- A Boolean UI control
local WaitingResponse = Controls["Waiting Response"] -- A Boolean UI control
local ConfirmBtn = Controls.Confirm

-- TCP Socket Initialization
local tcp = TcpSocket.New()

-- Track Login and Polling State
local isLoggedIn = false
local isWaitingForResponse = false
local isPollingActive = false
local isProcessingCommand = false
local isWaitingResponse = false
local commandQueue = {}

-- Variables
local timeout = 5

-- Timers
local timeoutTimer = Timer.New()

-- Expected CLI Prompt
local PROMPT = "%[My PDU%] #"

-- Send TCP Command if the socket is connected
local function sendTCP(command)
  if tcp.IsConnected then
    tcp:Write(command .. "\r\n")
  else
    print("Socket not connected")
  end
 --if
end
 --func

-- Function to Update Status Display
local function StatusUpdate(msg, state)
  Status.String = msg
  Status.Value = state
end

-- Debug Formatting for TCP Data
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

-- Send Next Command from Queue
local function ProcessNextCommand()
  if isWaitingForResponse or #commandQueue == 0 then
    isProcessingCommand = false
    return
  end

  isWaitingForResponse = true
  isProcessingCommand = true
  local command = table.remove(commandQueue, 1)
  print("Sending command:", command)
  sendTCP(command)
end

-- Queue Commands for Execution
local function QueueCommands()
  if isLoggedIn and not isProcessingCommand then
    commandQueue = {
      "show inlets",
      "show sensor externalsensor 1",
      "show sensor externalsensor 2",
      "show outlets",
      "show outletgroups details"
    }
    ProcessNextCommand()
  end
end

-- Poll Data Periodically
local function PollData()
  if not isPollingActive and not isProcessingCommand then
    isPollingActive = true
    print("Polling PDU for data...")
    QueueCommands()
  end

  Timer.CallAfter(
    function()
      isPollingActive = false
      PollData()
    end,
    30
  ) -- Poll every 30 seconds
end

-- Buffer for Incoming Data
local responseBuffer = ""

-- Update the Processing state
local function SetProcessingState(state)
  Processing.Boolean = state -- This will trigger the EventHandler
  isProcessingCommand = state
end

local function SetWaitingState(state)
  WaitingResponse.Boolean = state
  isWaitingForResponse = state
end

-- Confim action
local function confirmCommand()
  -- Time delay table
  local delayFunction = {
    ["single outlet"] = 1,
    ["group outlets"] = 3
  }

  if timeoutTimer:IsRunning() then
    timeoutTimer:Stop()
  end

  SetProcessingState(true)
  SetWaitingState(false)
  sendTCP("y")

  -- **After confirming the outlet toggle, request an update for outlet groups**
  Timer.CallAfter(
    function()
      if tcp.IsConnected then
        sendTCP("show outletgroups details")
        print("[DEBUG] Sent 'show outletgroups details' command")
      end
      SetProcessingState(false)
      ConfirmBtn.IsDisabled = true
    end,
    3
  ) -- Delay to allow the change to take effect before fetching status
end
 --func
ConfirmBtn.IsDisabled = true -- disable confirmation button at start

-- TCP Socket Event Handler
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
    responseBuffer = responseBuffer .. data

    -- Debug: Only print once full login prompt or response is received
    if string.find(responseBuffer, "Username:") then
      print("Detected Username prompt, sending username...")
      Timer.CallAfter(
        function()
          if tcp.IsConnected then
            sendTCP(Username.String)
            print("Sent username:", Username.String)
          end
        end,
        0.5
      )
      responseBuffer = ""
    elseif string.find(responseBuffer, "Password:") then
      print("Detected Password prompt, sending password...")
      Timer.CallAfter(
        function()
          if tcp.IsConnected then
            sendTCP(Password.String)
            print("Sent password:", string.rep("*", #Password.String))
          end
        end,
        1.0
      ) -- Increased delay to 1 second
      responseBuffer = ""
    elseif string.find(responseBuffer, "Welcome") then
      print("Login successful!")
      StatusUpdate("Logged In", 0)
      isLoggedIn = true
      responseBuffer = ""

      -- Start polling after login
      Timer.CallAfter(PollData, 5)
    elseif string.find(responseBuffer, "Authentication failed") then
      -- Process Commands After Login
      print("[ERROR] Login failed! Check credentials.")
      StatusUpdate("Authentication Failed", 2)
      responseBuffer = ""
    elseif isLoggedIn and string.find(responseBuffer, PROMPT) then
      print("Full response received:", DebugFormat(responseBuffer))

      -- **Extract and Update RMS Current**
      local current = string.match(responseBuffer, "RMS Current:%s*([%d%.]+)%s*A")
      if current then
        RMS_Current.String = current .. " A"
        print("[DEBUG] Updated RMS Current:", RMS_Current.String)
      end

      -- **Extract and Update Temperature**
      local temp = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*deg C")
      if temp then
        Temperature.String = temp .. " °C"
        print("[DEBUG] Updated Temperature:", Temperature.String)
      end

      -- **Extract and Update Humidity**
      local humidity = string.match(responseBuffer, "Reading:%s*([%d%.]+)%s*%%")
      if humidity then
        Humidity.String = humidity .. " %"
        print("[DEBUG] Updated Humidity:", Humidity.String)
      end

      -- **Extract and Update Power Outlet States**
      for outlet, state in string.gmatch(responseBuffer, "Outlet%s*(%d+):%s*Power state:%s*(%a+)") do
        local index = tonumber(outlet)
        if index and Power_State[index] then
          Power_State[index].Boolean = (state == "On")
          print("[DEBUG] Outlet " .. index .. " is " .. state)
        end
       --if
      end
       --for

      -- **Check if we received "show outletgroups details"**
      if string.find(responseBuffer, "show outletgroups details") then
        print("[DEBUG] Detected outlet group details response. Processing groups...")

        -- **Extract and Update Power State Groups**
        local detectedGroups = {} -- Store valid group indexes
        local groupCount = 0 -- Track the number of valid groups

        for group, groupName, stateString in string.gmatch(
          responseBuffer,
          "Outlet Group (%d+) %- ([^:]+).-State:%s*([^\r\n]+)"
        ) do
          local groupIndex = tonumber(group)
          groupCount = math.max(groupCount, groupIndex) -- Keep track of the highest group index
          detectedGroups[groupIndex] = true -- Store detected group indexes

          -- **Extract "X on" and "Y off" separately**
          local onCount = stateString:match("(%d+) on") -- Always extract "X on"
          local offCount = stateString:match("(%d+) off") -- Extract "Y off" if present

          -- Convert to numbers (default to 0 if nil)
          onCount = tonumber(onCount) or 0
          offCount = tonumber(offCount) or 0

          -- **If any outlets are OFF, the group should be OFF**
          local isGroupOn = (offCount == 0)

          -- **Debug Output**
          print(
            string.format(
              "[DEBUG] Matched Group: %d | Name: %s | On: %d | Off: %d",
              groupIndex,
              groupName,
              onCount,
              offCount
            )
          )

          if Power_State_Group[groupIndex] then
            Power_State_Group[groupIndex].Boolean = isGroupOn -- If any OFF, group is OFF
            Power_State_Group[groupIndex].IsDisabled = false -- **Enable valid group toggles**
            Power_State_Group[groupIndex].Legend = groupName -- **Update UI with Group Name**
            print(
              string.format(
                "[DEBUG] Group %d (%s) updated: %s",
                groupIndex,
                groupName,
                (offCount == 0) and "On" or "Off"
              )
            )
          end
        end

        -- **Now disable only unused group toggles (AFTER getting all data)**
        for i = 1, #Power_State_Group do
          if not detectedGroups[i] then
            Power_State_Group[i].Boolean = false
            Power_State_Group[i].IsDisabled = true -- **Disable extra toggles**
            Power_State_Group[i].String = "Unused Group" -- **Indicate unused toggles**
            print(string.format("[DEBUG] Group %d disabled (no associated group).", i))
          end
        end

        -- **Clear responseBuffer after processing to prevent stale data**
        responseBuffer = ""
      end

      -- **Ensure Values Are Updating**
      print("[DEBUG] Final Values Updated:")
      print("[DEBUG] RMS Current: " .. RMS_Current.String)
      print("[DEBUG] Temperature: " .. Temperature.String)
      print("[DEBUG] Humidity: " .. Humidity.String)

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
    if tcp.IsConnected then
      return
    end
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

-- Event Handlers
IP.EventHandler = TcpOpen
Port.EventHandler = TcpOpen
Connect.EventHandler = TcpOpen
Processing.EventHandler = function()
  -- Processing LED Handler
  Loading_State.String = Processing.Boolean and "Updating Outlets..." or ""
end

-- Initialize Connection
Timer.CallAfter(TcpOpen, 5)

-----------------------------------------------------------------------
-- Power State toggles hadlers
------------------------------------------------------------------------
for i = 1, #Power_State do
  Power_State[i].EventHandler = function(ctl)
    if not tcp.IsConnected then --check if socket is connected
      print("[ERROR] TCP connection is not available. Preventing power state toggle.")
      ctl.Boolean = not ctl.Boolean -- Revert the change
      return
    end
    if not isProcessingCommand then
      print("[Action] : Power Toggle triggered")
      SetWaitingState(true)
      ConfirmBtn.IsDisabled = false
      timeoutTimer:Start(timeout) -- start timeout timer

      local powerToggleState = ctl.Boolean -- Capture the state inside the function

      if powerToggleState then
        sendTCP("power outlets " .. i .. " on")
        print("Sent command: power outlets " .. i .. " on")
      else
        sendTCP("power outlets " .. i .. " off")
        print("Sent command: power outlets " .. i .. " off")
      end
    else
      -- Prevent the toggle from changing while processing
      ctl.Boolean = not ctl.Boolean
    end
  end
end

for i = 1, #Power_State_Group do
  Power_State_Group[i].EventHandler = function(ctl)
    if not tcp.IsConnected then --check if socket is connected
      print("[ERROR] TCP connection is not available. Preventing group toggle.")
      ctl.Boolean = not ctl.Boolean -- Revert the change
      return
    end
    print("[Action] : Power Group Toggle triggered")
    SetWaitingState(true)
    ConfirmBtn.IsDisabled = false
    timeoutTimer:Start(timeout) -- start timeout timer

    if ctl.Boolean == true then
      sendTCP("power outletgroup " .. i .. " on")
      print("Sent command: power outletgroup " .. i .. " on")
    else
      sendTCP("power outletgroup " .. i .. " off")
      print("Sent command: power outletgroup " .. i .. " off")
    end
  end
end

-- Setup confirm button handler to send confirmation
ConfirmBtn.EventHandler = function()
  if isWaitingForResponse then
    confirmCommand()
  end
end

--
timeoutTimer.EventHandler = function()
  if timeoutTimer:IsRunning() then
    timeoutTimer:Stop()
    print("Timer Stopped")
  end
  
  if isWaitingForResponse then
    sendTCP("n")
    print("Sent command: n (Cancel)")
    -- **After canceling the outlet toggle, request an update for outlet groups**
    Timer.CallAfter(
      function()
        if tcp.IsConnected then
          sendTCP("show outletgroups details")
          print("[DEBUG] Sent 'show outletgroups details' command")
        end
        SetProcessingState(false)
        SetWaitingState(false)
        ConfirmBtn.IsDisabled = true
      end,
      1.0
    ) -- Delay to allow the change to take effect before fetching status
  end
end

-- Function to enable/disable Power_State and Power_State_Group
local function UpdatePowerControls()
  local shouldDisable = Processing.Boolean or WaitingResponse.Boolean
  for i = 1, #Power_State do
    Power_State[i].IsDisabled = shouldDisable
  end
  for i = 1, #Power_State_Group do
    Power_State_Group[i].IsDisabled = shouldDisable
  end
end

-- Update state when Processing or WaitingResponse changes
Processing.EventHandler = function()
  UpdatePowerControls()
end

WaitingResponse.EventHandler = function()
  UpdatePowerControls()
end
