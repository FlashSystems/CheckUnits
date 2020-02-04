#!/bin/bash

# Version and Commit ID
# shellcheck disable=SC2016
COMMIT='$Id$'
VERSION="1.0"

# Check the shell version
if [ -z "${BASH_VERSINFO[*]}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
	echo "At least Bash version 4 required."
	exit 2
fi

# Tweak some settings
shopt -sq nullglob

# Output font and color definitions
# If the output is not a terminal, do not use any control sequences.
if [ -t 1 ]; then
	fontBold=$(tput -S <<< $'smul')
	fontInfo=$(tput -S <<< $'setaf black\nsetab 6')
	fontRemark=$(tput -S <<< $'setaf 3\nbold')
	fontWarn=$(tput -S <<< $'setaf black\nsetab 3')
	fontError=$(tput -S <<< $'setaf black\nsetab 1')
	fontCode=$(tput -S <<< $'bold')
	fontReset=$(tput -S <<< $'sgr0')
	fontDone=$(tput -S <<< $'setaf 2\nbold')
	fontDoneRemarks=$(tput -S <<< $'setaf 3\nbold')
else
	fontBold=''
	fontInfo=''
	fontRemark=''
	fontWarn=''
	fontError=''
	fontCode=''
	fontReset=''
	fontDone=''
	fontDoneRemarks=''
fi

# Outputs usage information.
function Usage () {
	# Use fmt to format the output. Prevent lines from being joined
	# together to allow better formatting.
	fmt -t -s <<- END
		CheckUnits v${VERSION} (${COMMIT:5:10})

		usage:
		       checkunits.sh [-p] [-c] [-s] [-v] [-i <Unit>] [-h]

		This shell script checks the systemd configuration of a modern Linux system and makes suggestions to optimize the use of systemd.

		It knows the following options:
	END
	# This lines might be joined to create a propper parameter list.
	fmt -t <<- END
		  -p
		     Report if the enabled/disabled state of the unit does not equal the preset state.
		  -c
		     Report units that where stopped because they are in conflict with an other unit.
		  -i
		     Ignores the given unit. This option can be passed multiple times to ignore multiple units.
		  -s
		     Disables the version warning and the summary output if no remarks where shown.
		  -v
		     Show additional information massages that are usefull in some cases.
		  -h
		     Display usage info.

	END
}

# Checks the state of the unit file by using a bunch of global variables.
# Globals: unitInfo, ignoreUnits, sdUnitPath, checkPresets, showConflicted, verbose
# These checks are based on the information in https://www.freedesktop.org/wiki/Software/systemd/dbus/
# The return code of this function is the number of remarks.
function CheckState () {
	local remarks=()

	[ "${unitInfo['UnitFileState']}" == 'transient' ] && return 0

	# Check if the unit file of this unit could be found. If that's the case, all other checks make no sense and we only warn about the missing file.
	if [ "${unitInfo['LoadState']}" == "not-found" ]; then
		while IFS='' read -rs -d' ' unitPath; do
			if [ -d "${unitPath}" ]; then
				for unitLink in "${unitPath}"/*/"${unitInfo['Id']}"; do
					[ -r "${unitLink}" ] || remarks+=("E: The symlink for this unit in ${unitLink%/*} is missing its destination unit file.:Maybe you have uninstalled the corresponding application and want to remove the symlink via [[rm ${unitLink}]].")
				done;
			fi;
		done <<< "${sdUnitPath#*=} " # Mind the space at the end!
	else
		for ignoredUnit in "${ignoreUnits[@]}"; do
			[ "${ignoredUnit}" == "${unitInfo['Id']}" ] && return 0
		done

		# Determin the class of the unit from the extension of the name
		unitClass="${unitInfo['Id']##*.}"

		# Map the current ActiveState of the unit to a more simple ActiveStateClass to simplify
		# the rest of the checks.
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
		
		# Check for failed and restarted units.
		[ "${simpleState}" == 'failed' ] && remarks+=("E: Unit is is failed state.:Check why it has failed using [[systemctl status ${unitInfo['Id']}]] or use [[journalctl -le -u ${unitInfo['Id']}]] to view the log. If everything is ok but you don't want to restart the unit, you can use [[systemctl reset-failed ${unitInfo['Id']}]] to reset the failed state.")
		[ -n "${unitInfo['NRestarts']}" ] && [ "${unitInfo['NRestarts']}" -gt 0 ] && remarks+=("W: The Unit ${unitInfo['Id']} was automatically restarted ${unitInfo['NRestarts']} times.:Maybe there is something wrong with it. You should check the logs via [[journalctl -le -u ${unitInfo['Id']}]]. If the unit is stable now, you can reset the restart counter using [[systemctl reset-failed ${unitInfo['Id']}]].")

		# If the service-unit has a sourcePath that points to /etc/init.d it's a generated legacy unit.
		# THe Unit file state "generated" can not be used here because it's currently not documented.
		[ -n "${unitInfo['SourcePath']}" ] && [ "${unitInfo['SourcePath']:0:11}" == '/etc/init.d' ] && [ "${unitClass}" == 'service' ] && remarks+=("I: The unit is a legacy unit generated by systemd.:Consider migrating the init script [[${unitInfo['SourcePath']}]] to a real systemd unit.")

		# Units triggered by timer units should be static
		# Check each trigger if it's a timer
		triggeredByTimer=0
		while IFS='' read -rs -d' ' trigger; do
			[ "${trigger##*.}" == "timer" ] && triggeredByTimer=1 && break
		done <<< "${unitInfo['TriggeredBy']} " # Mind the space at the end!

		if [ "${triggeredByTimer}" -gt 0 ] && [ "${unitInfo['UnitFileState']}" != "static" ]; then
			remarks+=("W: A unit file triggered by a timer should be static.:The unit is started by a timer and should not need an install section. Mostly you can remove the[[ [Install] ]]section from the unit file in [[${unitInfo['FragmentPath']}]] or create an override with [[systemctl edit ${unitInfo['Id']}]] for package provided units.")
		fi

		# In verbose mode, check if a unit triggered by a timer is disabled by a condition and provide an information for that case.
		if [ "${verbose}" -gt 0 ] && [ "${triggeredByTimer}" -gt 0 ] && [ -n "${unitInfo['ConditionTimestamp']}" ] && [ "${unitInfo['ConditionResult']}" == 'no' ]; then
			remarks+=("I: This unit is triggered by a timer but a condition does not allow it to run.:If you think the unit should be running check the condition via [[systemctl cat ${unitInfo['Id']}]].")
		fi

		# If this unit was enabled, but is not active and the ConflictedBy value is set, we check if any of the 
		# conflicting units is running. If that's the case the conflicted variable is set.
		conflicted=0
		if [ "${simpleState}" == 'inactive' ] && [ "${simpleUnitFileState}" == 'enabled' ] && [ -n "${unitInfo['ConflictedBy']}" ]; then
			while IFS='' read -r -s -d' ' conflict; do
				if systemctl -q is-active "${conflict}"; then
					conflicted=1

					[ "${showConflicted}" -gt 0 ] && remarks+=("I: Unit is stopped due to a conflict with unit ${conflict}.")
					break
				fi
			done <<< "${unitInfo['ConflictedBy']} " # Mind the space at the end of this string!
		fi

		case "${simpleUnitFileState}" in
			'enabled')
				# Only check the preset, if the unit this was enabled and
				# if the unit is not masked (because presets do not make sense for masked units.)
				if [ "${checkPresets}" -gt 0 ] && [ "${unitInfo['LoadState']}" != 'masked' ]; then
					[ "${simpleUnitFileState}" == "${unitInfo['UnitFilePreset']}" ] || remarks+=("W: Unit is enabled but preset wants it to be ${unitInfo['UnitFilePreset']}.:Create a preset file in [[/etc/systemd/system-preset/]] containing [[enable ${unitInfo['Id']}]] to change the preset to enabled or disable the unit via [[systemctl disable ${unitInfo['Id']}]]. For more information about presets use [[man systemd.preset]].")
				fi

				# If the unit is enabled, it should not be inactive. If it's in failed state, we've already reported this.
				# If the unit is conflicted, we do not report this, because someone wanted the unit to be off now.
				if [ "${simpleState}" == 'inactive' ] && [ ${conflicted} -eq 0 ]; then
					# Check if the unit was disabled by a condition. Because that would be ok.
					if [ -z "${unitInfo['ConditionTimestamp']}" ] || [ "${unitInfo['ConditionResult']}" != 'no' ]; then
						# If the unit is of type oneshot and ramainAfterExit is no and it exited successfully (because if the simpleState where
						# "failed" we wouldn't be here) then everything went as planned and we can ignore the inactive unit.
						# The condition is a little awkward because it's negated.
						if [ "${unitInfo['Type']}" != 'oneshot' ] || [ "${unitInfo['RemainAfterExit']}" != 'no' ]; then
							remarks+=("W: Unit is enabled but not active.:Use [[systemctl start ${unitInfo['Id']}]] to start the unit.")
						fi
					else
						[ "${verbose}" -gt 0 ] && remarks+=("I: Unit ${unitInfo['Id']} is disabled by a failed condition.:Use [[systemctl cat ${unitInfo['Id']}]] to show the unit file and check for unsatisified conditions.")
					fi
				fi
				;;
			'disabled')
				# See enabled
				if [ "${checkPresets}" -gt 0 ] && [ "${unitInfo['LoadState']}" != 'masked' ]; then
					[ "${simpleUnitFileState}" == "${unitInfo['UnitFilePreset']}" ] || remarks+=("W: Unit is disabled but preset wants it to be ${unitInfo['UnitFilePreset']}.:Create a preset file in [[/etc/systemd/system-preset/]] containing [[disable ${unitInfo['Id']}]] to change the preset to disabled or enable the unit via [[systemctl enable ${unitInfo['Id']}]]. For more information about presets use [[man systemd.preset]]..")
				fi

				# If this unit is active, check if any units that want this unit are active.
				# If that's the case, this unit may be active, because it was started by another unit.
				local activelyWanted=0
				if [ "${simpleState}" == 'active' ] && [ -n "${unitInfo['WantedBy']}" ]; then
					for service in ${unitInfo['WantedBy']}; do
						if systemctl is-active --quiet "${service}"; then
							activelyWanted=1

							# If we're in verbose mode, list the units wanting this unit.
							[ "${verbose}" -gt 0 ] && remarks+=("I: Unit ${unitInfo['Id']} is disabled but active because it is wanted by the active unit ${service}.")
						fi
					done
				fi

				# If the unit is disabled, it should be inactive as long as it's not triggered by another unit or by dbus.
				# For the dbus units we should check that there is really dbus activation registered. But communicating
				# with the dbus service and checking the configuration is beyond the scope this script.
				[ "${simpleState}" == 'active' ] && [ -z "${unitInfo['TriggeredBy']}" ] && [ "${activelyWanted}" -eq 0 ] && [ "${unitInfo['Type']}" != 'dbus' ] && remarks+=("W: Unit is disabled but ${unitInfo['ActiveState']}.:The unit will not start automatically on next reboot. If the unit should not be active, use [[systemctl stop ${unitInfo['Id']}]] to stop the unit. If the start of this unit was intentional, use [[systemctl enable ${unitInfo['Id']}]] to enable it permanently.")
				;;
			'invalid')
				;;
			'static')
				;;
		esac
	fi

	# End of checks. Start of output routine
	if [ "${#remarks[@]}" -gt 0 ]; then
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
				# Escaping the brackets is not neccessary but it makes the syntax highlighting of Sublime Text happy
				suggestion="${suggestion//\[\[/${fontCode}}"
				suggestion="${suggestion//\]\]/${fontReset}}"
				echo -e "${suggestion}${fontReset}"
			fi
		done
		echo
	fi

	return ${#remarks[@]}
}


# Parse command line argument
declare -a ignoreUnits
checkPresets=0
showConflicted=0
silent=0
verbose=0
while getopts "pcsvhi:" opt; do
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
		'v')
			verbose=1
			;;
		'h')
			Usage
			exit 0
			;;
		'?')
			exit 1
			;;
	esac
done

[ "${silent}" -eq 0 ] && echo "CheckUnits v${VERSION} (${COMMIT:5:10})..."

# Check the systemd version
IFS=" " read -rs _ version _ < <(systemctl --version)
if [ "${version}" -lt 239 ] && [ "${silent}" -eq 0 ]; then
	if [ "${verbose}" -eq 1 ]; then
		echo -e "${fontRemark}This system uses systemd version $version. This script has been tested with systemd 239 and above. The output may be incorrect or some information may be missing.${fontReset}"
	else
		echo -e "${fontRemark}Only systemd 239 and above supported."
	fi
fi

# Gather some global information about systemd
sdUnitPath=$(systemctl show -p UnitPath)

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
done < <(systemctl show -p Id -p Type -p NRestarts -p RemainAfterExit -p UnitFileState -p UnitFilePreset -p ActiveState -p TriggeredBy -p WantedBy -p ConflictedBy -p SourcePath -p LoadState -p ConditionResult -p ConditionTimestamp -p FragmentPath '*')

CheckState; ((messageCount+=$?))

if [ "$messageCount" -gt 0 ]; then
	echo -e "${fontDone}Check completed. ${fontDoneRemarks}$messageCount remarks.${fontReset}"
else
	[ "${silent}" -eq 0 ] && echo -e "${fontDone}Check completed without remarks.${fontReset} This does not mean everything will work as expected ;)"
fi
