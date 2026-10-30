--[[
This module adapted from the DSC-Envisalink module authored by Todd Austin.

Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.

--]]


local log = require "log"
local utilities = require "utilities"
local capabilities = require "st.capabilities"
local capabilitydefs = require "capabilitydefs"

local socket = require "cosock.socket"
local evl = require "envisalinkdefs"
local events = require "evthandler"
local g = require "globals"

-- Module variables
local clientsock
local connected = false
local loggedin = false
local link_status = nil				-- nil (startup), 'up', 'down', 'login_failed'
local connect_failures = 0
local handlers={}

local evlClient = {}

evlClient.msghandler = {}			-- forward reference to msghandler function

-- Post a status message to partition devices (only partitions have statusMessage).
-- If partitionNumber is nil, all partitions get the message.
local function emit_partition_status(driver, message, partitionNumber)
	for _, dev in ipairs(driver:get_devices()) do
		local dev_partition = dev.device_network_id:match('^envisalink|p|(%d+)$')
		if dev_partition and ((partitionNumber == nil) or (tonumber(dev_partition) == tonumber(partitionNumber))) then
			dev:emit_event(capabilities[capabilitydefs.statusMessage.name].statusMessage({value = message}))
		end
	end
end

-- Only post a message when the link state actually changes, so retries don't spam the status
local function set_link_status(driver, status, message)
	if link_status ~= status then
		link_status = status
		emit_partition_status(driver, message)
	end
end

-- Connection dropped; keep a login failure message visible since it is the more useful one
local function report_link_lost(driver, reason)
	if link_status ~= 'login_failed' then
		set_link_status(driver, 'down', string.format('Lost connection to EnvisaLink (%s) - retrying', reason))
	end
end

function evlClient.report_login_failure(driver)
	set_link_status(driver, 'login_failed', 'EnvisaLink login not completed - retrying')
end

local function clear_send_queue()
	for i = #g.to_send_queue, 1, -1 do g.to_send_queue[i] = nil end
end

function evlClient.connect(driver)

	local listen_ip = "0.0.0.0"
	local listen_port = 0

	local client = assert(socket.tcp(), "create LAN socket")

	assert(client:bind(listen_ip, listen_port), "LAN socket setsockname")

	local ret, msg = client:connect(g.conf.ip, g.conf.port)
	
	if ret == nil then
		log.error (string.format('Could not connect to EnvisaLink: %s', msg))
		client:close()
		connect_failures = connect_failures + 1
		if (link_status == 'down') and (connect_failures % g.reconnectReportInterval == 0) then
			emit_partition_status(driver, string.format('Still unable to reach EnvisaLink (%d attempts, %s)', connect_failures, msg))
		else
			set_link_status(driver, 'down', string.format('EnvisaLink unreachable (%s) - retrying', msg))
		end
		return nil, msg
	else
		connect_failures = 0
		client:settimeout(0)
		connected = true
		clientsock = client
		driver:register_channel_handler(client, evlClient.msghandler, 'LAN client handler')
		return client
	end
end


-- Cancelling a timer that has already fired raises an error, so never let a cancel abort the caller
local function cancel_timer(driver, name)
	local t = g.timers[name]
	g.timers[name] = nil
	if t then
		pcall(driver.cancel_timer, driver, t)
	end
end

function evlClient.disconnect(driver)

	connected = false
	loggedin = false
	g.last_rx_time = nil
	
	cancel_timer(driver, 'reconnect')
	cancel_timer(driver, 'waitlogin')
	cancel_timer(driver, 'keepalive')
	cancel_timer(driver, 'throttle')
	socket.sleep(.1)
	-- Anything still queued was meant for the old connection; never replay it later
	clear_send_queue()

	if clientsock then
		pcall(driver.unregister_channel_handler, driver, clientsock)
		pcall(clientsock.close, clientsock)
		clientsock = nil
	end
	utilities.set_online(driver,'offline')

end

local doreconnect						-- Forward reference

-- This function invoked by delayed timer
local function dowaitlogin(driver)
	
	g.timers.waitlogin = nil
	if not loggedin then
		log.warn('Failed to log into Envisalink; connect retry in 15 seconds')
		evlClient.report_login_failure(driver)
		evlClient.disconnect(driver)
		evlClient.reconnect(driver)
	else
		utilities.set_online(driver,'online')
	end
end

-- This function invoked by delayed timer
doreconnect = function(driver)

	g.timers.reconnect = nil
	if connected then
		-- Another path (startup or settings change) already re-established the link
		log.debug ('Reconnect skipped - already connected to EnvisaLink')
		return
	end
	log.info ('Attempting to reconnect to EnvisaLink')
	local client = evlClient.connect(driver)
	
	if client then
	
		log.info ('Re-connected to Envisalink')
		
		g.timers.waitlogin = driver:call_with_delay(g.loginWaitSeconds, dowaitlogin, 'Wait for Login')
		
	else
		g.timers.reconnect = driver:call_with_delay(g.reconnectSeconds, doreconnect, 'Re-connect timer')
	end
end

local function throttle_loop(driver)
	-- This timer has fired; clear it first so no exit path (including an error) leaves a stale handle
	-- behind that makes throttle_send think a loop is still running
	g.timers.throttle = nil
	if not (connected and clientsock) then
		log.warn('THROTTLE: Not connected to EnvisaLink - discarding queued commands')
		clear_send_queue()
		return
	end
	if #g.to_send_queue > 0 then
		local to_send = table.remove(g.to_send_queue,1)
		for _,msg in ipairs(to_send) do
			log.trace('TX > ' .. msg)
			local bytes, err = clientsock:send(msg)
			if err then
				log.error(string.format('Send failed: %s - triggering reconnect', err))
				report_link_lost(driver, 'send failed: ' .. err)
				evlClient.disconnect(driver)
				evlClient.reconnect(driver)
				return
			end
		end
		g.throttle_scheduled_at = os.time()
		g.timers.throttle = driver:call_with_delay(g.throttleSeconds, throttle_loop, 'Throttle commands to panel')
	else
		log.trace('THROTTLE: No more commands to send')
	end
end

-------------------------------------------------------------------------------------------------
local function throttle_send(driver)
	if g.timers.throttle and ((os.time() - g.throttle_scheduled_at) > g.throttleStallSeconds) then
		-- Throttle loop should run every throttleSeconds; if it hasn't, it's dead. Restart it, but
		-- only with the newest command - replaying old arm/disarm commands would be dangerous.
		log.error(string.format('THROTTLE: Command queue stalled for %d seconds - resetting', os.time() - g.throttle_scheduled_at))
		pcall(driver.cancel_timer, driver, g.timers.throttle)
		g.timers.throttle = nil
		local newest = g.to_send_queue[#g.to_send_queue]
		clear_send_queue()
		table.insert(g.to_send_queue, newest)
		emit_partition_status(driver, 'Command queue was stalled - reset, older commands discarded')
	end
	if g.timers.throttle then
		log.trace ('THROTTLE: Message queued')
	else
		g.throttle_scheduled_at = os.time()
		g.timers.throttle = driver:call_with_delay(0, throttle_loop, 'Throttle commands to panel')
	end
end

-- Refuse to queue panel commands while not logged in, so they aren't silently lost
local function can_send(driver, partitionNumber)
	if loggedin then
		return true
	end
	log.warn(string.format('Not connected to EnvisaLink - command for partition %s not sent', partitionNumber))
	emit_partition_status(driver, 'No connection to panel - command not sent', partitionNumber)
	-- Safety net: if the link is down and nothing is going to bring it back, start reconnecting
	if not connected and not g.timers.reconnect then
		log.warn('No reconnect pending - scheduling reconnect to EnvisaLink')
		evlClient.reconnect(driver)
	end
	return false
end

local function send_command(driver,code,data)
-- Send a command in the proper honeywell format.
	local to_send = '^' .. code .. ',' .. data .. '$\n'
	log.trace ('TX > ' .. to_send)
	local send_array ={}
	table.insert(send_array,to_send)
	table.insert(g.to_send_queue,send_array)
	throttle_send(driver)
end

local function send_raw(driver,to_send)
-- Send keypress sequence to active partition
	if not can_send(driver, 1) then return false end
	to_send = to_send .. '\n'
	log.trace ('TX > ' .. to_send)
	local send_array ={}
	table.insert(send_array,to_send)
	table.insert(g.to_send_queue,send_array)
	throttle_send(driver)
	return true
end

local function dump_zone_timers(driver)
-- Send a command to dump out the zone timers.
	send_command(driver,evl.Commands.DumpZoneTimers, '')
end

local function keypresses_to_partition(driver,partitionNumber,keypresses)
-- Send keypresses to a particular partition.
	if not can_send(driver, partitionNumber) then return false end
	log.trace ('TX Keypresses > ^' .. evl.Commands.PartitionKeypress .. ',' .. partitionNumber .. ',' .. keypresses .. '$')
	local send_array = {}
	for char in keypresses:gmatch(".") do
		table.insert(send_array,'^' .. evl.Commands.PartitionKeypress .. ',' .. partitionNumber .. ',' .. char .. '$\n')
	end
	table.insert(g.to_send_queue,send_array)
	throttle_send(driver)
	return true
end

function evlClient.disarm_partition(driver,code,partitionNumber)
-- Disarm a partition
	local to_send = code .. evl.ArmCommands.disarm
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.arm_away_partition(driver,code,partitionNumber)
-- Arm away a partition
	local to_send = code .. evl.ArmCommands.armAway
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.arm_stay_partition(driver,code,partitionNumber)
-- Arm stay a partition
	local to_send = code .. evl.ArmCommands.armStay
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.arm_instant_partition(driver,code,partitionNumber)
-- Arm instant a partition
	local to_send = code .. evl.ArmCommands.armInstant
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end
	
function evlClient.arm_night_partition(driver,code,partitionNumber)
-- Arm night a partition
	local to_send = code .. evl.ArmCommands.armNight
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.arm_max_partition(driver,code,partitionNumber)
-- Arm max a partition
	local to_send = code .. evl.ArmCommands.armMax
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.chime_partition(driver,code,partitionNumber)
-- Toggle chime for a partition
	local to_send = code .. evl.ArmCommands.chime
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.bypass_zone_partition(driver,code,partitionNumber,zone)
-- Bypass a zone on a partition
	local zone_int = tonumber(zone)
	if zone_int then
		if (zone_int <= 128) and (zone_int > 0) then
			local zone_string = ''
			if zone_int < 10 then
				zone_string = '0'
			end
			zone_string = zone_string .. zone
			local to_send = code .. evl.ArmCommands.bypass .. zone_string
			if tonumber(partitionNumber) == 1 then
				return send_raw(driver,to_send)
			else
				return keypresses_to_partition(driver,partitionNumber,to_send)
			end
		end
	end
end

function evlClient.trigger_one_partition_on(driver,code,partitionNumber)
-- Turn trigger 1 on
	local to_send = code .. evl.ArmCommands.triggerOneOn
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.trigger_one_partition_off(driver,code,partitionNumber)
-- Turn trigger 1 off
	local to_send = code .. evl.ArmCommands.triggerOneOff
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.trigger_two_partition_on(driver,code,partitionNumber)
-- Turn trigger 1 on
	local to_send = code .. evl.ArmCommands.triggerTwoOn
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

function evlClient.trigger_two_partition_off(driver,code,partitionNumber)
-- Turn trigger 1 off
	local to_send = code .. evl.ArmCommands.triggerTwoOff
	if tonumber(partitionNumber) == 1 then
		return send_raw(driver,to_send)
	else
		return keypresses_to_partition(driver,partitionNumber,to_send)
	end
end

-- Login to Envisalink; once successful, send Refresh request
function handlers.handle_login(driver,sock)
	log.info ('Received login password request; sending password')
	local to_send = g.conf.password .. '\n'
	log.trace ('TX > ' .. to_send)
	local bytes, err = clientsock:send(to_send)
	if err then
		log.error(string.format('Login send failed: %s - triggering reconnect', err))
		report_link_lost(driver, 'login send failed: ' .. err)
		evlClient.disconnect(driver)
		evlClient.reconnect(driver)
	end
end		

local function keepalive_loop(driver)
	-- This timer has fired; clear it so disconnect() doesn't try to cancel it
	g.timers.keepalive = nil
	if connected and loggedin then
		if g.last_rx_time and (os.time() - g.last_rx_time) > g.noRxTimeout then
			log.warn(string.format('No data received for %d seconds - reconnecting', os.time() - g.last_rx_time))
			report_link_lost(driver, string.format('no data for %d seconds', os.time() - g.last_rx_time))
			evlClient.disconnect(driver)
			evlClient.reconnect(driver)
			return
		end
		log.trace('Sending keepalive poll to Envisalink')
		send_command(driver,evl.Commands.KeepAlive, '0')
	end
	g.timers.keepalive = driver:call_with_delay(g.keepaliveSeconds, keepalive_loop, 'Keepalive timer')
end

function handlers.handle_login_success(driver,sock)
	log.info('Successfully logged in to Envisalink...')
	loggedin = true
	g.last_rx_time = os.time()
	connect_failures = 0
	set_link_status(driver, 'up', 'Connected to EnvisaLink')
	-- Set Partition 1 as active
	send_command(driver,evl.Commands.ChangeDefaultPartition, '1')
	-- Start keepalive polling
	cancel_timer(driver, 'keepalive')
	g.timers.keepalive = driver:call_with_delay(g.keepaliveSeconds, keepalive_loop, 'Keepalive timer')
end

function handlers.handle_login_failure(driver,sock)
	log.error ('Envisalink login failed - incorrect password')
	set_link_status(driver, 'login_failed', 'EnvisaLink rejected password - check settings')
end

function handlers.handle_login_timeout(driver,sock)
	log.error ('Envisalink login failed - timeout')
	set_link_status(driver, 'login_failed', 'EnvisaLink login timed out - retrying')
end

local function get_partition_state(flags, alpha)
	if flags.alarm or flags.alarm_fire_zone or flags.fire then
		return 'alarm'
	elseif flags.alarm_in_memory then
		return 'alarmcleared'
    elseif alpha:find('You may exit now') then
		return 'arming'
	elseif alpha:find('May Exit Now') then
		return 'arming'
    elseif flags.armed_stay and flags.armed_zero_entry_delay then
		return 'armedinstant'
    elseif flags.armed_away and flags.armed_zero_entry_delay then
		return 'armedmax'
    elseif flags.armed_stay then
		return 'armedstay'
    elseif flags.armed_away then
		return 'armedaway'
    elseif flags.ready then
		return 'ready'
    elseif not flags.ready then
		return 'notready'
	else
		return 'unknown'
	end
end

local function get_zone_report_type(flags,alpha)
	if flags.alarm or flags.alarm_fire_zone or flags.fire then
		return 'alarm'
	elseif flags.alarm_in_memory then
		return 'alarmcleared'
	elseif flags.system_trouble then
		return 'tamper'
	elseif flags.low_battery then
		return 'battery'
	elseif flags.bypass and alpha:find('BYPAS') then
		return 'bypass'
	elseif not flags.ready then
		return 'notready'
	else
		return 'unknown'
	end
end

local function parse_led_bitfield(led_bitfield)
	local flags = {}
	for key, value in pairs(evl.LED_Flags) do
		flags[key] = (value & led_bitfield) ~= 0
	end
	return flags
end

function handlers.handle_keypad_update(driver,sock,data)
	if #data >= 6 then
		local partition = tonumber(data[2],16)
		local led_bitfield = tonumber(data[3],16)
		local zone_user = tonumber(data[4],10)
		local beep = tonumber(data[5],16)
		local alpha = ''
		for i=6,#data,1 do
			alpha = alpha .. (#alpha > 0 and ',' or '') .. (data[i] or '')
		end
		local flags = parse_led_bitfield(led_bitfield)
		local partition_status = get_partition_state(flags, alpha)
		local open_timer_count = 0
		for _ in pairs(g.zone_timers[partition]) do open_timer_count = open_timer_count + 1 end
		local new_msg = data[1] .. ',' .. data [2] .. ',' .. data [3] .. ',' .. data [4] .. ',' .. data [5] .. ',' .. data [6]
		if (new_msg ~= g.last_event[partition]) or (open_timer_count > 1) then
			g.last_event[partition] = new_msg
			local partition_code = flags.not_used2 and flags.not_used3
			local partition_response = {
				type 		= 'partition',
				partition 	= partition,
				alpha 		= alpha,
				state 		= partition_status,
				chime 		= flags.chime and 'chime' or 'off',
				power 		= flags.ac_present and 'mains' or 'battery',
				bypass 		= flags.bypass and 'bypassed' or (flags.ready and 'closed' or 'open')
			}
			local zone_code = get_zone_report_type(flags,alpha)
			local arming_countdown = (partition_status == 'arming') and (zone_code == 'notready')
			if partition_code then
				-- Keypad update is giving partition status
				partition_response.battery = flags.low_battery and 0 or 100
			elseif arming_countdown then
				-- Keypad is counting down. Take no action on zone report
			elseif tonumber(zone_user) then
				-- Keypad update is giving zone status
				local zone_response = {
					type 		= 'zone',
					partition 	= partition,
					zone 		= zone_user
				}
				local timer_type
				if zone_code == 'battery' then
					zone_response.battery = 0
					timer_type = 'battery'
				elseif zone_code == 'tamper' then
					zone_response.tamper = 'detected'
					timer_type = 'tamper'
				elseif zone_code == 'bypass' then
					zone_response.state = 'bypassed'
					-- Zones stay bypassed until the entire partition is disarmed, so zone timers won't help here
					timer_type = nil
				elseif (zone_code == 'alarm') or (zone_code == 'alarmcleared') or (zone_code == 'notready') then
					zone_response.state = flags.ready and 'closed' or 'open'
					timer_type = 'state'
				end
				events.stnp_notification_handler(driver,zone_response)
				if timer_type then
					-- Increment zone timers. This is a workaround since the Vista doesn't notify on zone closure
					local timer_count = 0
						for _, the_timer in pairs(g.zone_timers[partition]) do
						g.zone_timers[partition][_] = the_timer + 1
						timer_count = timer_count + 1
					end
					utilities.disptable(g.zone_timers[partition], '  ')
					if g.zone_timers[partition][zone_user .. '|' .. timer_type] then
						log.debug (string.format('Zone timer for %s reset from %s to 0',zone_user,g.zone_timers[partition][zone_user .. '|' .. timer_type]))
					end
					g.zone_timers[partition][zone_user .. '|' .. timer_type] = 0
					
					local kill_timers = {}
					for zone_type, the_timer in pairs(g.zone_timers[partition]) do
						-- If zone is more than 2 overdue in showing on panel, assume it has closed
						if the_timer >= timer_count + g.conf.zoneclosedelay then
							local the_zone = zone_type:match('(%d+)|.+')
							local the_type = zone_type:match('%d+|(.+)')
							local the_zone_response = {
								type 		= 'zone',
								partition	= partition,
								zone 		= the_zone
							}
							if the_type == 'state' then
								the_zone_response.state = 'closed'
							elseif the_type == 'battery' then
								the_zone_response.battery = 100
							elseif the_type == 'tamper' then
								the_zone_response.tamper = 'clear'
							end
							events.stnp_notification_handler(driver,the_zone_response)
							table.insert(kill_timers,zone_type)
						end
					end
					-- Kill any timers for zones that are being closed
					for _,zone_type in pairs(kill_timers) do
						log.debug (string.format('Removing %s from zone_timers', zone_type))
						g.zone_timers[partition][zone_type] = nil
					end
				end
			end
			events.stnp_notification_handler(driver,partition_response)
		end
	else
		log.error('Error - Keypad Update event has incorrect length!')
	end
end

function handlers.handle_zone_state_change(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

function handlers.handle_partition_state_change(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

function handlers.handle_realtime_cid_event(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

function handlers.handle_zone_timer_dump(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

function handlers.handle_poll_response(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

function handlers.handle_command_response(driver,sock,data)
	log.info (string.format('%s event received. Data: %s',evl.ResponseTypes[data[1]].name, data[2]))
end

local function handle_line(driver, sock, input)
	if input then
		if evl.ResponseTypes[input] then
			handlers[evl.ResponseTypes[input].handler](driver,sock)
		else
			local data = input:match('(%%.+)%$') or input:match('(%^.+)%$')
			if data then
				local responseTable = utilities.splitString(data,',')
				handlers[evl.ResponseTypes[responseTable[1]].handler](driver,sock,responseTable)
			else
				log.error ('Unknown response received')
			end
		end
	end
end

function evlClient.reconnect(driver)
	cancel_timer(driver, 'reconnect')
	g.timers.reconnect = driver:call_with_delay(g.reconnectSeconds, doreconnect, 'Re-connect timer')

end

------------------------------------------------------------------------
--							Channel Handler
------------------------------------------------------------------------

evlClient.msghandler = function(driver, sock)
    local recvbuf
    local recverr

	if sock ~= clientsock then
		-- Leftover socket from an earlier connection; drop it without touching the current link
		log.warn ('Closing stale EnvisaLink socket')
		pcall(driver.unregister_channel_handler, driver, sock)
		pcall(sock.close, sock)
		return
	end
	recvbuf, recverr = sock:receive('*l')
	
	if recverr ~= nil then
		log.debug (string.format('Receive status = %s', recverr))
	end
	
	if (recverr ~= 'timeout') and recvbuf then
		g.last_rx_time = os.time()
		log.trace (string.format('RX < %s', recvbuf))

		handle_line(driver, sock, recvbuf)
	
	elseif (recverr ~= 'timeout') and (recverr ~= nil) then
		log.error (string.format('Socket Receive Error occured: %s', recverr))
		
		if recverr == 'closed' then
			log.warn ('Envisalink has disconnected')
			report_link_lost(driver, 'closed by EnvisaLink')
			evlClient.disconnect(driver)
			evlClient.reconnect(driver)
		
		end
	end	
end

function evlClient.is_loggedin(driver)

	return loggedin

end

function evlClient.is_connected(driver)

	return connected

end

return evlClient

