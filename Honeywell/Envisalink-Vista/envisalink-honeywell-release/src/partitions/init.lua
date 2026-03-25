-- Author: philh30
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require('st.capabilities')
local log = require('log')
local commands = require('commands')
local capdefs = require('capabilitydefs')
local events = require "evthandler"
local g = require('globals')
local utilities = require('utilities')

local models_supported = {
  'Honeywell Primary Partition',
  'Honeywell Partition',
}

local function can_handle_partitions(opts, driver, device, ...)
  for _, model in ipairs(models_supported) do
    if device.model == model then
      return true
    end
  end
  return false
end

---------------------------------------
-- Added Lifecycle Handler
local function added_handler(driver, device)
  log.info(device.id .. ": " .. device.device_network_id .. " > ADDED PARTITION")
  device:emit_event(capabilities[capdefs.statusMessage.name].statusMessage({value = 'No Connection to Panel'}))
  device:emit_event(capabilities.securitySystem.securitySystemStatus.disarmed())
  device:emit_event(capabilities.securitySystem.alarm({value = 'Initialized'}))
  device:emit_event(capabilities[capdefs.alarmMode.name].alarmMode({value = 'Not Ready'}))
  device:emit_event(capabilities[capdefs.alarmMode.name].supportedAlarmModes({value = {'disarm','armAway','armStay'}}))
  device:emit_event(capabilities.chime.chime.off())
  device:emit_event(capabilities.bypassable.bypassStatus.ready())
  device:emit_event(capabilities.powerSource.powerSource.mains())
  device:emit_event(capabilities.battery.battery({value = 100}))
  device:online()
end

----------------------------------
-- Info Changed Lifecycle Handler
local function infoChanged_handler(driver,device, event, args)
  log.info(device.id .. ": " .. device.device_network_id .. " > INFO CHANGED PARTITION")
  local partition_num = device.device_network_id:match('envisalink|p|(%d+)')
  if device.preferences.addSwitches then
    local device_list = driver:get_devices()
    local found = {
      ['disarm']      = false,
      ['armAway']     = false,
      ['armStay']     = false,
      ['armInstant']  = false,
      ['armMax']      = false,
      ['armNight']    = false,
      ['chime']       = false,
    }
    for _, dev in ipairs(device_list) do
      local dev_id = dev.device_network_id:match('envisalink|s|(.+)|' .. partition_num)
      if dev_id then found[dev_id] = true end
    end
    if device.preferences.addSwitches then
      if not found['disarm'] then events.createDevice(driver,'switch','Switch','disarm|' .. partition_num,nil) end
      if not found['armAway'] then events.createDevice(driver,'switch','Switch','armAway|' .. partition_num,nil) end
      if not found['armStay'] then events.createDevice(driver,'switch','Switch','armStay|' .. partition_num,nil) end
      if (not found['armInstant']) and device.preferences.armInstantSupported then events.createDevice(driver,'switch','Switch','armInstant|' .. partition_num,nil) end
      if (not found['armMax']) and device.preferences.armMaxSupported then events.createDevice(driver,'switch','Switch','armMax|' .. partition_num,nil) end
      if (not found['armNight']) and device.preferences.armNightSupported then events.createDevice(driver,'switch','Switch','armNight|' .. partition_num,nil) end
    end
  end
  local supported_modes = {'disarm','armAway','armStay'}
  if device.preferences.armInstantSupported then
    table.insert(supported_modes,'armInstant')
  end
  if device.preferences.armMaxSupported then
    table.insert(supported_modes,'armMax')
  end
  if device.preferences.armNightSupported then
    table.insert(supported_modes,'armNight')
  end
  device:emit_event(capabilities[capdefs.alarmMode.name].supportedAlarmModes({value = supported_modes}))
end

----------------------------
-- Refresh command
local function refresh_handler(driver, device, command)
  log.info(device.id .. ": " .. device.device_network_id .. " > REFRESH")
  commands.refresh_partition(driver,device)
end

----------------
-- States that allow direct mode change (disarm + re-arm)

local function send_partition_command(driver,device,partition,command)
  if tonumber(partition) ~= 1 and tonumber(partition) ~= 2 then
    log.error (string.format('Could not determine partition number for %s',device.device_network_id))
    return
  end
  local current_state = device.state_cache.main[capdefs.alarmMode.name].alarmMode.value
  if command ~= 'disarm' and g.direct_change_states[current_state] then
    local already_active = utilities.is_already_active(device, command, capdefs)
    if already_active then
      log.info(string.format('Already in %s - skipping command %s', current_state, command))
      local evt = capabilities[capdefs.alarmMode.name].alarmMode({value = current_state}, {visibility = {displayed = false}})
      evt.state_change = true
      device:emit_event(evt)
      return
    end
    if device.preferences.directModeChange then
      local delay = g.modeChangeDelay
      log.info(string.format('Direct mode change: %s -> %s (disarming first, %ds delay)', current_state, command, delay))
      commands.send_evl_command(driver, { ['partition'] = partition, ['command'] = 'disarm' })
      commands.send_evl_command_delayed(driver, { ['partition'] = partition, ['command'] = command }, delay)
      return
    end
    log.info(string.format('Panel is %s and direct mode change disabled - rejecting %s', current_state, command))
    local evt = capabilities[capdefs.alarmMode.name].alarmMode({value = current_state}, {visibility = {displayed = false}})
    evt.state_change = true
    device:emit_event(evt)
    return
  end
  commands.send_evl_command(driver, { ['partition'] = partition, ['command'] = command })
end

----------------
-- Send partition command
local function handle_partition_command(driver,device,cmd)
  log.info(device.id .. ": " .. device.device_network_id .. " > RECEIVED PARTITION COMMAND " .. cmd.args.alarmMode)
  local partition = device.device_network_id:match('envisalink|p|(%d+)') .. ''
  send_partition_command(driver,device,partition,cmd.args.alarmMode)
end

local function sthm_handler(driver,device,cmd,command_name)
  log.info('SmartThings Home Monitor has triggered ' .. command_name)
  if device.preferences.integrateSTHM then
    local partition = device.device_network_id:match('envisalink|p|(%d+)') .. ''
    send_partition_command(driver,device,partition,command_name)
  else
    log.info('SmartThings Home Monitor integration is turned off in partition settings.')
  end
end

local function armAway_handler(driver,device,cmd)
  sthm_handler(driver,device,cmd,'armAway')
end

local function armStay_handler(driver,device,cmd)
  sthm_handler(driver,device,cmd,'armStay')
end

local function disarm_handler(driver,device,cmd)
  sthm_handler(driver,device,cmd,'disarm')
end

local function chime_handler(driver,device,cmd)
  local args = { ['command'] = 'chime', ['partition'] = device.device_network_id:match('envisalink|p|(.+)')}
  commands.send_evl_command(driver,args)
end

---------------------------------------
-- Partition Sub-Driver
local partition_driver = {
  NAME = "Partition",
  lifecycle_handlers = {
    added = added_handler,
    infoChanged = infoChanged_handler,
  },
  capability_handlers = {
    [capdefs.alarmMode.capability.ID] = {
      [capdefs.alarmMode.capability.commands.setAlarmMode.NAME] = handle_partition_command,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [capabilities.securitySystem.ID] = {
      [capabilities.securitySystem.commands.armAway.NAME] = armAway_handler,
      [capabilities.securitySystem.commands.armStay.NAME] = armStay_handler,
      [capabilities.securitySystem.commands.disarm.NAME] = disarm_handler,
    },
    [capabilities.chime.ID] = {
      [capabilities.chime.commands.chime.NAME] = chime_handler,
      [capabilities.chime.commands.off.NAME] = chime_handler,
    }
  },
  can_handle = can_handle_partitions,
  sub_drivers = { 
        require('partitions/primary'),
      }
}

return partition_driver