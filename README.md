# CheckUnits
This shell script checks the systemd configuration of a modern Linux system and makes suggestions to optimize the use of systemd. If an issue is found the script tries to tell you the commands to solve or further investigate the issue to get you started.

## Dependencies
This script does not have many dependencies. It was tests with bash 4.4 and systemd 239 but should work with older versions as well.

## Usage
Just clone or export the repository and call `checkunits.sh`.

# How it works
The script does some tests to make sure your current system state matches the systemd configuration. For all non transient systemd units the following checks are performed:

* If the unit has failed an error is reported.
* If the unit was automatically restarted a warning is reported.
* If the unit was created by the systemd-sysv-generator to start a legacy init-Script an information is reported.
* If the enabled/disabled state of the unit does not equal the preset state an information is reported.
* If the unit is enabled but not active a warning is reported unless...
  * the unit is a one-shot unit and RemainAfterExit is set to "no".
* If the unit is disabled but active a warning is reported unless...
  * the unit is triggered by another unit or
  * the unit is a dbus-unit because these units can be triggered by dbus activation.

# Known issues
## disabled dbus units
For dbus-units it is not checked if there really is a dbus service that activates the given systemd unit. Talking to the dbus service for this check is beyond the scope of this script. For disabled dbus units that are active it is assumed that it was activated via dbus.

## simple services as oneshot replacements
Sometimes a simple service is enabled, runs once and stops. This is done to speed up the boot process. When using a oneshot service systemd waits for the unit to finish before starting dependencies. If this is not desired a self terminating simple service is an alternative. RemainAfterExit should be used on this services to prevent `checkunits.sh` from reporting them as enabled but not active.