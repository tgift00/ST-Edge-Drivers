# SmartThings Edge Driver for Honeywell/Ademco Vista Panels with Envisalink Interface

## Overview

This driver provides a direct, local connection between the SmartThings hub and an Envisalink interface that is installed in a Honeywell/Ademco Vista panel. No additional hardware is required besides the ST Hub, Vista alarm system, and Envisalink. The driver supports two partitions and attempts to glean as much data as possible from the Vista panel. This driver uses the Envisalink connection functions developed by Todd Austin for the DSC/Envisalink integration. The logic for parsing Vista keypad update data from the Envisalink builds upon the work done by redloro for the STNP integration.

***This driver is a work in progress.*** ST Edge is currently (October 2021) in beta, and may change in ways that break this driver.

- [SmartThings Community topic](https://community.smartthings.com/t/st-edge-honeywell-ademco-vista-panel-envisalink/233766)
- [Installation instructions](INSTALLATION.md)

## Version Notes

### V 1.07
- **Direct alarm mode switching:** New partition preference "Direct Alarm Mode Switch" allows switching directly between armed modes (e.g. Armed Away → Armed Instant) without manually disarming first. The driver automatically sends a disarm followed by the new arm command with a 2 second delay. Works from partition commands, STHM integration, and virtual switches. Only allowed in safe states (arming, armedstay, armedaway, armedinstant, armedmax, alarmcleared) — blocked during active alarms. Requesting the same mode already active is ignored.
- **Connection resilience after power outage:** Added error handling on socket send operations. Failed sends now trigger automatic disconnect and reconnect instead of silently dropping commands.
- **Keepalive polling:** A periodic keepalive command (`^00,0$`) is sent every 30 seconds to detect dead connections and prevent session timeouts.
- **Reconnect race condition fix:** Resolved an issue where competing disconnect/reconnect paths could cancel each other's timers, leaving the driver unable to recover.
- **Switch state fix:** Fixed virtual switch state matching to use anchored pattern match, preventing partial matches on device network IDs.
- **Preference logging:** Partition preferences are now logged on startup for easier troubleshooting.
- **Code cleanup:** Refactored shared global variables, lookup tables, and timing constants into a `globals.lua` module.
- **Bug fix:** Fixed missing `driver` argument in `dowaitlogin` disconnect call that would cause an error if login timed out during reconnect.

### V 1.06 - 12/26/2021
- Added carbon monoxide detector device type.
- Fixed active/inactive status of icon on smoke detector dashboard.

### V 1.05 - 11/29/2021
- Fixed error where highest wired zone and zone delay preferences were not updating the driver properly.

### V 1.04 - 11/24/2021
- Fixed events for alarmMode - previously were posting the value instead of the key (e.g. Alarm instead of alarm). This was preventing automations from firing.

### V 1.03 - 11/22/2021
- Removed conversion of alarm code to integer. This was preventing alarm codes with leading zeroes from working, as the zeroes were removed in the conversion.

### V 1.02 - 11/20/2021
- Changes to account for panels that are set to display the exit delay countdown. The countdown was previously causing erroneous zone state changes to post.

### V 1.01 - 11/9/2021
- Fixed calls to update_tamper and update_battery to include correct parameters.

### V 1.00 - 10/29/2021
- Second partition support included. Limited testing so far, but all functions that treat p2 differently from p1 worked. Could enable p3 with a few changes, but not sure how useful it would be as it's the common partition.
- Panel commands are throttled to 1 every 2 seconds.
- Zones are currently closed using a system based on redloro's code for zone timers. Should change this in the future to get rid of some of the zone flutter but need to see how low battery reports cycle through the keypad sequence. Keypad updates cycle through the zone faults in ascending numerical order, but are interrupted by new faults and restart at lowest numbered zone. Zone timers work well with a couple faulted zones but are causing false zone clears when multiple zones are left faulted for an extended period.
- Contact and motion sensors tested extensively. Limited testing of smokes, leaks and glass breaks.
- Bypass command moved to individual zones. Multiple zones can be bypassed at once by putting them in a scene. Tested 3 zones in one scene - throttle seems to work fine to keep the commands from overloading the panel.
- Triggers 'work', but I have nothing connected to them so no clue if it's really working. No keypad reaction to trigger, so no way to tell whether they're on or off. May need to build in momentary capability for those using these as garage openers, but it's also possible to put both 'on' and 'off' in a single scene to accomplish the momentary action. Throttle would put a 2 second gap between the 'on' and 'off'.
- Messed up the platinummassive43262.smokeZone capability presentation, so 'clear' shows as active icon and 'detected' shows as inactive icon. Corrected presentation but old is cached for me - maybe it'll show correctly for others.
- Tamper tested on wireless contact sensors. Works, but the Vista panel stops giving any other notifications until the tamper is cleared. It doesn't seem like there's a workaround possible to continue getting zone fault data while tamper is active.
- Power loss to panel tested (just unplugged it). Panel handles this much better than tamper, continuing to cycle through zone faults.
- Need to test low battery on panel backup and on wireless zones. Both should report as 0 when low and 100 otherwise, but need to see if they override zone faults like tamper or are cycled through with zone faults. Right now I've assumed they cycle with zone faults.
- Currently using securitySystem stock capability in the background, though it's exposed in automations. Attributes will work on the 'If' side of automations, and the 'disarm' command will work on the 'Then' side. However, 'armAway' and 'armStay' commands require a boolean parameter to be passed, and there's no way to do that in the app. This can be done in webCoRE though. Interestingly, SmartThings Home Monitor automatically (and successfully) calls the disarm/armAway/armStay commands of every device with those capabilities when it's put in those states. Option added to partition preferences to enable/disable this linkage, but may need to think about how the default for that should function.
