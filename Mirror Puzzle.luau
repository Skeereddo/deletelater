--Credit: Discord Username: naitsirhc._ | Roblox Username: Skeeredd
--!strict

-- Services are fetched once so every function shares one reference instead of calling GetService again
local Players = game:GetService("Players") -- Builds the character filter for the doorway check and fires PlayerRemoving for cooldown cleanup
local TweenService = game:GetService("TweenService") -- Interpolates CFrame on the server, and the anchored parts replicate the motion to every client
local ProximityPromptService = game:GetService("ProximityPromptService") -- PromptTriggered fires for every prompt in the place, so one connection serves all controls
local ServerStorage = game:GetService("ServerStorage") -- Clients cannot see ServerStorage, so the beam template only replicates once the server clones it

-- A beam bouncing between two facing mirrors would never stop, so a hop count and a shared length both cap the loop
local MAX_SEGMENTS = 12 -- Each hop costs one Raycast and one pooled part, so this number is also the pool size per circuit
local MAX_DISTANCE = 180 -- Length budget shared by every hop, so a beam that leaves through a gap is not drawn across the whole map
local SURFACE_OFFSET = 0.025 -- The next ray starts this far off the mirror, because a ray starting on the face can hit that same face at distance 0
local EDGE_THRESHOLD = 0.99 -- The reflective faces of a mirror have an object-space normal of almost exactly +Z or -Z, every other face is an edge
local BEAM_THICKNESS = 0.09 -- X and Y size of every beam part, only the Z size follows the segment length

-- Mirrors snap to 45 degree steps, so an axis-aligned beam always leaves a mirror axis-aligned and the puzzle has exact solutions
local ROTATION_STEPS = 8 -- 8 steps of 45 degrees make one full turn, and the modulo in setMirrorStep wraps the count back to 0
local STEP_ANGLE = 2 * math.pi / ROTATION_STEPS -- Radians per step, computed once because CFrame.Angles takes radians
local INPUT_COOLDOWN = 0.18 -- Holding the prompt key retriggers fast, so each player gets a short server-side cooldown

-- Tween settings are built once and reused, since TweenInfo is immutable and safe to share between tweens
local DOOR_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut) -- Quad InOut eases both ends, so the heavy door does not snap at the start or stop
local SHUTTER_TWEEN = TweenInfo.new(0.3) -- The shutter is small, so a short linear slide is enough
local DOOR_LIFT = 8.9 -- Gap between the top of the closed door and the top of the lintel, so the open door sits fully inside the lintel
local SHUTTER_DROP = 8 -- Lowers the shutter from above the beam height into the cyan beam path

local DIM = Color3.fromRGB(60, 76, 93) -- Unpowered receiver colour, dark so the powered circuit colour stands out

-- One row per source/receiver pair, matched to Studio parts by name, so a new circuit needs one row and two parts
local CIRCUIT_TYPES = {
	{ name = "CYAN", color = Color3.fromRGB(71, 226, 255) },
	{ name = "ORANGE", color = Color3.fromRGB(255, 181, 76) },
}

-- Routing accepts input, Solved locks the puzzle with the door open, Resetting waits for the doorway to clear
type Mode = "Routing" | "Solved" | "Resetting"

-- origin keeps only the mirror position, so a rotation is always applied to a clean CFrame and never adds up float error
type Mirror = {
	part: BasePart,
	origin: CFrame,
	step: number,
	initial: number,
}

-- pool holds the beam parts made at startup, and used counts how many the last trace showed, so a shorter path knows what to hide
type Circuit = {
	source: BasePart,
	receiver: BasePart,
	color: Color3,
	pool: { BasePart },
	used: number,
	powered: boolean,
}

-- A table keyed by Mode replaces an if/elseif chain, and the Mode type makes a missing state a type error
local STATUS: { [Mode]: string } = {
	Routing = "CONNECT BOTH BEAMS!",
	Solved = "PUZZLE SOLVED!",
	Resetting = "RESETTING",
}

-- WaitForChild makes the script wait for the Studio model instead of failing on a nil index if it streams in late
local lab = workspace:WaitForChild("PhotonLab")
local optics = lab:WaitForChild("Optics") -- The only folder rays can hit, so beam parts and decoration never block a beam
local emitters = lab:WaitForChild("Emitters") -- Each source gives its circuit a start position and, through its LookVector, a start direction
local controls = lab:WaitForChild("Controls") -- Every ProximityPrompt lives here, so the prompt list is collected from one folder
local visuals = lab:WaitForChild("Runtime") -- Pooled beam parts are parented here, outside Optics, so they are never raycast targets

local door = lab:WaitForChild("Door") :: BasePart -- The cast tells the type checker that CFrame and CanCollide exist on this instance
local doorZone = lab:WaitForChild("DoorZone") :: BasePart -- Invisible CanTouch volume around the doorway that gives Touched events for the reset safety
local shutter = optics:WaitForChild("Shutter") :: BasePart -- In Optics so it absorbs the beam when lowered
local readout = controls:WaitForChild("Console"):WaitForChild("Sign"):WaitForChild("Readout") :: TextLabel -- Cached once because setMode writes to it on every mode change
local segmentTemplate = ServerStorage:WaitForChild("LaserSegmentTemplate") :: BasePart -- Neon, anchored, no collision or query, so clones only need size and colour

-- Poses are saved before anything moves, so reset and close always return to the exact authored CFrame
local closedDoor = door.CFrame
local raisedDoor = closedDoor + Vector3.new(0, DOOR_LIFT, 0) -- Adding a Vector3 to a CFrame moves it in world space and keeps the rotation
local openShutter = shutter.CFrame
local blockedShutter = openShutter - Vector3.new(0, SHUTTER_DROP, 0)

local mirrors: { [BasePart]: Mirror } = {} -- Keyed by part, so a ray hit becomes a mirror lookup in O(1) with no search
local circuits: { Circuit } = {} -- An array, because the solve check simply loops over every circuit
local prompts: { ProximityPrompt } = {} -- Collected once, so setMode does not walk controls:GetDescendants() on every change
local cooldowns: { [Player]: number } = {} -- Next os.clock() time each player may trigger a prompt again
local doorwayParts: { [BasePart]: true } = {} -- Character parts inside DoorZone, kept by Touched/TouchEnded so it matches the touch events exactly

local mode: Mode = "Routing"
local traceQueued = false -- True while a trace is already deferred, so many changes in one frame cost one trace

local doorTween: Tween? = nil -- Kept so a new door move can cancel the running one instead of fighting it
local doorTarget = closedDoor -- Where the door is heading, which tells whether a close is already running
local shutterTween: Tween? = nil
local shutterClosed = false

-- RaycastParams is reused, because building new params for every ray creates garbage on each call
local rayParams = RaycastParams.new()
rayParams.IncludeInstances = { optics } -- Include list, so walls, mirrors, receivers and the shutter are the only possible hits

-- Every animated move goes through here, so cancelling the old tween and playing the new one is written once
local function playTween(previous: Tween?, part: BasePart, info: TweenInfo, target: CFrame): Tween
	if previous then
		previous:Cancel() -- Without this, two tweens would write the same CFrame every frame and the part would jitter
	end

	local tween = TweenService:Create(part, info, { CFrame = target })
	tween:Play()

	return tween -- Returned so the caller can store the handle and later listen to Completed
end

-- Door moves also record their target, which closeDoorWhenClear and the Touched handler read
local function moveDoor(target: CFrame): Tween
	doorTarget = target
	doorTween = playTween(doorTween, door, DOOR_TWEEN, target)

	return doorTween :: Tween -- doorTween was just assigned, so the cast only removes the optional from its type
end

-- One place switches the mode, so prompts and the console can never disagree with the mode
local function setMode(value: Mode)
	mode = value

	for _, prompt in prompts do
		-- Enabled is set on the server and replicates, so a client cannot trigger a prompt the puzzle has locked
		prompt.Enabled = value == "Routing" or (value == "Solved" and prompt:GetAttribute("Action") == "Reset")
	end

	readout.Text = STATUS[value]
end

-- Clones the template once per pool slot at startup, so tracing never creates or destroys instances
local function makeSegment(color: Color3, index: number): BasePart
	local segment = segmentTemplate:Clone()
	segment.Name = "Segment" .. index -- Numbered names make the pool readable in the Explorer while testing
	segment.Color = color
	segment.Transparency = 1 -- Starts hidden, and the first trace shows only the slots it uses
	segment.Parent = visuals -- Parented last, so all properties replicate together in one change

	return segment
end

-- Stretches one pooled part between two points to draw one hop of the beam
local function showSegment(segment: BasePart, start: Vector3, finish: Vector3)
	local length = (finish - start).Magnitude

	segment.Size = Vector3.new(BEAM_THICKNESS, BEAM_THICKNESS, length) -- Z is the long axis, because CFrame.lookAt points -Z at the target
	segment.CFrame = CFrame.lookAt((start + finish) * 0.5, finish) -- The midpoint centers the part, and lookAt aims its long axis at the finish
	segment.Transparency = if length < 0.001 then 1 else 0 -- A zero-length hop has no visible direction, so it stays hidden
end

-- Follows one beam hop by hop and reports if it ended on its own receiver
local function traceCircuit(circuit: Circuit)
	local origin = circuit.source.Position
	local direction = circuit.source.CFrame.LookVector -- Already unit length, so direction * remaining is exactly the ray length left
	local remaining = MAX_DISTANCE
	local powered = false
	local used = 0

	for index = 1, MAX_SEGMENTS do
		local result = workspace:Raycast(origin, direction * remaining, rayParams) -- The ray length is the remaining budget, so the full path never exceeds MAX_DISTANCE
		local finish = if result then result.Position else origin + direction * remaining -- With no hit the beam is drawn to the end of its budget

		showSegment(circuit.pool[index], origin, finish)
		used = index

		if not result then
			break
		end

		remaining -= result.Distance

		if result.Instance == circuit.receiver then
			powered = true -- Only its own receiver counts, the other colour's receiver absorbs the beam like a wall
			break
		end

		-- Raycast only returns BaseParts here because Optics holds no terrain, so the cast is safe for the table lookup
		local mirror = mirrors[result.Instance :: BasePart]
		if not mirror then
			break -- Walls, the shutter and the wrong receiver absorb the beam
		end

		-- VectorToObjectSpace rotates the world normal into mirror space, where the two reflective faces point along Z
		local localNormal = mirror.part.CFrame:VectorToObjectSpace(result.Normal)
		if math.abs(localNormal.Z) < EDGE_THRESHOLD or remaining <= SURFACE_OFFSET then
			break -- An edge hit absorbs the beam, and with no budget left there is nothing to draw past the mirror
		end

		-- Reflection r = d - 2(d.n)n: d.n is how much of the direction points into the face, removing it twice flips that part and keeps the rest
		direction = (direction - 2 * direction:Dot(result.Normal) * result.Normal).Unit -- .Unit removes the tiny length drift float math adds on every bounce
		origin = result.Position + direction * SURFACE_OFFSET
		remaining -= SURFACE_OFFSET -- The offset is real travel, so it comes out of the same budget
	end

	-- Slots after the last used one may still show an older, longer path, so only that range is hidden
	for index = used + 1, circuit.used do
		circuit.pool[index].Transparency = 1
	end

	circuit.used = used

	if circuit.powered ~= powered then
		circuit.powered = powered -- Colour is only written when the state flips, so an unchanged trace replicates nothing
		circuit.receiver.Color = if powered then circuit.color else DIM
	end
end

-- Retraces every circuit, then solves the puzzle when all receivers are powered
local function traceAll()
	traceQueued = false -- Cleared first, so a change made by this trace's own effects can queue the next one

	local solved = true
	for _, circuit in circuits do
		traceCircuit(circuit)
		solved = solved and circuit.powered
	end

	if solved and mode == "Routing" then
		setMode("Solved") -- Locks the mirrors first, so the winning layout cannot be changed while the door opens
		door.CanCollide = false -- Turned off before the tween, so the moving door never pushes a player
		moveDoor(raisedDoor)
	end
end

-- Called by anything that changes the beam path; this is the only place a trace is scheduled
local function invalidate()
	if traceQueued then
		return
	end

	traceQueued = true
	task.defer(traceAll) -- Runs at the end of the current resumption cycle, so a reset that moves four mirrors costs one trace
end

-- Rotates a mirror to a step and asks for a new trace
local function setMirrorStep(mirror: Mirror, step: number)
	mirror.step = step % ROTATION_STEPS -- Luau % always returns a result with the divisor's sign, so step + 1 from 7 wraps to 0
	mirror.part.CFrame = mirror.origin * CFrame.Angles(0, mirror.step * STEP_ANGLE, 0) -- Rotation is built from the saved origin, so turns never accumulate
	invalidate()
end

-- True while any character part is inside the doorway volume
-- A server spatial query is not used here: touches are reported by the client that owns the character, ahead of the
-- server copy of its position, so the query still sees the player for a moment after the last TouchEnded
local function doorwayOccupied(): boolean
	for part in doorwayParts do
		if part:IsDescendantOf(workspace) then
			return true
		end

		doorwayParts[part] = nil -- A part destroyed inside the zone, for example on respawn, never fires TouchEnded
	end

	return false
end

-- Closes the door after a reset, but only once nobody stands in the doorway
local function closeDoorWhenClear()
	if mode ~= "Resetting" or doorTarget == closedDoor or doorwayOccupied() then
		return -- A close is already running, the door was never opened, or a player would be crushed
	end

	-- Once fires a single time and disconnects itself, so repeated closes do not pile up Completed connections
	moveDoor(closedDoor).Completed:Once(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			door.CanCollide = true -- Collision only returns when the door is fully down, a cancelled close reports Cancelled
			setMode("Routing")
		end
	end)
end

-- Puts the shutter and mirrors back, and only starts the door sequence when the door is actually open
local function resetPuzzle()
	shutterClosed = false
	shutterTween = playTween(shutterTween, shutter, SHUTTER_TWEEN, openShutter)

	for _, mirror in mirrors do
		setMirrorStep(mirror, mirror.initial)
	end

	if mode == "Solved" then
		setMode("Resetting") -- Locks every prompt until the door is closed again
		closeDoorWhenClear() -- If someone is inside, TouchEnded retries this once they step out
	end
end

-- Rejects a prompt that arrives before the player's cooldown has ended
local function validInteraction(player: Player): boolean
	local now = os.clock() -- Monotonic server clock, so changing the system time cannot skip a cooldown

	if now < (cooldowns[player] or 0) then
		return false
	end

	cooldowns[player] = now + INPUT_COOLDOWN
	return true
end

-- Every prompt routes here, and the Action attribute chooses what it does
local function handlePrompt(prompt: ProximityPrompt, player: Player)
	if not validInteraction(player) then
		return
	end

	local action = prompt:GetAttribute("Action")

	-- Disabled prompts already cannot fire, the mode checks also cover a prompt that fired in the same frame the mode changed
	if action == "Reset" then
		if mode ~= "Resetting" then
			resetPuzzle()
		end
	elseif mode == "Routing" then
		if action == "Rotate" then
			local target = optics:FindFirstChild(tostring(prompt:GetAttribute("Target"))) -- The prompt names its mirror, so one handler serves every mirror
			local mirror = if target then mirrors[target :: BasePart] else nil

			if mirror then
				setMirrorStep(mirror, mirror.step + 1)
			end
		elseif action == "Shutter" then
			shutterClosed = not shutterClosed
			shutterTween = playTween(shutterTween, shutter, SHUTTER_TWEEN, if shutterClosed then blockedShutter else openShutter)
		end
	end
end

-- Every Optics child tagged as a mirror becomes a Mirror, so new mirrors only need the attributes in Studio
for _, part in optics:GetChildren() do
	if part:IsA("BasePart") and part:GetAttribute("OpticType") == "Mirror" then
		local initial = tonumber(part:GetAttribute("InitialStep")) or 0 -- tonumber returns nil for a missing attribute, so it falls back to step 0

		local mirror: Mirror = {
			part = part,
			origin = CFrame.new(part.Position), -- Position only, which drops the authored rotation, so the step alone decides the angle
			step = initial,
			initial = initial,
		}

		mirrors[part] = mirror
		setMirrorStep(mirror, initial)
	end
end

-- Each circuit type gets its source, its receiver and a full beam pool made once
for _, circuitType in CIRCUIT_TYPES do
	local circuit: Circuit = {
		source = emitters:WaitForChild(circuitType.name) :: BasePart,
		receiver = optics:WaitForChild(circuitType.name .. "Receiver") :: BasePart,
		color = circuitType.color,
		pool = {},
		used = 0,
		powered = false,
	}

	for index = 1, MAX_SEGMENTS do
		table.insert(circuit.pool, makeSegment(circuitType.color, index))
	end

	circuit.receiver.Color = DIM
	table.insert(circuits, circuit) -- This runs before the deferred first trace, so that trace already sees every circuit
end

for _, descendant in controls:GetDescendants() do
	if descendant:IsA("ProximityPrompt") then
		table.insert(prompts, descendant)
	end
end

-- The shutter is the only optic that moves by tween, mirrors call invalidate themselves in setMirrorStep
shutter:GetPropertyChangedSignal("CFrame"):Connect(invalidate)

ProximityPromptService.PromptTriggered:Connect(handlePrompt)

-- A player stepping into a closing doorway sends the door back up instead of closing on them
doorZone.Touched:Connect(function(hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model") -- Accessories put parts one level deeper, so the nearest Model is the character

	if not (character and Players:GetPlayerFromCharacter(character)) then
		return -- Only player characters can be trapped, other loose parts do not hold the door
	end

	doorwayParts[hit] = true

	if mode == "Resetting" and doorTarget == closedDoor then
		moveDoor(raisedDoor) -- Cancels the close tween, its Completed reports Cancelled, so collision stays off
	end
end)

-- Each part leaving the zone retries the close, and doorwayOccupied blocks it until the last part is out
doorZone.TouchEnded:Connect(function(hit: BasePart)
	doorwayParts[hit] = nil
	closeDoorWhenClear()
end)

Players.PlayerRemoving:Connect(function(player: Player)
	cooldowns[player] = nil -- Player objects are table keys, so leaving players are removed or the table keeps growing
end)

setMode("Routing") -- Applies the start state to the prompts and the console
