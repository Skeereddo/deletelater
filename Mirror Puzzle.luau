--Credit: Discord Username: naitsirhc._ | Roblox Username: Skeeredd
--!strict

-- Store each service once so every part of the script uses the same service
local Players = game:GetService("Players") -- PlayerRemoving uses these server player objects
local RunService = game:GetService("RunService") -- Heartbeat runs the update loop
local TweenService = game:GetService("TweenService") -- TweenService moves the door and shutter
local ProximityPromptService = game:GetService("ProximityPromptService") -- One event handles every prompt
local ServerStorage = game:GetService("ServerStorage") -- ServerStorage keeps the beam template off the client

-- These limits keep every ray check small and safe
local MAX_SEGMENTS = 12 -- Stop a beam after a fixed number of hits
local MAX_DISTANCE = 180 -- Use one distance limit for the full beam path
local SURFACE_OFFSET = 0.025 -- Leave a small gap so the next ray does not hit the same face
local TRACE_INTERVAL = 1 / 30 -- Wait between ray checks when parts change

-- Mirror rotation uses eight fixed steps
local ROTATION_STEPS = 8 -- Convert every mirror value into one of eight steps
local INPUT_COOLDOWN = 0.18 -- Stop one player from using prompts too fast

-- Each color marks one source and its receiver
local CYAN = Color3.fromRGB(71, 226, 255) -- Cyan marks the first circuit
local ORANGE = Color3.fromRGB(255, 181, 76) -- Orange marks the second circuit
local DIM = Color3.fromRGB(60, 76, 93) -- Dim is the color for a receiver that is off

-- Types show the data shared by the main parts of the script
type Mode = "Routing" | "Solved" | "Resetting"

type Mirror = {
	part: BasePart,
	origin: CFrame,
	step: number,
	initial: number,
}

type Circuit = {
	source: BasePart,
	receiver: BasePart,
	color: Color3,
	pool: { BasePart },
	used: number,
	powered: boolean,
	termination: string,
}

-- These references point to parts made in Studio
local lab = workspace:WaitForChild("PhotonLab") -- Stop clearly if the Studio model is missing

local optics = lab:WaitForChild("Optics") -- Only these parts can affect a ray
local emitters = lab:WaitForChild("Emitters") -- Sources give each circuit its first position and direction
local controls = lab:WaitForChild("Controls") -- Prompts in this folder control the puzzle
local visuals = lab:WaitForChild("Runtime") -- These parts show beams and do not block rays

local door = lab:WaitForChild("Door") :: BasePart -- The door is moved and checked for players
local shutter = optics:WaitForChild("Shutter") :: BasePart -- The shutter blocks a beam when lowered
local console = controls:WaitForChild("Console") :: BasePart -- The SurfaceGui on this part shows the mode

local segmentTemplate = ServerStorage:WaitForChild("LaserSegmentTemplate") :: BasePart -- Clone this Studio template for every beam part

-- Save the starting CFrames so reset always uses the same positions
local closedDoor = door.CFrame
local raisedDoor = closedDoor + Vector3.new(0, 10, 0)

local openShutter = shutter.CFrame
local blockedShutter = openShutter - Vector3.new(0, 8, 0)

-- Runtime tables keep mirror data, circuit data, and player times
local mirrors: { [BasePart]: Mirror } = {} -- The part is the key used to find its mirror data
local circuits: { Circuit } = {} -- Each circuit stores its source, receiver, and beam pool
local cooldowns: { [Player]: number } = {} -- Store the next allowed prompt time for each player

local mode: Mode = "Routing" -- Routing accepts input, Solved locks input, Resetting protects the door

-- A change sets this flag and the next update runs one ray check
local dirty = true -- Startup needs one full ray check
local nextTrace = 0 -- This time groups quick changes into one ray check
local tracePasses = 0 -- This count shows how many ray checks finished

-- These saved tween handles let a new action stop an old tween
local doorTween: Tween? = nil -- Keep the door tween so another action can stop it
local closingSince: number? = nil -- Start this timer only after the doorway is empty

local shutterClosed = false -- This selects the open or blocked shutter pose
local shutterTween: Tween? = nil -- Keep the shutter tween so another action can stop it

-- Ray checks and door checks reuse their filter objects
local rayParams = RaycastParams.new() -- Reuse the ray filter for every ray check
rayParams.IncludeInstances = { optics } -- Only parts in Optics can be hit by a ray
rayParams.IgnoreWater = true -- Water is not part of this indoor puzzle

local overlapParams = OverlapParams.new() -- Reuse the door check filter
overlapParams.MaxParts = 1 -- One player is enough to keep the door open

-- Mark the beam path as changed and let the update loop check it
local function invalidate() -- Listeners set dirty so the next update checks the beam path
	dirty = true
end

-- Make one beam part from the Studio template
local function makeSegment(color: Color3, index: number): BasePart
	local segment = segmentTemplate:Clone() -- The template gives every beam part the same base settings
	segment.Name = "Segment" .. index -- Name the clone so it can be found in Runtime
	segment.Color = color -- Apply the circuit color to the clone
	segment.Parent = visuals -- Add the ready clone to the Runtime folder

	return segment
end

-- Put one saved beam part between two ray points
local function showSegment(circuit: Circuit, index: number, start: Vector3, finish: Vector3)
	local segment = circuit.pool[index] -- Reuse a saved beam part instead of making a new one
	local length = (finish - start).Magnitude -- The part length matches this beam section

	if length < 0.001 then
		segment.Transparency = 1 -- Hide a beam part when its two points are too close
		return
	end

	segment.Size = Vector3.new(0.09, 0.09, length) -- Resize the saved part to this beam section
	segment.CFrame = CFrame.lookAt((start + finish) * 0.5, finish) -- Center and aim the part along the beam section
	segment.Transparency = 0 -- Show only the beam parts used by this ray check
end

-- Follow one circuit from its source to its receiver
local function traceCircuit(circuit: Circuit)
	local origin = circuit.source.Position -- Start at the source position
	local direction = circuit.source.CFrame.LookVector -- Start in the source LookVector direction
	local remaining = MAX_DISTANCE -- Track the distance left for all later hits
	local powered = false -- This circuit is on only when its receiver is hit
	local used = 0 -- Count the beam parts used by this check
	local termination = "Bounce limit" -- Save a reason in case the loop uses every step

	for index = 1, MAX_SEGMENTS do
		local result = workspace:Raycast(origin, direction * remaining, rayParams) -- Find the next hit or the end of the beam path
		local finish = if result then result.Position else origin + direction * remaining -- Draw to the hit point or to the end of the distance limit
		showSegment(circuit, index, origin, finish)
		used = index -- Remember the latest beam part index

		if not result then
			termination = "Range exhausted" -- End when no hit is found or no distance remains
			break
		end

		remaining -= result.Distance -- Remove the traveled distance before the next hit

		if result.Instance == circuit.receiver then
			powered = true -- Mark the circuit on after its receiver is hit
			termination = "Receiver" -- Record that the receiver ended the beam path
			break
		end

		local hit = result.Instance -- Keep the hit separate before checking its type
		local mirror = if hit:IsA("BasePart") then mirrors[hit] else nil -- Use the mirror table only for BaseParts

		if not mirror then
			termination = "Absorbed" -- Stop at a wall, shutter, or other non-mirror part
			break
		end

		local localNormal = mirror.part.CFrame:VectorToObjectSpace(result.Normal) -- Check the hit normal in mirror space
		if math.abs(localNormal.Z) < 0.99 then -- Ignore hits on the thin mirror edge
			termination = "Mirror edge"
			break
		end

		if remaining <= SURFACE_OFFSET then
			termination = "Range exhausted" -- End when no hit is found or no distance remains
			break
		end

		local normal = result.Normal -- Use the world normal for reflection
		direction = (direction - 2 * direction:Dot(normal) * normal).Unit -- Reflect the beam direction across the mirror normal

		origin = result.Position + direction * SURFACE_OFFSET -- Start past the mirror face to avoid a second hit
		remaining -= SURFACE_OFFSET -- Count the small gap in the distance limit
	end

	for index = used + 1, circuit.used do
		circuit.pool[index].Transparency = 1 -- Hide old beam parts after a shorter path
	end

	circuit.used = used -- Save the current number of beam parts
	circuit.termination = termination -- Save the end reason for inspection
	circuit.source:SetAttribute("Segments", used) -- Share the beam length as an attribute
	circuit.source:SetAttribute("Termination", termination) -- Share the end reason as an attribute

	if circuit.powered ~= powered then
		circuit.powered = powered -- Save the new receiver state
		circuit.receiver.Color = if powered then circuit.color else DIM -- Match receiver color to its state
		circuit.receiver:SetAttribute("Powered", powered) -- Share receiver state with the place
	end
end

-- Read the mirror step and apply its CFrame
local function syncMirror(mirror: Mirror)
	local raw = mirror.part:GetAttribute("Step") -- Read the editable mirror step

	if typeof(raw) ~= "number" or raw ~= raw or math.abs(raw) == math.huge then
		mirror.part:SetAttribute("Step", mirror.step) -- Restore the last safe step when input is not a number
		return
	end

	local step = math.round(raw) % ROTATION_STEPS -- Round and wrap the value into the supported steps
	mirror.step = step -- Save the valid step for the next prompt
	mirror.part.CFrame = mirror.origin * CFrame.Angles(0, step * math.pi / 4, 0) -- Keep the position and rotate the mirror around Y

	if raw ~= step then
		mirror.part:SetAttribute("Step", step) -- Write the valid step back to Studio state
	end

	invalidate()
end

-- Keep the in-world console text in step with the mode
local function updateConsole()
	local status = "CONNECT BOTH BEAMS!" -- The console starts with the unsolved message

	if mode == "Solved" then
		status = "PUZZLE SOLVED!" -- Show this only when both circuits are on
	elseif mode == "Resetting" then
		status = "RESETTING" -- Show this while reset protects the doorway
	end

	local surface = console:FindFirstChildOfClass("SurfaceGui") -- The console display is optional
	local readout = if surface then surface:FindFirstChild("Readout") else nil -- Find the text object only when the display exists

	if readout and readout:IsA("TextLabel") then
		readout.Text = status -- Show the current mode in the lab
	end
end

-- Change the shared mode and update every prompt
local function setMode(value: Mode)
	mode = value -- Save the mode used by every other system
	lab:SetAttribute("State", value) -- Share the mode as a place attribute
	for _, descendant in controls:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			local isReset = descendant:GetAttribute("Action") == "Reset" -- Reset stays usable after the puzzle is solved
			descendant.Enabled = value ~= "Resetting" and (value ~= "Solved" or isReset) -- Disable normal prompts during reset and after solving
		end
	end

	updateConsole()
end

-- Move the door to a saved CFrame
local function moveDoor(target: CFrame)

	if doorTween then
		doorTween:Cancel()
	end

	local tween = TweenService:Create( -- A local Tween value keeps :Play() type-safe
		door,
		TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = target }
	)

	doorTween = tween -- Save the door tween handle
	tween:Play() -- Start the tween after saving its handle
end

-- Check whether a player is still in the doorway
local function doorwayOccupied(): boolean
	local characters: { Instance } = {} -- The filter uses full character models

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(characters, player.Character) -- Add each player character to the door filter
		end
	end

	overlapParams.IncludeInstances = characters -- Check only player characters in the door area
	return #workspace:GetPartBoundsInBox(closedDoor, door.Size + Vector3.new(2, 1, 3), overlapParams) > 0 -- Keep the door open while a player is inside
end

-- Return the shutter, mirrors, and door to their starting state
local function resetPuzzle()
	setMode("Resetting") -- Disable normal controls before reset starts
	closingSince = nil -- Clear the reset timer
	door.CanCollide = false -- An open door must not trap a player
	moveDoor(raisedDoor)

	if shutterTween then
		shutterTween:Cancel()
	end

	shutterClosed = false -- Reset always opens the shutter
	shutter.CFrame = openShutter -- Put the shutter back at its saved open CFrame

	for _, mirror in mirrors do
		mirror.part:SetAttribute("Step", mirror.initial) -- Reset each mirror to its first step
	end

	invalidate()
end

-- Use a per-player wait to stop repeated prompt actions
local function validInteraction(player: Player, prompt: ProximityPrompt): boolean
	local now = os.clock() -- Use server time for cooldowns and reset timing
	if now < (cooldowns[player] or 0) then -- Reject a prompt before its wait ends
		return false
	end

	cooldowns[player] = now + INPUT_COOLDOWN -- Set the next time this player may use a prompt

	return true
end

-- Route one prompt action to the matching puzzle part
local function handlePrompt(prompt: ProximityPrompt, player: Player)

	if not validInteraction(player, prompt) or mode == "Resetting" then
		return
	end

	local action = prompt:GetAttribute("Action") -- Prompt attributes choose the action
	if action == "Reset" then
		resetPuzzle()
		return
	end

	if mode == "Solved" then
		return
	end

	if action == "Rotate" then
		local target = optics:FindFirstChild(tostring(prompt:GetAttribute("Target"))) -- Find only the mirror named by the prompt
		local mirror = if target and target:IsA("BasePart") then mirrors[target] else nil -- Use the mirror table only for BaseParts

		if mirror then
			mirror.part:SetAttribute("Step", (mirror.step + 1) % ROTATION_STEPS) -- Move the mirror forward by one step
		end
	elseif action == "Shutter" then
		shutterClosed = not shutterClosed -- Switch between the two shutter poses

		if shutterTween then
			shutterTween:Cancel()
		end

		local target = if shutterClosed then blockedShutter else openShutter -- Choose the new shutter CFrame
		local tween = TweenService:Create(shutter, TweenInfo.new(0.3), { CFrame = target }) -- A local Tween value keeps :Play() type-safe

		shutterTween = tween -- Save the shutter tween handle
		tween:Play() -- Start the tween after saving its handle
	end
end

-- Add every Studio mirror to the mirror table
for _, part in optics:GetChildren() do
	if part:IsA("BasePart") and part:GetAttribute("OpticType") == "Mirror" then
		local initial = part:GetAttribute("InitialStep") -- Read the mirror step

		local mirror: Mirror = {
			part = part,
			origin = CFrame.new(part.Position),
			step = initial,
			initial = initial,
		}

		mirrors[part] = mirror -- Register the mirror by its part
		part:SetAttribute("Step", initial) -- Keep the Studio step as the editable value
		syncMirror(mirror)

		part:GetAttributeChangedSignal("Step"):Connect(function()
			syncMirror(mirror)
		end)
	end
end

-- Create the two circuits and their saved beam parts
for index, name in { "CYAN", "ORANGE" } do
	local source = emitters:WaitForChild(name) :: BasePart -- Get the source for this circuit
	local receiver = optics:WaitForChild(name .. "Receiver") :: BasePart -- Get the matching receiver
	local color = if index == 1 then CYAN else ORANGE -- Pick the color for this circuit

	local circuit: Circuit = {
		source = source,
		receiver = receiver,
		color = color,
		pool = {},
		used = 0,
		powered = false,
		termination = "Pending",
	}

	for segmentIndex = 1, MAX_SEGMENTS do
		table.insert(circuit.pool, makeSegment(color, segmentIndex)) -- Fill the circuit beam pool once
	end

	receiver.Color = DIM -- Receivers start off
	receiver:SetAttribute("Powered", false) -- Receivers start with a shared off state
	table.insert(circuits, circuit) -- Add this circuit to the solve check

	source:GetPropertyChangedSignal("CFrame"):Connect(invalidate) -- A moved source needs a new ray check
end

-- Changes to an optic part request a new ray check
for _, part in optics:GetDescendants() do
	if part:IsA("BasePart") then
		part:GetPropertyChangedSignal("CFrame"):Connect(invalidate) -- A moved optic needs a new ray check
		part:GetPropertyChangedSignal("Size"):Connect(invalidate) -- A resized optic needs a new ray check
	end
end

-- All prompt actions enter through one server event
ProximityPromptService.PromptTriggered:Connect(handlePrompt)

-- Remove player data when the player leaves
Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil -- Remove the player from the cooldown table
end)

-- The update loop traces changed beams and controls reset safety
RunService.Heartbeat:Connect(function()
	local now = os.clock() -- Use server time for cooldowns and reset timing

	if dirty and now >= nextTrace then -- Trace only after a change and after the wait time
		dirty = false -- Clear the flag before tracing
		nextTrace = now + TRACE_INTERVAL -- Set the next allowed trace time

		for _, circuit in circuits do
			traceCircuit(circuit)
		end

		tracePasses += 1 -- Count completed ray checks
		lab:SetAttribute("TracePasses", tracePasses)
	end

	if mode == "Routing" then
		if circuits[1].powered and circuits[2].powered and not dirty then -- Solve only when both receivers are on

			setMode("Solved") -- Lock prompts before opening the door
			door.CanCollide = false -- An open door must not trap a player
			moveDoor(raisedDoor)
		end
	elseif mode == "Resetting" then

		if doorwayOccupied() then -- Keep the door up while a player is inside
			if closingSince then
				closingSince = nil -- Clear the reset timer
				moveDoor(raisedDoor)
			end

		elseif not closingSince then -- Start closing only after an empty doorway check
			closingSince = now
			moveDoor(closedDoor)

		elseif now - closingSince >= 0.75 then -- Wait for the closing tween before restoring collision
			door.CFrame = closedDoor -- Snap to the exact closed CFrame
			door.CanCollide = true -- Restore collision after the doorway is clear
			closingSince = nil -- Clear the reset timer
			setMode("Routing")
		end
	end
end)

-- Start with controls enabled and the console in its first state
setMode("Routing")
