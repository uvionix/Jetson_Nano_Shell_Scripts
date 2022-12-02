#!/bin/bash

##########################
# The script sets the vehicle mode to RTL after a defined period of time provided as an input argument.
# The time period is in seconds.
##########################

logFile=$(grep -i "LOG_FILE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
logHistoryFilepathContainer=$(grep -i "LOG_HISTORY_FILEPATH_CONTAINER" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
logHistoryFile=$(cat $logHistoryFilepathContainer)

sleep_count=$1

echo "Switch to RTL service started! Switching after" $sleep_count "seconds."
printf "\t Switch to RTL service started! Switching after %d seconds.\n" $sleep_count | tee -a $logFile $logHistoryFile > /dev/null

while true
do
    sleep 1
    sleep_count=$((sleep_count-1))

    if [ $sleep_count -eq 0 ]
    then
        echo "Switching to RTL..."
        printf "\t Switching to RTL...\n" | tee -a $logFile $logHistoryFile > /dev/null
        /usr/local/bin/chmod_offline.py rtl | tee -a $logFile $logHistoryFile > /dev/null

        if [ $? -eq 0 ]
        then
            break
        else
            echo "Switching to RTL failed. Retrying..."
            printf "\t Switching to RTL failed. Retrying...\n" | tee -a $logFile $logHistoryFile > /dev/null
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
