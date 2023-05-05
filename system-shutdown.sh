#!/bin/bash

### MAIN SCRIPT STARTS HERE ###

# SCRIPT PARAMETERS
nw_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/network-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)

logFile=$(grep -iw "LOG_FILE" $nw_setup_file | awk -F'"' '{print $2}')
logHistoryFilepathContainer=$(grep -iw "LOG_HISTORY_FILEPATH_CONTAINER" $nw_setup_file | awk -F'"' '{print $2}')
logHistoryFile=$(cat $logHistoryFilepathContainer)

nowTime=$(date +"%T")
printf "%s System shutdown requested...\n" $nowTime | tee -a $logFile $logHistoryFile
printf "%s Stopping services...\n" $nowTime | tee -a $logFile $logHistoryFile

service network-watchdog stop
service update-uav-latest-status stop
service mavproxy-autostart stop
service openvpn-autostart stop
service modem-watchdog stop
systemctl stop camera-start.socket

nowTime=$(date +"%T")
printf "%s Shutting down.\n" $nowTime | tee -a $logFile $logHistoryFile
sleep 2
shutdown -h now
