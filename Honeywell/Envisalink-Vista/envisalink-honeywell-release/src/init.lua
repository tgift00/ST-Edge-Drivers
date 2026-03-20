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

local Driver = require('st.driver')
local log = require('log')
local events = require "evthandler"
local g = require('globals')

---------------------------------------
-- local imports
local lifecycles = require('lifecycles')

---------------------------------------
-- driver functions
local function discovery_handler(driver, _, should_continue)
  if not g.initialized then
    log.info("Creating primary partition device")
    events.createDevice(driver, 'partition', 'Primary Partition', 1, nil)
  else
    log.info ('Primary partition already created')
  end
end

---------------------------------------
-- Driver definition
local driver = Driver('envisalink-honeywell', {
      discovery = discovery_handler,
      lifecycle_handlers = lifecycles,
      sub_drivers = { 
        require('partitions'),
        require('zones'),
        require('switches')
      }
    }
  )

--------------------
-- Initialize Driver
driver:run()