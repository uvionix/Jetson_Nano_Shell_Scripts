#!/bin/bash

##########################
# The script sets the vehicle mode to RTL after a defined period of time provided as an input argument.
# The time period is in seconds.
##########################

nw_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/network-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
mavproxy_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/mavproxy-autostart.service | awk -F'=' '{print $2}' | sed s/'\s'//g)

logFile=$(grep -iw "LOG_FILE" $nw_setup_file | awk -F'"' '{print $2}')
logHistoryFilepathContainer=$(grep -iw "LOG_HISTORY_FILEPATH_CONTAINER" $nw_setup_file | awk -F'"' '{print $2}')
logHistoryFile=$(cat $logHistoryFilepathContainer)
chmod_port=$(grep -iw local_port_chmod $mavproxy_setup_file | awk -F'"' '{print $2}')
chmod_baudrate=$(grep -iw device_baud $mavproxy_setup_file | awk -F'"' '{print $2}')

sleep_count=$TIMOUT

printf "\t Switch to RTL service started! Switching after %d seconds.\n" $sleep_count | tee -a $logFile $logHistoryFile

while true
do
    sleep 1
    sleep_count=$((sleep_count-1))

    if [ $sleep_count -eq 0 ]
    then
        printf "\t Switching to RTL...\n" | tee -a $logFile $logHistoryFile
        /usr/local/bin/chmod_offline.py $chmod_port $chmod_baudrate rtl | tee -a $logFile $logHistoryFile

        if [ $? -eq 0 ]
        then
            break
        else
            printf "\t Switching to RTL failed. Retrying...\n" | tee -a $logFile $logHistoryFile
            sleep_count=1
        fi
    else
        echo "Switching to RTL in" $sleep_count "..."
        
        if [ $sleep_count -gt 10 ]
        then
            continue
        fi

        printf "\t Switching to RTL in %d...\n" $sleep_count | tee -a $logFile $logHistoryFile > /dev/null
    fi
done
