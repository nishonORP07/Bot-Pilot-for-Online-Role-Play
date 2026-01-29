local ffi = require("ffi")
local vector3d = require("vector3d")
local samp = require("samp.events")
local sampapi = require("sampapi")

local sampfuncs = require("sampfuncs")
local raknet = require("samp.raknet")
require("samp.synchronization")

local SCNetGame = sampapi.require("CNetGame", true)

ffi.cdef "typedef struct vector3d { float x, y, z; } vector3d;"
ffi.metatype("vector3d", { __index = vector3d })

local samp_sync_t = (function()
	local this = {}

	local sync_traits = {
		player     = { type = "struct PlayerSyncData",     id = raknet.PACKET.PLAYER_SYNC,     store = sampStorePlayerOnfootData },
		vehicle    = { type = "struct VehicleSyncData",    id = raknet.PACKET.VEHICLE_SYNC,    store = sampStorePlayerIncarData },
		passenger  = { type = "struct PassengerSyncData",  id = raknet.PACKET.PASSENGER_SYNC,  store = sampStorePlayerPassengerData },
		aim        = { type = "struct AimSyncData",        id = raknet.PACKET.AIM_SYNC,        store = sampStorePlayerAimData },
		trailer    = { type = "struct TrailerSyncData",    id = raknet.PACKET.TRAILER_SYNC,    store = sampStorePlayerTrailerData },
		unoccupied = { type = "struct UnoccupiedSyncData", id = raknet.PACKET.UNOCCUPIED_SYNC, store = nil },
		bullet     = { type = "struct BulletSyncData",     id = raknet.PACKET.BULLET_SYNC,     store = nil },
		spectator  = { type = "struct SpectatorSyncData",  id = raknet.PACKET.SPECTATOR_SYNC,  store = nil }
	}

	local function constructor(_, sync_type, copy_from_player)
		local t = sync_traits[sync_type]
		local data = ffi.new(t.type, {})
		local dstb = ffi.cast("uintptr_t", ffi.new(t.type .. "*", data))

		if copy_from_player and t.store then
			local id = tonumber(copy_from_player)
			if not id then
				id = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
			end
			t.store(id, tonumber(dstb))
		end

		return setmetatable({
			id = t.id,
			data = data,
			dstb = dstb
		}, { __index = this })
	end

	function this:send()
		local bs = raknetNewBitStream()
		raknetBitStreamWriteInt8(bs, self.id)
		raknetBitStreamWriteBuffer(bs, tonumber(self.dstb), ffi.sizeof(self.data))
		raknetSendBitStreamEx(bs, sampfuncs.HIGH_PRIORITY, sampfuncs.UNRELIABLE_SEQUENCED, 1)
		raknetDeleteBitStream(bs)
	end

	return setmetatable(this, { __call = constructor })
end)()

local coordm_t = (function()
	local this = {}

	local function constructor(_, step, to)
		to = vector3d(to.x, to.y, to.z)
		return setmetatable({ step = step, to = to }, { __index = this })
	end

	function this:next()
		if not isCharSittingInAnyCar(playerPed) then
			return false
		end

		local vehicle = storeCarCharIsInNoSave(playerPed)

		if not self.pos then
			local x, y, z = getCarCoordinates(vehicle)
			self.pos = vector3d(x, y, z)
		end

		local pos = self.pos

		if (self.to - pos):length() < self.step then
			setCarCoordinates(vehicle, self.to.x, self.to.y, self.to.z - 1)
			return false
		else
			local o = self.to - pos
			local f, t = getVectorAngles(o)

			local x = pos.x + self.step * math.sin(t - math.pi / 2) * math.cos(f)
			local y = pos.y + self.step * math.sin(t - math.pi / 2) * math.sin(f)
			local z = pos.z + self.step * math.cos(t - math.pi / 2)

			setCarCoordinates(vehicle, x, y, z)

			local sync = samp_sync_t("vehicle", true)

			sync.data.vehicleId = SCNetGame.RefNetGame():GetPlayerPool():GetLocalPlayer().m_nCurrentVehicle
			sync.data.position.x = x
			sync.data.position.y = y
			sync.data.position.z = z

			o:normalize()

			sync.data.moveSpeed.x = o.x > 0 and 0.1 or -0.1
			sync.data.moveSpeed.y = o.y > 0 and 0.1 or -0.1
			sync.data.moveSpeed.z = o.z > 0 and 0.1 or -0.1

			self.pos.x, self.pos.y, self.pos.z = sync.data.position.x, sync.data.position.y, sync.data.position.z

			sync:send()

			return true
		end
	end

	return setmetatable(this, { __call = constructor })
end)()

function main()
	while not isSampAvailable() do wait(0) end

	local step = 10
	local sleep = 0.25
	local any_point

	sampRegisterChatCommand("pbot", function()
		status = not status
	end)

	function samp.onSendVehicleSync()
		if status and any_point then
			return false
		end
	end

	function samp.onShowDialog(id, style, title, yes, no, text)
		if title == "{FFCD00}Вы завершили рейс!" then
			sampSendDialogResponse(id, 1, 0, "1. Продолжить работу")
			return false
		end
	end

	while true do
		if status then
			local pos = search_map_marker(true, getCharCoordinates(PLAYER_PED))
			if pos then
				local t = coordm_t(step, pos)
				any_point = t
				if isCharSittingInAnyCar(PLAYER_PED) then
					local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
					setCarCollision(vehicle, false)
				end
				while status and t:next() do
					local clock = os.clock()
					while os.clock() - clock < sleep do
						printStringNow("~y~wait...", 150)
						if isCharSittingInAnyCar(PLAYER_PED) then
							local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
							setCarCoordinates(vehicle, t.pos.x, t.pos.y, t.pos.z)
						end
						wait(0)
					end
				end
				any_point = false
				if isCharSittingInAnyCar(PLAYER_PED) then
					local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
					setCarCollision(vehicle, true)
				end
			end
		end
		wait(0)
	end
end

function search_map_marker(is_race, x, y, z)
	local ptr = is_race and 0xC7F168 or 0xC7DD88
	local step = is_race and 56 or 160
	local base = vector3d(x, y, z)
	local result = { distance = math.huge }
	for id = 0, 31 do
		local pos = ffi.cast("vector3d*", ptr + id * step)
		if pos.x ~= 0 and pos.y ~= 0 and pos.z ~= 0 then
			local distance = (base - pos):length()
			if distance < result.distance then
				result.distance = distance
				result.vector = pos
			end
		end
	end
	return result.vector
end

function getVectorAngles(v)
	local f = math.atan2(v.y, v.x)
	local t = math.acos(v.z / v:length())
	return f + (f > 0 and -1 or 1) * math.pi, math.pi / 2 - t
end