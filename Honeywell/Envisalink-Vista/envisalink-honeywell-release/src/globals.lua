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
}

return globals
