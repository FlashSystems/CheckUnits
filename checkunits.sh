#!/bin/bash

colorBold=$(tput smul)
colorInfo=$(tput setaf black; tput setab 12)
colorWarn=$(tput setaf black; tput setab 11)
colorError=$(tput setaf black; tput setab 9)
colorCode=$(tput bold)
colorReset=$(tput sgr0)

function CheckState () {
	[ "$unitType" == "oneshot" ] && return
	[ "$unitState" == "transient" ] && return
	
	local remarks=()

	[ "$activeState" == "failed" ] && remarks+=("E: Unit is is failed state.:Check why it has failed using {{{systemctl status $id}}} or use {{{systemctl reset-failed $id}}} to reset the failed state of the unit.")
	[ $restarts -gt 0 ] && remarks+=("W: The Unit $id was automatically restarted $restarts times.:Maybe there is something wrong with it. You should check the logs via {{{journalctl -le -u $id}}}.")

	case "$unitState" in
		enabled)
			[ "$unitState" == "$preset" ] || remarks+=("I: Unit is enabled but preset wants it to be $preset.:Create a preset file in {{{/etc/systemd/system-preset/}}} containing {{{enable $id}}}")

			# If the unit is enabled it should not be inactive. If it's in failed state we've already reported this.
			if [ "$activeState" == "inactive" ]; then
				[ "$result" == "success" ] && remarks+=("I: Unit is enabled but not active. It exited with the result "'"'"$result"'"'". It's very like you don't need to do anything.") || remarks+=("W: Unit is enabled but not active.:Use {{{systemctl start $id}}} to start the unit.")
			fi
			;;
		disabled)
			[ "$unitState" == "$preset" ] || remarks+=("I: Unit is disabled but preset wants it to be $preset.:Create a preset file in {{{/etc/systemd/system-preset/}}} containing {{{disable $id}}}.")

			# If the unit is disabled it should be inactive as long as it's not triggered by another unit
			[ "$activeState" == "inactive" ] || [ "$triggeredBy" == "" ] || remarks+=("W: Unit is disabled but $activeState.:Use {{{systemctl stop $id}}} to stop the unit.")
			;;
	esac

	if [ ${#remarks[@]} -gt 0 ]; then
		echo "Remarks for unit $colorBold$id$colorReset:"
		while IFS=":" read severity msg suggestion; do
			case "$severity" in
				I) echo -en "$colorInfo[ INFO  ]" ;;
				W) echo -en "$colorWarn[WARNING]" ;;
				E) echo -en "$colorError[ ERROR ]" ;;
			esac
			echo -en "$colorReset"
			echo "$msg"
			if [ -n "$suggestion" ]; then
				suggestion=${suggestion//\{\{\{/$colorCode}
				suggestion=${suggestion//\}\}\}/$colorReset}
				echo -e "$suggestion$colorReset"
			fi
			echo
		done <<< "$remarks"
	fi
}

while IFS="=" read -r key value; do
	if [ -z "$key" ]; then
		CheckState
	else
		case "$key" in
			Id) id="$value" ;;
			Type) unitType="$value" ;;
			Result) result="$value" ;;
			NRestarts) restarts="$value" ;;
			RemainAfterExit) remainAfterExit="$value" ;;
			UnitFileState) unitState="$value" ;;
			ActiveState) activeState="$value" ;;
			TriggeredBy) triggeredby="$value" ;;
			UnitFilePreset) preset="$value" ;;
		esac
	fi
done < <(systemctl show -p Id -p Type -p Result -p NRestarts -p RemainAfterExit -p UnitFileState -p UnitFilePreset -p ActiveState -p TriggeredBy '*')

CheckState
