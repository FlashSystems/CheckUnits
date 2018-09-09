#!/bin/bash

# Version and Commit ID
# shellcheck disable=SC2016
COMMIT='$Id$'
VERSION="0.2"

# Output font and color definitions
fontBold=$(tput smul)
fontInfo=$(tput setaf black; tput setab 6)
fontWarn=$(tput setaf black; tput setab 3)
fontError=$(tput setaf black; tput setab 1)
fontCode=$(tput bold)
fontReset=$(tput sgr0)
fontDone=$(tput setaf 2; tput bold)
fontDoneRemarks=$(tput setaf 3; tput bold)

# Checks the state of the unit file by using a bunch of global variables.
# These checks are based on the information in https://www.freedesktop.org/wiki/Software/systemd/dbus/
# The return code of this function is the number of remarks.
function CheckState () {
	[ "$unitType" == "oneshot" ] && return 0
	[ "$unitState" == "transient" ] && return 0
	
	local remarks=()

	# Check for failed and restarted units.
	[ "$activeState" == "failed" ] && remarks+=("E: Unit is is failed state.:Check why it has failed using {{{systemctl status $id}}} or use {{{systemctl reset-failed $id}}} to reset the failed state of the unit.")
	[ -n "$restarts" ] && [ "$restarts" -gt "0" ] && remarks+=("W: The Unit $id was automatically restarted $restarts times.:Maybe there is something wrong with it. You should check the logs via {{{journalctl -le -u $id}}}.")

	# If the service-unit has a sourcePath set that points to /etc/init.d it's a generated legacy unit.
	# THe Unit file state "generated" can not be used here because it's currently not documented.
	[ -n "$sourcePath" ] && [ "${sourcePath:0:11}" == "/etc/init.d" ] && [ "$unitClass" == "service" ] && remarks+=("I: The unit is legacy unit generated by systemd.:Consider migrating the init script {{{$sourcePath}}} to a real systemd unit.")

	# If this unit was enabled but is not active and the ConflictedBy value is set we check if any of the 
	# conflicting units is running. If that's the case the conflicted variable is set.
	conflicted=0
	if [ "$activeState" == "inactive" ] && [ "$unitState" == "enabled" ] && [ -n "$conflictedBy" ]; then
		while IFS="" read -r -s -d" " conflict; do
			if systemctl -q is-active "$conflict"; then
				conflicted=1
				break
			fi
		done <<< "$conflictedBy " # Mind the space at the end of this string!
	fi

	case "$unitState" in
		enabled)
			[ "$unitState" == "$preset" ] || remarks+=("I: Unit is enabled but preset wants it to be $preset.:Create a preset file in {{{/etc/systemd/system-preset/}}} containing {{{enable $id}}} to change the preset to enabled or disable the unit via {{{systemctl disable $id}}}. For more information about presets use {{{man systemd.preset}}}.")

			# If the unit is enabled it should not be inactive. If it's in failed state we've already reported this.
			# If the unit is conflicted we do not report this because someone wanted the unit to be off now.
			if [ "$activeState" == "inactive" ] && [ $conflicted -eq 0 ]; then
				if [ "$unitType" == "simple" ] && [ "$remainAfterExit" == "no" ] && [ "$result" == "success" ];then
					remarks+=("I: Unit is enabled but not active. It exited with the result "'"'"$result"'"'". It's very like you don't need to do anything.")
				else
					remarks+=("W: Unit is enabled but not active.:Use {{{systemctl start $id}}} to start the unit.")
				fi
			fi
			;;
		disabled)
			[ "$unitState" == "$preset" ] || remarks+=("I: Unit is disabled but preset wants it to be $preset.:Create a preset file in {{{/etc/systemd/system-preset/}}} containing {{{disable $id}}} to change the preset to disabled or enable the unit via {{{systemctl enable $id}}}. For more information about presets use {{{man systemd.preset}}}..")

			# If the unit is disabled it should be inactive as long as it's not triggered by another unit or by dbus
			[ "$activeState" == "inactive" ] || [ "$triggeredBy" == "" ] || [ "$unitType" == "dbus" ] || remarks+=("W: Unit is disabled but $activeState.:Use {{{systemctl stop $id}}} to stop the unit.")
			;;
	esac

	# End of checks. Start of output routine
	if [ ${#remarks[@]} -gt 0 ]; then
		echo "Remarks for unit $fontBold$id$fontReset:"
		for remark in "${remarks[@]}"; do
			IFS=":" read -r severity msg suggestion <<< "$remark"
			case "$severity" in
				I) echo -en "$fontInfo"'[ INFO  ]' ;;
				W) echo -en "$fontWarn"'[WARNING]' ;;
				E) echo -en "$fontError"'[ ERROR ]' ;;
			esac
			echo -en "$fontReset"
			echo "$msg"
			if [ -n "$suggestion" ]; then
				suggestion=${suggestion//\{\{\{/$fontCode}
				suggestion=${suggestion//\}\}\}/$fontReset}
				echo -e "$suggestion$fontReset"
			fi
		done
		echo
	fi

	return ${#remarks[@]}
}

echo "CheckServices v${VERSION} (${COMMIT//\$/})..."

messageCount=0
while IFS="=" read -r key value; do
	if [ -z "$key" ]; then
		CheckState; ((messageCount+=$?))
	else
		case "$key" in
			Id) id="$value"; unitClass="${id##*.}" ;;
			Type) unitType="$value" ;;
			Result) result="$value" ;;
			NRestarts) restarts="$value" ;;
			RemainAfterExit) remainAfterExit="$value" ;;
			UnitFileState) unitState="$value" ;;
			ActiveState) activeState="$value" ;;
			TriggeredBy) triggeredBy="$value" ;;
			UnitFilePreset) preset="$value" ;;
			ConflictedBy) conflictedBy="$value" ;;
			SourcePath) sourcePath="$value" ;;
		esac
	fi
done < <(systemctl show -p Id -p Type -p Result -p NRestarts -p RemainAfterExit -p UnitFileState -p UnitFilePreset -p ActiveState -p TriggeredBy -p ConflictedBy -p SourcePath '*')

CheckState; ((messageCount+=$?))

if [ $messageCount -gt 0 ]; then
	echo -e "${fontDone}Check completed. ${fontDoneRemarks}$messageCount remarks.${fontReset}"
else
	echo -e "${fontDone}Check completed without remarks.${fontReset} This does not mean everything will work as expected ;)"
fi
