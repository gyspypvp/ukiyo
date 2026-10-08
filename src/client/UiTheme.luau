--!strict
--[[
	UiTheme (ModuleScript, StarterPlayerScripts/Client)
	===================================================
	One visual language for every piece of Clash Kick UI, built in code so the
	place needs no UI assets:

	  * dark, slightly translucent "glass" panels with a hairline light edge
	  * round action buttons, each with its own accent colour
	  * one clean sans-serif family (Gotham) in three weights; no outlined
	    cartoon lettering

	Change a colour or font here and every screen element follows.
]]

local UiTheme = {}

UiTheme.Font = Enum.Font.GothamBold -- labels, buttons
UiTheme.FontHeavy = Enum.Font.GothamBlack -- banners, big numbers
UiTheme.FontBody = Enum.Font.GothamMedium -- sentences

UiTheme.Colors = table.freeze({
	Panel = Color3.fromRGB(16, 18, 24),
	Edge = Color3.fromRGB(255, 255, 255),
	Text = Color3.fromRGB(245, 247, 250),
	SubText = Color3.fromRGB(165, 173, 188),
	Danger = Color3.fromRGB(255, 72, 88), -- incoming kicks, strikes, hits on you
	-- One accent per action, reused by its button, its cooldown and its world effects.
	Kick = Color3.fromRGB(255, 138, 61),
	Block = Color3.fromRGB(77, 168, 255),
	Dash = Color3.fromRGB(64, 224, 168),
	Skill = Color3.fromRGB(168, 122, 255),
	UltA = Color3.fromRGB(255, 196, 61), -- the ULTIMATE gradient runs UltA -> UltB
	UltB = Color3.fromRGB(255, 61, 140),
})

UiTheme.PanelTransparency = 0.22
UiTheme.EdgeTransparency = 0.82

function UiTheme.corner(parent: GuiObject, radius: UDim?): UICorner
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = radius or UDim.new(0, 10)
	uiCorner.Parent = parent
	return uiCorner
end

function UiTheme.stroke(parent: GuiObject, thickness: number, color: Color3, transparency: number?): UIStroke
	local uiStroke = Instance.new("UIStroke")
	uiStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	uiStroke.Thickness = thickness
	uiStroke.Color = color
	uiStroke.Transparency = transparency or 0
	uiStroke.Parent = parent
	return uiStroke
end

-- A glass panel: dark, translucent, rounded, with a faint light edge.
function UiTheme.panel(parent: Instance, name: string, radius: UDim?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = UiTheme.Colors.Panel
	frame.BackgroundTransparency = UiTheme.PanelTransparency
	frame.BorderSizePixel = 0
	frame.Parent = parent
	UiTheme.corner(frame, radius)
	UiTheme.stroke(frame, 1, UiTheme.Colors.Edge, UiTheme.EdgeTransparency)
	return frame
end

--[[
	A text label. `textSize` given: fixed size (wrapping off unless asked).
	Omitted: scales to fit its box. Centred by default.
]]
function UiTheme.text(parent: Instance, font: Enum.Font, color: Color3, textSize: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextColor3 = color
	label.Text = ""
	if textSize then
		label.TextScaled = false
		label.TextSize = textSize
	else
		label.TextScaled = true
	end
	label.Parent = parent
	return label
end

--[[
	Show `fraction` (0..1) of a frame through its UIGradient's transparency,
	with a hard edge: the gradient's start (Rotation decides where that is)
	stays visible up to `fraction`, the rest is hidden. Used for cooldown
	shades and the ULTIMATE charge fill. A frame with UICorner stays round.
]]
function UiTheme.setFill(gradient: UIGradient, fraction: number)
	local f = math.clamp(fraction, 0, 1)
	if f <= 0.001 then
		gradient.Transparency = NumberSequence.new(1)
	elseif f >= 0.999 then
		gradient.Transparency = NumberSequence.new(0)
	else
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(f, 0),
			NumberSequenceKeypoint.new(math.min(f + 0.001, 0.999), 1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
end

return table.freeze(UiTheme)
