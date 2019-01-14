#!/bin/bash

# Version and Commit ID
# shellcheck disable=SC2016
COMMIT='$Id$'
VERSION="0.4"

# Check the shell version
if [ -z "${BASH_VERSINFO}" ] || [ ${BASH_VERSINFO[0]} -lt 4 ]; then
	echo "At least Bash version 4 required."
	exit 2
fi

# Output font and color definitions
fontBold=$(tput -S <<< $'smul')
fontInfo=$(tput -S <<< $'setaf black\nsetab 6')
fontWarn=$(tput -S <<< $'setaf black\nsetab 3')
fontError=$(tput -S <<< $'setaf black\nsetab 1')
fontCode=$(tput -S <<< $'bold')
fontReset=$(tput -S <<< $'sgr0')
fontDone=$(tput -S <<< $'setaf 2\nbold')
fontDoneRemarks=$(tput -S <<< $'setaf 3\nbold')

# Checks the state of the unit file by using a bunch of global variables.
# These checks are based on the information in https://www.freedesktop.org/wiki/Software/systemd/dbus/
# The return code of this function is the number of remarks.
function CheckState () {
	[ "${unitInfo['UnitFileState']}" == 'transient' ] && return 0
	[ "${unitInfo['LoadState']}" == 'not-found' ] && return 0

	for ignoredUnit in "${ignoreUnits[@]}"; do
		[ "${ignoredUnit}" == "${unitInfo['Id']}" ] && return 0
	done

	# Determin the class of the unit from the extension of the name
	unitClass="${unitInfo['Id']##*.}"

	# Map the current ActiveState of the unit to a more simple ActiveStateClass to simplify
	# the rest of the cheks.
	case "${unitInfo['ActiveState']}" in
		'active'|'reloading'|'activating') simpleState='active' ;;
		'inactive'|'deactivating') simpleState='inactive' ;;
		'failed') simpleState='failed' ;;
	esac

	# Map the multiple UnitFileState values to a simplified set for testing.
	case "${unitInfo['UnitFileState']}" in
		'enabled'|'linked') simpleUnitFileState='enabled' ;;
		'enabled-runtime'|'linked-runtime'|'masked'|'masked-runtime'|'disabled') simpleUnitFileState='disabled' ;;
		# Catch "invalid", "static" and empty ("")
		*) simpleUnitFileState="${unitInfo['UnitFileState']}"
	esac
	
	local remarks=()

	# Check for failed and restarted units.
	[ "${simpleState}" == 'failed' ] && remarks+=("E: Unit is is failed state.:Check why it has failed using [[systemctl status ${unitInfo['Id']}]] or use [[journalctl -le -u ${unitInfo['Id']}]] to view the log. If everything is ok but you don't want to restart the unit, you can use [[systemctl reset-failed ${unitInfo['Id']}]] to reset the failed state.")
	[ -n "${unitInfo['NRestarts']}" ] && [ "${unitInfo['NRestarts']}" -gt 0 ] && remarks+=("W: The Unit ${unitInfo['Id']} was automatically restarted ${unitInfo['NRestarts']} times.:Maybe there is something wrong with it. You should check the logs via [[journalctl -le -u ${unitInfo['Id']}]]. If the unit is stable now, you can reset the restart counter using [[systemctl reset-failed ${unitInfo['Id']}]].")

	# If the service-unit has a sourcePath set that points to /etc/init.d it's a generated legacy unit.
	# THe Unit file state "generated" can not be used here because it's currently not documented.
	[ -n "${unitInfo['SourcePath']}" ] && [ "${unitInfo['SourcePath']:0:11}" == '/etc/init.d' ] && [ "${unitClass}" == 'service' ] && remarks+=("I: The unit is legacy unit generated by systemd.:Consider migrating the init script [[${unitInfo['SourcePath']}]] to a real systemd unit.")

	# If this unit was enabled but is not active and the ConflictedBy value is set we check if any of the 
	# conflicting units is running. If that's the case the conflicted variable is set.
	conflicted=0
	if [ "${simpleState}" == 'inactive' ] && [ "${simpleUnitFileState}" == 'enabled' ] && [ -n "${unitInfo['ConflictedBy']}" ]; then
		while IFS="" read -r -s -d" " conflict; do
			if systemctl -q is-active "${conflict}"; then
				conflicted=1

				[ ${showConflicted} -gt 0 ] && remarks+=("I: Unit is stopped due to a conflict with unit ${conflict}.")
				break
			fi
		done <<< "${unitInfo['ConflictedBy']} " # Mind the space at the end of this string!
	fi

	case "${simpleUnitFileState}" in
		'enabled')
			# Only check the preset if the unit this was enabled and
			# if the unit is not masked (because presets do not make sense for masked units.)
			if [ ${checkPresets} -gt 0 ] && [ "${unitInfo['LoadState']}" != 'masked' ]; then
				[ "${simpleUnitFileState}" == "${unitInfo['UnitFilePreset']}" ] || remarks+=("I: Unit is enabled but preset wants it to be ${unitInfo['UnitFilePreset']}.:Create a preset file in [[/etc/systemd/system-preset/]] containing [[enable ${unitInfo['Id']}]] to change the preset to enabled or disable the unit via [[systemctl disable ${unitInfo['Id']}]]. For more information about presets use [[man systemd.preset]].")
			fi

			# If the unit is enabled it should not be inactive. If it's in failed state we've already reported this.
			# If the unit is conflicted we do not report this because someone wanted the unit to be off now.
			if [ "${simpleState}" == 'inactive' ] && [ ${conflicted} -eq 0 ]; then
				# If the unit if of type oneshot and ramainAfterExit is no and it exited successfully (because if the simpleState where
				# "failed" we wouldn't be here) then everything went as planned and we can ignore the inactive unit.
				# The condition is a little awkward because it's negated.
				if [ "${unitInfo['Type']}" != 'oneshot' ] || [ "${unitInfo['RemainAfterExit']}" != 'no' ]; then
					remarks+=("W: Unit is enabled but not active.:Use [[systemctl start ${unitInfo['Id']}]] to start the unit.")
				fi
			fi
			;;
		'disabled')
			# See enabled
			if [ ${checkPresets} -gt 0 ] && [ "${unitInfo['LoadState']}" != 'masked' ]; then
				[ "${simpleUnitFileState}" == "${unitInfo['UnitFilePreset']}" ] || remarks+=("I: Unit is disabled but preset wants it to be ${unitInfo['UnitFilePreset']}.:Create a preset file in [[/etc/systemd/system-preset/]] containing [[disable ${unitInfo['Id']}]] to change the preset to disabled or enable the unit via [[systemctl enable ${unitInfo['Id']}]]. For more information about presets use [[man systemd.preset]]..")
			fi

			# If the unit is disabled it should be inactive as long as it's not triggered by another unit or by dbus
			# For the dbus units we should check that there is really dbus activation registered for this unit. But communicating
			# with the dbus service and checking the configuration is beyond the scope this script.
			[ "${simpleState}" == 'active' ] && [ "${unitInfo['TriggeredBy']}" == '' ] && [ "${unitInfo['Type']}" != 'dbus' ] && remarks+=("W: Unit is disabled but ${unitInfo['ActiveState']}.:If the unit should not be active, use [[systemctl stop ${unitInfo['Id']}]] to stop the unit. If the start of this unit was intentional, use [[systemctl enable ${unitInfo['Id']}]] to enable it permanently.")
			;;
		'invalid')
			;;
		'static')
			;;
	esac

	# End of checks. Start of output routine
	if [ ${#remarks[@]} -gt 0 ]; then
		echo "Remarks for unit ${fontBold}${unitInfo['Id']}${fontReset}:"
		for remark in "${remarks[@]}"; do
			IFS=":" read -r severity msg suggestion <<< "${remark}"
			case "${severity}" in
				I) echo -en "${fontInfo}[ INFO  ]" ;;
				W) echo -en "${fontWarn}[WARNING]" ;;
				E) echo -en "${fontError}[ ERROR ]" ;;
			esac
			echo -en "${fontReset}"
			echo "${msg}"
			if [ -n "${suggestion}" ]; then
				# Escaping the brackets is no neccessary but it makes the syntax highlighting of Sublime Text happy
				suggestion="${suggestion//\[\[/${fontCode}}"
				suggestion="${suggestion//\]\]/${fontReset}}"
				echo -e "${suggestion}${fontReset}"
			fi
		done
		echo
	fi

	return ${#remarks[@]}
}


echo "CheckServices v${VERSION} (${COMMIT:5:10})..."

# Parse command line argument
declare -a ignoreUnits
checkPresets=0
showConflicted=0
silent=0
while getopts "pcsi:" opt; do
	case "$opt" in
		'p')
			checkPresets=1
			;;
		'c')
			showConflicted=1
			;;
		's')
			silent=1
			;;
		'i')
			ignoreUnits+=("$OPTARG")
			;;
		'?')
			exit 1
			;;
	esac
done

# Check unit file info
declare -A unitInfo

messageCount=0
while IFS="=" read -r key value; do
	if [ -z "${key}" ]; then
		CheckState; ((messageCount+=$?))
		unset unitInfo; declare -A unitInfo
	else
		unitInfo["${key}"]="${value}"
	fi
done < <(systemctl show -p Id -p Type -p NRestarts -p RemainAfterExit -p UnitFileState -p UnitFilePreset -p ActiveState -p TriggeredBy -p ConflictedBy -p SourcePath -p LoadState '*')

CheckState; ((messageCount+=$?))

if [ $messageCount -gt 0 ]; then
	echo -e "${fontDone}Check completed. ${fontDoneRemarks}$messageCount remarks.${fontReset}"
else
	[ ${silent} -eq 0 ] && echo -e "${fontDone}Check completed without remarks.${fontReset} This does not mean everything will work as expected ;)"
fi
