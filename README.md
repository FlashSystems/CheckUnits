# CheckUnits

This shell script checks the systemd configuration of a modern Linux system and makes suggestions to optimize the use of systemd. If an issue is found the script tries to tell you the commands to solve or further investigate the issue to get you started.

## Dependencies

This script does not have any dependencies besides `bash` and `systemd`.
It was tested with the following `bash` versions:

* 4.4
* 5.0

And the following `systemd` versions (a warning is shown if a version older that 239 is detected):

* 239 to 257

The script should work with newer versions of `bash` and `systemd` also. If not, please file a bug.

## Usage

Just clone or export the repository and call `checkunits.sh`.

## Command line options

`checkunits.sh` supports some command line options:

### -p

Shows a warning if the enabled/disabled state of the unit does not equal the preset state.

### -c

Report units that where stopped because they are in conflict with an other unit.

### -r *Restarts*

Allows to specify the number of restarts after which a warning is issued for a unit.

### -i *Unit*

Ignores the given unit. This option can be passed multiple times to ignore multiple units.

### -s

Disables the version warning and the summary output if no remarks where shown.

### -e

Shows errors only. This also enables `-s`. This option is usefull, if `checkunits.sh` is used for monitoring your system for unit failures. See chapter *Monitoring* for more details.

### -v

Verbose mode shows some additional information messages that are useful to clarify why specific warnings or errors are not shown. For example: An information message is shown if a unit is enabled but not running because it was disabled by a condition. These warnings are normally suppressed because conditions are legitimated to stop a unit from running.

### -h

Display usage info.

## Exit codes

`checkunits.sh` uses the following exit codes to convey the final result of its operation:

| Exit Code |                      Description                       |
|-----------|--------------------------------------------------------|
|         0 | The script completed successfully and without remarks. |
|       127 | The script completed successfully, but with remarks.   |
|         1 | Invalid command line option.                           |
|         2 | Unsupported bash version. Use bash 4.0 or newer.       |

# How it works

The script does some tests to make sure your current system state matches the systemd configuration. For all non transient systemd units the following checks are performed:

* If the unit has failed, an error is reported.
* If the unit was automatically restarted, a warning is reported.
* If the unit was created by the systemd-sysv-generator to start a legacy init-Script, an information is reported.
* If the unit file could not be found because of a dangling wants or requires symlink, an error is reported.
* If the unit is triggered by a timer unit...
  * and it is not static, a warning is reported.
  * and it is disabled by a condition, an information is reported (in verbose mode).
* If the unit was stopped because it conflicted with an other unit, an information is reported. (Only if `-c` is used)
* If the enabled/disabled state of the unit does not equal the preset state, an information is reported. (Only if `-p` is used)
* If the unit is enabled but not active, a warning is reported unless...
  * the unit is a one-shot unit and RemainAfterExit is set to "no" or
  * it was disabled by a condition. (Shows an information message in verbose mode).
* If the unit is disabled but active, a warning is reported unless...
  * the unit is triggered by another unit or
  * the unit is wanted by another active unit (shows an information message in verbose mode) or
  * the unit is a dbus-unit because these units can be triggered by dbus activation.

# Monitoring

CheckUnits can be used for a simple form of monitoring. The following oneliner sends an e-mail containing the output of the script if the return code is not 0:

```bash
mailbody=$(mktemp)
checkunits -e > "${mailbody?}"||mail -q "${mailbody?}" -s "Failed units" -r "MyHost <myhost@mydomain.example" "administrator@mydomain.example"
rm "${mailbody?}"
```

# Known issues

## disabled dbus units

For dbus-units, it is not checked if there really is a dbus service that activates the given systemd unit. Talking to the dbus service for this check is beyond the scope of this script. For disabled dbus units that are active, it is assumed that they where activated via dbus.

## simple services as oneshot replacements

Sometimes a simple service is enabled, runs once and stops. This is done to speed up the boot process. When using a oneshot service, systemd waits for the unit to finish, before starting dependencies. If this is not desired, a self terminating simple service is an alternative. RemainAfterExit should be used on this services to prevent `checkunits.sh` from reporting them as enabled, but not active.
