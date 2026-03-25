local globals = {
  initialized = false,
  timers = { reconnect = nil, waitlogin = nil, throttle = nil, keepalive = nil },
  conf = {
    ip = '192.168.1.nnn',
    port = 4025,
    password = 'user',
    alarmcode = '1111',
    zoneclosedelay = 2,
    wiredzonemax = 8,
    partitions = { [1] = {}, [2] = {} },
    zones = { [1] = {}, [2] = {} },
    switches = { [1] = {}, [2] = {} },
  },
  zone_timers = { [1] = {}, [2] = {} },
  last_event = {},
  to_send_queue = {},
  -- Command-keyed lookup tables (command -> state/keyword/security)
  -- Used by commands.lua, partitions/init.lua, and utilities.lua for
  -- command-to-state resolution and direct mode change logic.
  --
  -- Panel state-keyed lookup tables (state -> switch/security) are in
  -- evthandler.lua (switch_modes and translate_state.security_system),
  -- used when processing incoming Envisalink events.
  --
  -- All armed states map to one of two ST security modes:
  --   armedStay (armStay, armInstant, armNight)
  --   armedAway (armAway, armMax)
  direct_change_states = {
    arming        = true,
    armedstay     = true,
    armedaway     = true,
    armedinstant  = true,
    armedmax      = true,
    armednight    = true,
    alarmcleared  = true,
  },
  command_map = {
    armStay     = { state = 'armedstay',    keyword = 'STAY',    security = 'armedStay' },
    armAway     = { state = 'armedaway',    keyword = 'AWAY',    security = 'armedAway' },
    armInstant  = { state = 'armedinstant', keyword = 'INSTANT', security = 'armedStay' },
    armMax      = { state = 'armedmax',     keyword = 'MAX',     security = 'armedAway' },
    armNight    = { state = 'armednight',   keyword = 'NIGHT',   security = 'armedStay' },
  },
  reconnectSeconds = 15,
  loginWaitSeconds = 3,
  connectRetrySeconds = 5,
  modeChangeDelay = 2,
  throttleSeconds = 2,
  keepaliveSeconds = 30,
}

return globals
