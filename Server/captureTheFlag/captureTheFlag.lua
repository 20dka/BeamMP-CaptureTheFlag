
--	capture the flag minigame server plugin by deer boi
--	
--	set flag position with /setflag (uses current vehicle pos)
--	start with /startctf
--	
--	meow :3

pluginPath = debug.getinfo(1).source:gsub("\\","/")
pluginPath = pluginPath:sub(2,(pluginPath:find("captureTheFlag.lua"))-2)

package.path = package.path .. ";;" .. pluginPath .. "/?.lua;;".. pluginPath .. "/lua/?.lua"

local json = require("json")

--server config
local countdownCounter = 5
local resetPenalty = 100
local winPoints = 1800

--client config
local config = {
	toggleNametags = true,

	dropDamageTresh = 10000,
	flagRadius = 1.2,
	flagSpawn = nil,

	inactiveColor = {r=0.3, g=0.3, b=0.3},
	activeColor = {r=1, g=1, b=0},
	wonColor = {r=0, g=1, b=0},

	pickupTimes = { localResetCar = 10, remoteResetCar = 5, remoteTookFlag = 3, localDroppedFlag = 5, remoteDroppedFlag = 0, gameStart = 5 }
}



-- internal variables
local points = {}
local flagCarrierID = nil
local flagCarrierName = nil


------------------------------------------EVENTS-----------------------------------------------------------

function onInit()
	--RegisterEvent("onPlayerJoin","onPlayerJoin")
	--RegisterEvent("onPlayerConnecting","onPlayerConnecting")
	--RegisterEvent("onPlayerJoining","onPlayerJoining")
	--RegisterEvent("onVehicleEdited","onVehicleEdited")
	MP.RegisterEvent("onChatMessage","onChatMessage")
	--RegisterEvent("onVehicleDeleted","onVehicleDeleted")
	MP.RegisterEvent("onPlayerDisconnect","onPlayerDisconnect")

	MP.RegisterEvent("CtFsetFlagSpawnTo","setFlagSpawnTo")
	MP.RegisterEvent("CtFflagExchanged","flagExchanged")
	MP.RegisterEvent("CtFflagPickedUp","flagPickedUp")
	MP.RegisterEvent("CtFflagDropped","flagDropped")
	MP.RegisterEvent("CtFremovePoints","removePoints")


clog("--------------CaptureTheFlag Ready--------------", true)
end


function setFlagSpawnTo(playerID, data)
	data = string.gsub(data, ";", ":")
	data = json.decode(data)

	clog("Set the flag spawnpoint to x:"..tostring(data.x).." y:"..tostring(data.y).." z:"..tostring(data.z))
	MP.SendChatMessage(playerID, "Successfully set flag spawnpoint")

	sendConfig({flagSpawn = data})
end

function flagExchanged(playerID, data)
	-- clog(printNameWithID(playerID).." in vehicle "..data.." took the flag from "..(flagCarrierID and printNameWithID(flagCarrierID) or 'NOBODY'))
	clog(printNameWithID(playerID).." in vehicle "..data.." took the flag from "..(flagCarrierID and printNameWithID(flagCarrierID) or 'NOBODY'))

	flagCarrierID = playerID
	flagCarrierName = MP.GetPlayerName(flagCarrierID)

	MP.TriggerClientEvent(-1, "CtFremoteExchangedFlag", data)
end
function flagPickedUp(playerID, data)
	clog(printNameWithID(playerID).." in vehicle "..data.." picked up the flag")
	if flagCarrierID then clog("Carrier was not nil! "..printNameWithID(flagCarrierID)) end

	flagCarrierID = playerID
	flagCarrierName = MP.GetPlayerName(playerID)
	MP.TriggerClientEvent(-1, "CtFremotePickedUpFlag", data)
end
function flagDropped(playerID, data)
	flagCarrierID = nil
	flagCarrierName = nil
	clog(printNameWithID(playerID).." in vehicle "..data.." dropped the flag")
	MP.TriggerClientEvent(-1, "CtFremoteDroppedFlag", data)
end
function removePoints(playerID, data)
	local playerName = MP.GetPlayerName(playerID)
	clog(printNameWithID(playerID).." in vehicle "..data.." received a penalty of "..tostring(resetPenalty).." points")
	points[playerName] = points[playerName] - resetPenalty
	if points[playerName] < 0 then points[playerName] = 0 end
end

function updateScoreboard()
	if flagCarrierID then
		points[flagCarrierName] = points[flagCarrierName] + 1
		if points[flagCarrierName] == winPoints then
			gameWon(flagCarrierName)
			MP.CancelEventTimer("updateScoreboard")
		end
	end
	local scorestr = json.encode(points)
	--print(scorestr)
	for k,v in pairs(MP.GetPlayers() or {}) do
		MP.TriggerClientEvent(k, "CtFreceiveScoreboard", scorestr)
	end
end

function sendConfig(newcfg)
	newcfg = newcfg or {}
	config.toggleNametags = newcfg.toggleNametags or config.toggleNametags

	config.dropDamageTresh = newcfg.dropDamageTresh or config.dropDamageTresh
	config.flagRadius = newcfg.flagRadius or config.flagRadius
	config.flagSpawnPoint = newcfg.flagSpawn or config.flagSpawnPoint

	config.inactiveColor = newcfg.inactiveColor or config.inactiveColor
	config.activeColor = newcfg.activeColor or config.activeColor
	config.wonColor = newcfg.wonColor or config.wonColor

	config.pickupTimes = newcfg.pickupTimes or config.pickupTimes

	local cfg = json.encode(config):gsub(':',';')

	MP.TriggerClientEvent(-1, "CtFsetConfig", cfg)
end


function gameWon(winner)
	clog("player "..winner.." won CtF", true)
	MP.TriggerClientEvent(-1, "CtFplayerWon", winner)
	flagCarrierID = nil
	flagCarrierName = nil
end

function doCountdown()
	if countdownCounter <= 0 then return end
	MP.SendChatMessage(-1, tostring(countdownCounter))
	countdownCounter = countdownCounter - 1
	if countdownCounter == 0 then
		MP.SendChatMessage(-1, "Go!")								--send chat
		points = {}
		for k, v in pairs(MP.GetPlayers()) do points[v] = 0 end	--clear scores
		clog("Cleared scores, starting game")
		--StopThread("doCountdown")								--stop this funkyness
		MP.RegisterEvent("updateScoreboardEvent", "updateScoreboard")
		MP.CreateEventTimer("updateScoreboardEvent", 30)					--start scorekeeping timer
	end
end

function startCountdown()
	MP.SendChatMessage(-1, "CtF starting in...")
	countdownCounter = 5
	flagCarrierID = nil
	flagCarrierName = nil
	MP.RegisterEvent("countdownEvent", "doCountdown")
	MP.CreateEventTimer("countdownEvent", 30)

	MP.TriggerClientEvent(-1, "CtFrestartGame", tostring(countdownCounter))
	sendConfig()
end

function onChatMessage(playerID, name ,chatMessage)
	chatMessage = chatMessage:sub(1)
	clog(name.." said: "..chatMessage, true)

	if chatMessage:find("/startctf") then
		clog("player "..name.." started CtF", true)
		startCountdown()
		return 1
	elseif starts_with(chatMessage, "/help") then
		MP.SendChatMessage(playerID, "/startctf				[CTF] Start a ctf round")
		MP.SendChatMessage(playerID, "/setwin [winPoint]	[CTF] Set the number of point needed to win (default: "..winPoints..")")
		MP.SendChatMessage(playerID, "/setdmg [dmg]			[CTF] Set the damage treshold to drop the flag (default: "..config.dropDamageTresh..")")
		MP.SendChatMessage(playerID, "/setflag 				[CTF] Set the flag spawnpoint")
		MP.SendChatMessage(playerID, "/hidescoreboard 		[CTF] Hide the scoreboard")
		return 1
	elseif chatMessage:find("/hidescoreboard") then
		MP.TriggerClientEvent(-1, "CtFhideUI", "")
	elseif starts_with(chatMessage, "/setwin ") then
		winPoints = tonumber(chatMessage:sub(#"/setwin "))
		clog("player "..name.." set the win treshold to "..winPoints, true)
		return 1
	elseif starts_with(chatMessage, "/setdmg ") then
		dropTreshold = tonumber((chatMessage:sub(#"/setdmg ")))
		clog("player "..name.." set the damage treshold to "..dropTreshold, true)
		sendConfig({ dropDamageTresh = dropTreshold })
		return 1
	elseif starts_with(chatMessage, "/setflag") then
		clog("player "..name.." wants to set the flag spawnpoint, requesting from client", true)
		MP.TriggerClientEvent(playerID, "CtFflagSpawnRequest", "")
		return 1
	end
end

function onPlayerDisconnect(playerID)
	if flagCarrierID ~= playerID then return end

	clog(printNameWithID(playerID).." disconnected while carrying the flag, dropping it")
	MP.TriggerClientEventForAllExcept(playerID, "CtFremoteDroppedFlag", playerID)
end
function onVehicleSpawn(playerID, vehicleID, vehicleData)
	clog("Vehicle Spawned "..playerID.." "..vehicleID, true)
end
function onVehicleEdited(playerID, vehicleID, vehicleData)
	clog("Vehicle Edited "..playerID.." "..vehicleID, true)
end
function onVehicleDeleted(playerID, vehicleID)
	if flagCarrierID ~= playerID then return end

	clog(printNameWithID(playerID).." deleted a vehicle while carrying the flag, dropping it")
	MP.TriggerClientEventForAllExcept(playerID, "CtFremoteDroppedFlag", vehicleID)
end


function MP.TriggerClientEventForAllExcept(excludeID, eventName, eventData)
	for k,v in pairs(MP.GetPlayers()) do
		if k ~= excludeID then
			MP.TriggerClientEvent(k, eventName, eventData)
		end
	end
end

function tableToString(t, oneLine)
	oneLine = oneLine or true
	local str = ""

	for k,v in pairs(t) do
		str = str.." "..k.." : ".. (type(v) == "table" and tableToString(v) or v)
		if not oneLine then
			str = str.."\n"
		end
	end
	return str
end
function clog(text)
	if text == nil then
		return
	end

	if type(text) == "table" then
		text = tableToString(text)
	end

	print(" [captureTheFlag] "..text)

	if false then
		file = io.open("log.txt", "a")
		file:write(os.date("[%d/%m/%Y %H:%M:%S] ")..text.."\n")
		file:close()
	end
end

function simpletraceback(level)
	local debuginfo = debug.getinfo(level+1) -- account for this function call
    print("function was called from: " .. debuginfo.short_src:gsub('\\','/'):gsub(pluginPath, "") .. ":" .. debuginfo.currentline .. " inside " .. tostring(debuginfo.name) .. "()")
end

function printNameWithID(playerID)
	if not playerID then
		simpletraceback(2)
		simpletraceback(3)
	end
	return (MP.GetPlayerName(playerID) or '?').."("..playerID..")" 
end
function starts_with(str, start)
   return str:sub(1, #start) == start
end


--onInit()
