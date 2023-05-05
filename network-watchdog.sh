#!/bin/bash

##########################
# The script monitors network connectivity and stops/restarts the VPN and MAVProxy services
# when the connectivity is lost and regained. When the connectivity is lost the vehicle mode is switched to LOITER.
# If the network connectivity is not regained after a defined period of time the vehicle mode is switched to RTL.
##########################

# SCRIPT FUNCTIONS

# Check if a keyboard is connected
check_keyboard_connected()
{
	hmiDetected=0

	for dev in /sys/bus/usb/devices/*-*:*
	do
		if [ -f $dev/bInterfaceClass ]
		then
			if [[ "$(cat $dev/bInterfaceClass)" == "03" && "$(cat $dev/bInterfaceProtocol)" == "01" ]]
			then
				printf "Keyboard detected. WIFI connection type is selected.\n" | tee -a $logFile
				hmiDetected=1
				return
			fi
		fi
	done

	printf "Keyboard not detected. LTE connection type is selected.\n" | tee -a $logFile

	if [ $DISABLE_WIFI_IF_LTE_NETWORK_IS_SELECTED -eq 1 ]
	then
		disable_wifi
	fi

	printf "Switching to runlevel multi-user.target...\n" | tee -a $logFile
	init 3

	# sleep 20
}

# Check if media devices are connected
check_media_devices_connected()
{
	prev_media_devices_count=$media_devices_count
	media_devices_count=$(df --block-size=1K --output='source' | grep -E -c "$supported_media_devices_list")

	if [ $media_devices_count -ne $prev_media_devices_count ]
	then
		if [ $media_devices_count -eq 0 ]
		then
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Media devices disconnected!\n" | tee -a $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Media devices disconnected!\n" $nowTime | tee -a $logFile $logHistoryFile
			fi
		else
			media_devices_list=$(df --block-size=1K --output='source' | grep -E "$supported_media_devices_list")

			if [ $media_devices_count -gt $prev_media_devices_count ]
			then
				media_dev_conn_or_disconn="connected"
			else
				media_dev_conn_or_disconn="disconnected"
			fi

			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Media device has been $media_dev_conn_or_disconn!\n" | tee -a $logFile
				printf "\t Media devices currently connected are: %s\n" $media_devices_list | tee -a $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Media device has been $media_dev_conn_or_disconn!\n" $nowTime | tee -a $logFile $logHistoryFile
				printf "%s Media devices currently connected are: %s\n" $nowTime $media_devices_list | tee -a $logFile $logHistoryFile
			fi
		fi
	fi
}

# Update the keyboard connected status
update_keyboard_connected()
{
	hmiDetected=0

	for dev in /sys/bus/usb/devices/*-*:*
	do
		if [ -f $dev/bInterfaceClass ]
		then
			if [[ "$(cat $dev/bInterfaceClass)" == "03" && "$(cat $dev/bInterfaceProtocol)" == "01" ]]
			then
				hmiDetected=1
				return
			fi
		fi
	done
}

# Handle the frame start sync error associated with e-CAM24_CUNX camera
handle_frame_start_syncpt_timeout_err()
{
    # Get the number of errors in the log file
    frame_sync_error_cnt=$(dmesg | grep -i "video4linux" | grep -i -c "frame start syncpt timeout")

    if [ $frame_sync_error_cnt -gt 5 ]
    then
        # The number of errors is greater than the defined threshold -> find the average time between successive errors
        # and reboot the system if it falls bellow a certain threshold
        cnt=0
        sum=0

        dmesg | grep -i "video4linux" | grep -i "frame start syncpt timeout" | awk -F'[' '{print $2}' | awk -F']' '{print $1}' | while read -r timstamp; do
            if [ $cnt -eq 0 ]
            then
                prev_timstamp=$timstamp
                cnt=$((cnt+1))
                continue
            fi

            dt=$(bc <<< "scale=2; ($timstamp-$prev_timstamp)")
            sum=$(bc <<< "scale=2; ($sum+$dt)")
            prev_timstamp=$timstamp
            cnt=$((cnt+1))

            if [ $cnt -ge $frame_sync_error_cnt ]
            then
                dt=$(bc <<< "scale=0; $sum/$cnt")
                
                if [ $dt -lt 3 ]
                then
					if [ $logHistoryFileGenerated -eq 1 ]
					then
						nowTime=$(date +"%T")
						printf "%s Frame start sync timeout error detected! Rebooting...\n" $nowTime | tee -a $logFile $logHistoryFile
					fi

                    reboot
                fi

                break
            fi
        done
    fi
}

# Check if a camera is connected
check_camera_connected()
{
	camDetected=$(ls /dev/* | grep $video_device)

	# Check for "frame start sync error" if the camera service is started
	if [ ! -z "$cameraServiceName" ]
	then
		cam_service_started=$(systemctl status $cameraServiceName | grep -i "active:" | grep -i "running")
		if [ ! -z "$cam_service_started" ]
		then
			handle_frame_start_syncpt_timeout_err
		fi
	fi

	if [ -z "$camDetected" ]
	then
		# Cammera is not connected
		if [ $camConnected -eq 1 ]
		then
			# Camera has been disconnected - stop the camera service
			camera_force_stop
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Camera disconnected. Camera service stopped.\n" | tee -a $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Camera disconnected. Camera service stopped.\n" $nowTime | tee -a $logFile $logHistoryFile
			fi
		fi

		camConnected=0
	else
		# Camera is connected - start the camera service only if no keyboard is detected
		if [ $hmiDetected -eq 1 ]
		then
			# Keyboard has been detected - stop the camera if started
			if [ $camConnected -eq 1 ]
			then
				camera_force_stop
				if [ $logHistoryFileGenerated -eq 0 ]
				then
					printf "\t Keyboard connected. Camera service stopped.\n" | tee -a $logFile
				else
					nowTime=$(date +"%T")
					printf "%s Keyboard connected. Camera service stopped.\n" $nowTime | tee -a $logFile $logHistoryFile
				fi
			fi

			camConnected=0
			return
		fi

		if [ $camConnected -eq 0 ]
		then
			if [ $camera_and_lte_connections_probed -eq 0 ]
			then
				probe_camera_and_lte_connections
				camera_and_lte_connections_probed=1
			fi

			# Camera has been connected - start the camera service
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Camera connected and no keyboard detected. Starting camera...\n" | tee -a $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Camera connected and no keyboard detected. Starting camera...\n" $nowTime | tee -a $logFile $logHistoryFile
			fi

			camera_start
		fi

		camConnected=1
	fi
}

# Check the prerequisites for starting MAVProxy
check_mavproxy_prerequisites()
{
	# Get the UART device name
	uart_device=$(grep -iw "device=" $mavproxy_setup_file | awk -F'"' '{print $2}')
	echo "MAVProxy UART device is: $uart_device" | tee -a $logFile

	# Check the status of the nvgetty service and disable it if necessary
	nvgetty_found=""
	nvgetty_found=$(service nvgetty status)

	if [ ! -z "$nvgetty_found" ]
	then
		# nvgetty service exists
		nvgetty_disabled=$(service nvgetty status | grep -i loaded: | grep -i "nvgetty.service; disabled")
		nvgetty_inactive=$(service nvgetty status | grep -i active: | grep -i inactive)

		if [ -z "$nvgetty_disabled" ] || [ -z "$nvgetty_inactive" ];
		then
			echo "nvgetty service is enabled. Stopping and disabling the nvgetty service..." | tee -a $logFile
			systemctl stop nvgetty
			sleep 2
			systemctl disable nvgetty
			schedule_reboot=1
		else
			echo "nvgetty service is disabled."
		fi
	fi

	# Check the permissions of the MAVProxy UART port and modify them accordingly
	port_rights=$(stat -c "%a" $uart_device)

	if [ ! -z "$port_rights" ] && [ $port_rights -lt 660 ];
	then
		echo "Port $uart_device permissions set to $port_rights. Changing permissions of port $uart_device to 666..." | tee -a $logFile
		chmod 666 $uart_device
		schedule_reboot=1
	else
		if [ ! -z "$port_rights" ] && [ $port_rights -ge 660 ];
		then
			echo "Port $uart_device permissions are set correctly!" | tee -a $logFile
		else
			echo "Port $uart_device not found!" | tee -a $logFile
		fi
	fi

	if [ $schedule_reboot -eq 1 ]
	then
		echo "Rebooting system..." | tee -a $logFile
		sleep 5
		reboot
	elif [ ! -z "$port_rights" ]
	then
		echo "MAVProxy prerequisites met!" | tee -a $logFile
	fi
}

# Choose connection type (LTE or WIFI) and initialize the connection name and interface
choose_connection_type()
{
	while true
	do
		# Update devices connected status
		update_keyboard_connected
		check_media_devices_connected
		check_camera_connected

		if [ $hmiDetected -eq 0 ] && [ $lteNetworkSelected -eq 0 ];
		then
			# Select LTE connection type
			lteNetworkSelected=1
			pref_wifi_con_count=$max_pref_wifi_con_count
			wifiConnectionFound=""
			echo "Check if the LTE module is connected..." | tee -a $logFile
		fi

		if [ $lteNetworkSelected -eq 0 ]
		then
			# WIFI connection type is selected -> check if a preffered WIFI connection is available
			echo "Check if a preffered WIFI connection is available..." | tee -a $logFile
			# wifiConnectionName=$(nmcli connection | grep -m1 "wifi" | awk -F' ' '{print $1}')
			wifiConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 wifi | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
			len=`expr length "$wifiConnectionName"`

			if [ $len -gt $((min_wifi_con_name_length-1)) ]
			then
				wifiConnectionFound=$(nmcli device wifi list | grep -w "$wifiConnectionName")
				# pref_wifi_con_count=0
			else
				pref_wifi_con_count=$((pref_wifi_con_count+1))
				echo "Invalid WIFI connection name" "$wifiConnectionName" "obtained. Connection name must be at least" "$min_wifi_con_name_length" "characters long!" | tee -a $logFile
				sleep $SAMPLING_PERIOD_SEC

				if [ $pref_wifi_con_count -le $max_pref_wifi_con_count ]
				then
					continue
				fi
			fi
		fi

		if [ -z "$wifiConnectionFound" ] || [ $lteNetworkSelected -eq 1 ];
		then
			# The mobile connection is selected here after a defined number of attemts
			pref_wifi_con_count=$((pref_wifi_con_count+1))

			if [ $pref_wifi_con_count -gt $max_pref_wifi_con_count ]
			then
				# Check if the LTE module is available
				if [ $lteNetworkSelected -eq 0 ]
				then
					echo "Preffered WIFI connection is not available. Check if the LTE module is connected..." | tee -a $logFile
				fi

				lteNetworkSelected=1
				lteConnected=$(lsusb | grep -i "$LTE_MANUFACTURER_NAME")

				if [ ! -z "$lteConnected" ]
				then
					# LTE module is connected - get the associated device name
					lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
					echo "LTE module $LTE_MANUFACTURER_NAME connected. Getting device name..." | tee -a $logFile

					if [ -z "$lteDeviceName" ]
					then
						if [ $pref_wifi_con_count -gt $((max_pref_wifi_con_count+5)) ]
						then
							echo "Failed initializing LTE device name. Process restarting..." | tee -a $logFile
							pref_wifi_con_count=0
							lteNetworkSelected=0
						fi

						sleep $SAMPLING_PERIOD_SEC
						continue
					fi

					echo "LTE module $LTE_MANUFACTURER_NAME connected. Device name:" "$lteDeviceName" | tee -a $logFile
					
					lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

					if [ ! -z "$lteDeviceUnavailable" ]
					then
						echo "LTE device is not available. Check the SIM card!" | tee -a $logFile
						pref_wifi_con_count=0
						lteNetworkSelected=0
					else
						# LTE device is available - get the mobile connection name
						mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')

						echo "LTE interface name is set to $lteInterfaceName" | tee -a $logFile

						mobileInterfaceName=$lteInterfaceName
						wifiNetworkSelected=0
						lteNetworkSelected=1
						echo "Preffered mobile connection $mobileConnectionName found!" | tee -a $logFile
						break
					fi
				else
					# LTE module is not connected
					if [ $hmiDetected -eq 1 ]
					then
						echo "LTE module is not connected. Scanning for a preffered WIFI connection..." | tee -a $logFile
					else
						echo "LTE module is not connected. Process restarting..." | tee -a $logFile
					fi

					pref_wifi_con_count=0
					lteNetworkSelected=0
				fi
			else
				echo "Preffered WIFI connection is not available." | tee -a $logFile
			fi
		else
			# WIFI connection type is selected
			echo "Preffered WIFI connection $wifiConnectionName found!" | tee -a $logFile
			mobileConnectionName="$wifiConnectionName"
			mobileInterfaceName=$wifiInterfaceName
			wifiNetworkSelected=1
			lteNetworkSelected=0
			break
		fi

		sleep $SAMPLING_PERIOD_SEC
	done
}

# Check for internet connection
check_internet_connection()
{
	local timOut=7
	local address="8.8.8.8"
	local perPacketsLostThs=50
	local perPacketsLost=$(ping -w $timOut $address | grep -m1 "packets transmitted" | awk -F'% packet loss' '{print $1}' | awk -F'received, ' '{print $2}')

	if [ $perPacketsLost -gt $perPacketsLostThs ]
	then
		# No internet connection
		return 1
	else
		return 0
	fi
}

# Wait for internet connection
wait_for_internet_connection()
{
	while true
	do
		check_internet_connection
		if [ $? -eq 0 ]
		then
			break
		fi

		echo -e "\t Waiting for internet..."
		sleep 1
	done
}

# Synchronize date and time
sync_date_and_time()
{
	wait_for_internet_connection >> $logFile

	timedatectl set-ntp off
	sleep 2
	timedatectl set-ntp on
	sleep 10
}

# Connect to a network via the chosen connection type and start the VPN service
network_connect()
{
	while true
	do
		# Update devices connected status
		update_keyboard_connected
		check_media_devices_connected
		check_camera_connected

		echo "Attempting connection to $mobileConnectionName..." | tee -a $logFile
		connectionFound=$(nmcli connection | grep -i -o "$mobileConnectionName")

		if [ ! -z "$connectionFound" ]
		then
			nmcli connection up "$mobileConnectionName"

			if [ $? -eq 0 ]
			then
				if [ $wifiNetworkSelected -eq 1 ]
				then
					# Update the wifi interface name
					wifiInterfaceName=$(nmcli device | grep wifi | grep "$mobileConnectionName" | awk -F' ' '{print $1}')
					mobileInterfaceName=$wifiInterfaceName
					echo "Wifi interface set to $wifiInterfaceName"
					printf "\t Wifi interface set to %s\n" $wifiInterfaceName >> $logFile
				fi

				echo "Connection successful! Synchronizing date and time..." | tee -a $logFile
				service openvpn-autostart stop
				sync_date_and_time

				nowTime=$(date +"%T")
				nowDate=$(date +"%D")
				echo "Date and time set to $nowDate $nowTime" | tee -a $logFile
				printf "============= %s %s STARTING LOG FILE =============\n" $nowDate $nowTime >> $logFile

				if [ $SET_MAX_CPU_GPU_EMC_CLOCKS -eq 1 ]
				then
					# Set static max frequency to CPU, GPU and EMC clocks
					echo "$nowTime Setting static max frequency to CPU, GPU and EMC clocks..." | tee -a $logFile
					jetson_clocks
				else
					echo "$nowTime Auto setting up static max frequency to CPU, GPU and EMC clocks is disabled!" | tee -a $logFile
				fi

				# Generate the filepath for the log history file
				mkdir -p $LOG_HISTORY_DIR
				logHistoryFile=$LOG_HISTORY_DIR$(date +"%Y-%m-%d-%T")
				logHistoryFileGenerated=1

				# Copy the filepath to an interface file to be used by other scripts for logging
				echo $logHistoryFile > $LOG_HISTORY_FILEPATH_CONTAINER

				# Update the VPN configuration file
				nowTime=$(date +"%T")
				ovpn_config_file=$(find /etc/openvpn/ -iname *.ovpn)
				if [ -z "$ovpn_config_file" ]
				then
					echo "$nowTime The directory /etc/openvpn/ does not contain a VPN configuration file. Aborting!" | tee -a $logFile
					cp $logFile $logHistoryFile
					exit 0
				fi

				echo "# PATH TO THE OPENVPN CONFIGURATION FILE" > $openvpn_setup_file
				echo CONFIG_FILE_PATH=\"$ovpn_config_file\" >> $openvpn_setup_file
				echo "$nowTime Starting the VPN service..." | tee -a $logFile
				printf "\t VPN configuration file set to %s\n" $ovpn_config_file >> $logFile
				wait_for_internet_connection >> $logFile
				service openvpn-autostart restart

				# Create the log history file from the log file generated so far
				# (from now on every log message is written to $logFile and $logHistoryFile)
				cp $logFile $logHistoryFile
				break
			else
				echo "Connection failed! Retrying..." | tee -a $logFile
				nmcli connection down "$mobileConnectionName"
			fi
		fi

		sleep $SAMPLING_PERIOD_SEC
	done
}

# Disconnect from all networks
network_disconnect()
{
	while true
	do
		conname=$(nmcli device | grep -w -m1 connected)

		if [ ! -z "$conname" ]
		then
			# Get the actual connection name after removing the leading and trailing whitespaces
			conname=$(nmcli device | grep -w -m1 connected | awk -F'connected' '{print $2}' | sed -e 's/^[ \t]*//' | sed -e 's/[ \t]*$//')
			nmcli connection down "$conname"
		else
			break
		fi
	done
}

# Process the event where the network was just disconnected
process_network_just_disconnected()
{
	ip_address_wait_count=0
	printf "%s Network disconnected!\n" $nowTime | tee -a $logFile $logHistoryFile

	# Stop the VPN service
	printf "%s Stopping the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile
	service openvpn-autostart stop
	nowTime=$(date +"%T")
		
	if [ $AUTO_SWITCH_TO_LOITER -eq 1 ]
	then
		printf "%s Switching to LOITER mode...\n" $nowTime | tee -a $logFile $logHistoryFile
		/usr/local/bin/chmod_offline.py $chmod_port $chmod_baudrate loiter | tee -a $logFile $logHistoryFile
	else
		printf "%s Auto switching to LOITER mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile
	fi
			
	nowTime=$(date +"%T")

	if [ $switch_to_RTL_mode_service_started -eq 0 ] && [ $AUTO_SWITCH_TO_RTL -eq 1 ];
	then
		printf "%s Starting switch to RTL service...\n" $nowTime | tee -a $logFile $logHistoryFile
		service switch-to-rtl start
		switch_to_RTL_mode_service_started=1
	else
		if [ $AUTO_SWITCH_TO_RTL -eq 0 ]
		then
			printf "%s Auto switching to RTL mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile
		fi
	fi

	# TODO: If dynamic gstreamer pipeline is created signal it to stop the streaming branch
	#if [ $camConnected -eq 1 ]
	#then
	#	nowTime=$(date +"%T")
	#fi

	net_con_count=0

	if [ $wifiNetworkSelected -eq 1 ]
	then
		printf "\t Attempting to switch to LTE connection mode...\n" | tee -a $logFile $logHistoryFile
	fi
}

# Disable WIFI via GPIO
disable_wifi()
{
	echo "Disabling WIFI..." | tee -a $logFile

	# Check if the GPIO base value has already been configured - if not configure it
	gpio_base_configured=$(grep -iw "GPIO_BASE" $nw_setup_file)
	if [ -z "$gpio_base_configured" ]
	then
    	echo "Configuring GPIO_BASE by examining the file /sys/kernel/debug/gpio ..." | tee -a $logFile

    	# Read the GPIO base value by examining the file /sys/kernel/debug/gpio
    	gpio_base=$(cat /sys/kernel/debug/gpio | grep gpiochip0 | awk -F' ' '{print $3}' | awk -F'-' '{print $1}')

    	# Write the GPIO base value in the network watchdog setup file
    	echo "GPIO_BASE=$gpio_base" >> $nw_setup_file
	fi

	# Get the GPIO base value
	gpio_base=$(grep -iw "GPIO_BASE" $nw_setup_file | awk -F'=' '{print $2}')
	echo "GPIO base value set to $gpio_base" | tee -a $logFile

	# Calculate the number of the wifi disable GPIO
	wifi_disable_gpio=$((gpio_base+$WIFI_DISABLE_GPIO_OFFSET))

	# Export the GPIO if it is not exported
	regular_gpioNumber="gpio$wifi_disable_gpio"
	gpio_exported=$(ls /sys/class/gpio/ | grep "$regular_gpioNumber" )

	if [ -z "$gpio_exported" ]
	then
		echo $wifi_disable_gpio > /sys/class/gpio/export
	fi

	if [ $? -eq 0 ]
	then
		wifi_disable_cnt=0

		while true
		do
			if [ $wifi_disable_cnt -gt $max_wifi_disable_cnt ]
			then
				echo "WIFI disable failed!" | tee -a $logFile
				break
			fi

			# Get the current GPIO value
			gpio_curr_value=$(cat /sys/class/gpio/$regular_gpioNumber/value)

			if [ $gpio_curr_value -eq 1 ]
			then
				echo "WIFI successfully disabled!" | tee -a $logFile
				break
			else
				configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

				if [ -z "$configured_direction_out" ]
				then
					echo out > /sys/class/gpio/$regular_gpioNumber/direction
				else
					echo 1 > /sys/class/gpio/$regular_gpioNumber/value
				fi

				sleep $SAMPLING_PERIOD_SEC
			fi

			wifi_disable_cnt=$((wifi_disable_cnt+1))
		done
	else
		echo "WIFI disable failed!" | tee -a $logFile
	fi
}

# Probe camera and LTE connections
probe_camera_and_lte_connections()
{
	local lte_disconnected_after_cam_probing=0
	local lte_wait_disconnected_cnt=0
	local lte_max_wait_disconnected_cnt=10
	echo -e "\t Camera probing is enabled..." | tee -a $logFile

	# Wait until the LTE module is connected
	echo -e "\t Waiting until the LTE module is connected..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$LTE_MANUFACTURER_NAME")

    	if [ ! -z "$lteConnected" ]
    	then
        	break
    	fi

    	sleep $SAMPLING_PERIOD_SEC
	done

	# LTE module is connected - probe the camera connection
	echo -e "\t LTE module is connected. Probing the camera connection..." | tee -a $logFile
	sleep 7
	service gstreamer-camera-probe start

	# Wait to see if the LTE module will be disconnected as a result of the camera probing
	echo -e "\t Waiting to see if the LTE module will be disconnected as a result of the camera probing..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$LTE_MANUFACTURER_NAME")

    	if [ -z "$lteConnected" ]
    	then
			echo -e "\t LTE module disconnected!" | tee -a $logFile
			lte_disconnected_after_cam_probing=1
        	break
    	fi

    	lte_wait_disconnected_cnt=$((lte_wait_disconnected_cnt+1))

    	if [ $lte_wait_disconnected_cnt -gt $lte_max_wait_disconnected_cnt ]
    	then
			echo -e "\t Wait timeout! LTE is still connected." | tee -a $logFile
        	break
    	fi

    	sleep $SAMPLING_PERIOD_SEC
	done

	# Stop camera probing
	echo -e "\t Stopping camera probing..." | tee -a $logFile
	service gstreamer-camera-probe stop

	if [ $lte_disconnected_after_cam_probing -eq 0 ]
	then
		return
	fi

	# Wait until the LTE module is reconnected
	echo -e "\t Waiting until the LTE module is reconnected..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$LTE_MANUFACTURER_NAME")

    	if [ ! -z "$lteConnected" ]
    	then
			# LTE module is connected. Wait for device name...
			lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
			if [ ! -z "$lteDeviceName" ]
			then
				break
			fi
    	fi

    	sleep $SAMPLING_PERIOD_SEC
	done

	echo -e "\t LTE module is reconnected!" | tee -a $logFile
	#sleep 10
}

# Get the name of the camera service
get_camera_service_name()
{
	while true
	do
		cameraServiceName=$(systemctl --type=service --state=active | grep -m1 camera-start@ | awk -F' ' '{print $1}')
		if [ ! -z "$cameraServiceName" ]
		then
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Camera service name initialized as %s\n" $cameraServiceName | tee -a $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Camera service name initialized as %s\n" $nowTime $cameraServiceName | tee -a $logFile $logHistoryFile
			fi
			
			break
		fi

		sleep $SAMPLING_PERIOD_SEC
	done
}

# Start the camera
camera_start()
{
	systemctl start camera-start.socket
	get_camera_service_name
}

# Stop the camera by terminating the camera service
camera_force_stop()
{
	systemctl stop camera-start.socket
	systemctl stop $cameraServiceName
}

# Start MAVProxy
start_mavproxy()
{
	# Check if MAVProxy has already been started
	service_started=$(service mavproxy-autostart status | grep -i "active:" | grep -i "running")
	if [ -z "$service_started" ]
	then
		echo "Checking MAVProxy prerequisites..." | tee -a $logFile
		check_mavproxy_prerequisites
		echo "Starting MAVProxy..." | tee -a $logFile

		while true
		do
			service mavproxy-autostart start

			if [ $? -eq 0 ]
			then
				echo "MAVProxy started." | tee -a $logFile
				break
			else
				echo "MAVProxy starting failed. Retrying..." | tee -a $logFile
				service mavproxy-autostart stop
				sleep $SAMPLING_PERIOD_SEC
			fi
		done
	else
		echo "MAVProxy has already been started!" | tee -a $logFile
	fi

	# Starting MAVProxy related services
	service_started=$(service update-uav-latest-status status | grep -i "active:" | grep -i "running")
	if [ -z "$service_started" ]
	then
		service update-uav-latest-status start
		echo "Started UAV status update service." | tee -a $logFile
	else
		echo "UAV status update service has already been started!" | tee -a $logFile
	fi
}

# Restart MAVProxy
restart_mavproxy()
{
	service mavproxy-autostart restart
}

### MAIN SCRIPT STARTS HERE ###

# SCRIPT PARAMETERS
nw_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/network-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
mw_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/modem-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
gst_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/camera-start@.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
mavproxy_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/mavproxy-autostart.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
openvpn_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/openvpn-autostart.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
Disconnected=0
Reconnecting=1
Connected=2
chmod_port=$(grep -iw local_port_chmod $mavproxy_setup_file | awk -F'"' '{print $2}')
chmod_baudrate=$(grep -iw device_baud $mavproxy_setup_file | awk -F'"' '{print $2}')
video_device=$(grep -iw capture_dev $gst_setup_file | awk -F'"' '{print $2}')
rec_destination_dev=$(grep -iw rec_destination_dev $gst_setup_file | awk -F'"' '{print $2}')
max_net_con_count=15 # Final value of the mobile network connection counter after which a new connection attempt will be made if the mobile network is available
max_vpn_con_count=15 # Final value of the VPN network connection counter after which the VPN service is restarted
max_ip_address_wait_count=10 # Final value of the wait for IP address counter after which the network is disconnected
max_pref_wifi_con_count=10 # Final value of the preffered wifi connection scan counter after which the mobile network is selected
min_wifi_con_name_length=2 # Minimum number of characters in the WIFI connection name
max_wifi_disable_cnt=10 # Final value of the wifi disable count after which wifi disable attemts are canceled
logFile=$LOG_FILE
logHistoryFileGenerated=0
logHistoryFile=""
lteInterfaceName=$LTE_INTERFACE_NAME
lteInterfaceNameAlt=$LTE_INTERFACE_NAME_ALT
wifiInterfaceName=$WIFI_INTERFACE_NAME
lteDeviceName=""
mobileConnectionName=""
mobileInterfaceName=""
cameraServiceName=""
networkStatus=$Reconnecting
media_devices_count=0
vpn_con_count=0
net_con_count=0
ip_address_wait_count=0
ip_address_wait_timout_occured=0
pref_wifi_con_count=0
wifiNetworkSelected=0
lteNetworkSelected=0
switch_to_RTL_mode_service_started=0
hmiDetected=0
camConnected=0
schedule_reboot=0
supported_media_devices_list="$rec_destination_dev|/dev/sd"

> $logFile # Clear the log file
> $LOG_HISTORY_FILEPATH_CONTAINER # Clear the log history filepath container
printf "============= INITIALIZING NEW LOG FILE =============\n" >> $logFile
echo "Initializing..." | tee -a $logFile

# Check if the modem power enable type has been configured
modem_power_enable_type_configured=$(grep -iw "MODEM_PWR_EN_GPIO_AS_I2C_MUX" $mw_setup_file)
if [ -z "$modem_power_enable_type_configured" ]
then
	printf "Modem power enable GPIO type is not configured. Camera probing will be enabled!\n" >> $logFile
	camera_and_lte_connections_probed=0
else
	# Check if the modem power enable GPIO is configured is an I2C mux GPIO
	modem_pwr_en_gpio_as_i2c_mux=$(grep -iw "MODEM_PWR_EN_GPIO_AS_I2C_MUX" $mw_setup_file | awk -F'=' '{print $2}')

	if [ $modem_pwr_en_gpio_as_i2c_mux -eq 1 ]
	then
		printf "Modem power enable GPIO is configured as an I2C mux GPIO. Camera probing is enabled!\n" >> $logFile
    	camera_and_lte_connections_probed=0
	else
    	camera_and_lte_connections_probed=1
	fi
fi

# Check if a keyboard is connected
check_keyboard_connected

# Check if a camera is connected
camDetected=$(ls /dev/* | grep $video_device)

if [ ! -z "$camDetected" ]
then
	echo "Camera connected as $video_device. Waiting for recording destination device $rec_destination_dev to become available..." | tee -a $logFile
	rec_dev_detected_wait_cnt=0
	while true
	do
		rec_dev_found=$(df --block-size=1K --output='source' | grep "$rec_destination_dev")
		if [ ! -z "$rec_dev_found" ]
		then
			break
		fi

		if [ $rec_dev_detected_wait_cnt -ge 5 ]
		then
			echo -e "\t Wait timeout occured! Skipping..." | tee -a $logFile
			break
		fi

		sleep $SAMPLING_PERIOD_SEC
		rec_dev_detected_wait_cnt=$((rec_dev_detected_wait_cnt+1))
	done
fi

# Check if the camera service has been started
cam_socket_started=$(systemctl status camera-start.socket | grep -i "active:" | grep -i "running")
uav_status_service_started=$(service update-uav-latest-status status | grep -i "active:" | grep -i "running")
if [ ! -z "$cam_socket_started" ] && [ ! -z "$uav_status_service_started" ];
then
	echo "Camera connected and has been started!" | tee -a $logFile
	camera_and_lte_connections_probed=1
	get_camera_service_name
	camConnected=1
fi

# Check if media devices are connected
check_media_devices_connected

# Start MAVProxy
start_mavproxy

# Start using camera immediately if detected
if [ $camConnected -eq 0 ] && [ ! -z "$camDetected" ] && [ $hmiDetected -eq 0 ];
then
	if [ $camera_and_lte_connections_probed -eq 0 ]
	then
		probe_camera_and_lte_connections
		camera_and_lte_connections_probed=1
	fi

	echo "Camera connected. Starting the camera service..." | tee -a $logFile
	camera_start
	camConnected=1
fi

# Choose connection type (LTE or WIFI) and initialize the connection name and interface
choose_connection_type

# Connect to a network via the chosen connection type and start the VPN service
network_connect

# Main watchdog loop
while true
do
	# Check if the mobile connection state is DOWN
	if [ $wifiNetworkSelected -eq 1 ]
	then
		update_keyboard_connected
		
		# Check if the mobile interface is listed
		interfaceListed=$(nmcli device | grep "$wifiInterfaceName")
		if [ -z "$interfaceListed" ]
		then
			mobileConnectionState=""
			printf "\t Network interface %s unavailable!\n" $wifiInterfaceName | tee -a $logFile $logHistoryFile
		else
			# mobileConnectionState=$(ip address show dev "$mobileInterfaceName" | grep -i -o "state down")
			mobileConnectionState=$(nmcli device | grep "$wifiInterfaceName" | awk -F' ' '{print $3}' | grep -E 'discon|unavail')
		fi
	else
		# Update the mobile interface device name in case it has changed if the module has been restarted by the modem watchdog service
		lteDeviceTypeGSM=$(nmcli device | grep -m1 -i "gsm")
		if [ ! -z "$lteDeviceTypeGSM" ]
		then
			lteDeviceNameNew=$(nmcli device | grep -m1 -i "gsm" | awk -F' ' '{print $1}')

			if [ ! -z "$lteDeviceNameNew" ] && [ "$lteDeviceName" != "$lteDeviceNameNew" ];
			then
				lteDeviceName=$lteDeviceNameNew
				printf "\t LTE device name changed to %s!\n" "$lteDeviceName" | tee -a $logFile $logHistoryFile
			fi
		fi

		# Check if the mobile interface is listed
		interfaceListed=$(nmcli device | grep "$lteDeviceName")
		if [ -z "$interfaceListed" ]
		then
			mobileConnectionState=""
			printf "\t Network interface %s unavailable!\n" "$lteDeviceName" | tee -a $logFile $logHistoryFile
		else
			mobileConnectionState=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep -E 'discon|unavail')
		fi
	fi

	# Check the connected media devices
	check_media_devices_connected

	# Check if a camera is connected
	check_camera_connected

	if [ $ip_address_wait_timout_occured -eq 1 ] || [ ! -z "$mobileConnectionState" ] || [ -z "$interfaceListed" ];
	then
		# Mobile network is disconnected
		nowTime=$(date +"%T")

		if [ $networkStatus -ne $Disconnected ]
		then
			networkStatus=$Disconnected
			process_network_just_disconnected
		fi

		# Check if a mobile network is available and connect to it
		net_con_count=$((net_con_count+1))

		if [ $net_con_count -gt $max_net_con_count ]
		then
			nowTime=$(date +"%T")
			printf "%s Scanning for connection %s...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile
			connectionFound=$(nmcli connection | grep -i -o "$mobileConnectionName")

			if [ ! -z "$connectionFound" ] && [ ! -z "$interfaceListed" ];
			then
				nowTime=$(date +"%T")
				printf "%s Connection %s found. Attempting connection...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile
				nmcli connection up "$mobileConnectionName"
				ip_address_wait_timout_occured=0
				net_con_count=0
				sleep $SAMPLING_PERIOD_SEC
				continue
			else
				nowTime=$(date +"%T")
				printf "%s Connection %s not found. Retrying...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile
			fi

			net_con_count=0
		fi

		# If a wifi connection was selected then switch to LTE connection ------------------
		if [ $wifiNetworkSelected -eq 1 ]
		then
			printf "\t Check if the LTE module is connected...\n" | tee -a $logFile $logHistoryFile
			lteConnected=$(lsusb | grep -i "$LTE_MANUFACTURER_NAME")

			if [ ! -z "$lteConnected" ]
			then
				# LTE module is connected - get the associated device name
				lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
				printf "\t LTE module %s connected. Getting device name...\n" $LTE_MANUFACTURER_NAME | tee -a $logFile $logHistoryFile

				if [ -z "$lteDeviceName" ]
				then
					printf "\t Failed initializing LTE device name. Process restarting...\n" | tee -a $logFile $logHistoryFile
					sleep $SAMPLING_PERIOD_SEC
					continue
				fi

				printf "\t LTE module %s connected. Device name: %s.\n" $LTE_MANUFACTURER_NAME "$lteDeviceName" | tee -a $logFile $logHistoryFile
				lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

				if [ ! -z "$lteDeviceUnavailable" ]
				then
					printf "\t LTE device is not available. Check the SIM card!\n" | tee -a $logFile $logHistoryFile
				else
					# LTE device is available - get the mobile connection name
					mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
					printf "\t LTE interface name is set to %s.\n" "$lteInterfaceName" | tee -a $logFile $logHistoryFile
					mobileInterfaceName=$lteInterfaceName
					wifiNetworkSelected=0
					lteNetworkSelected=1
					printf "\t Preffered mobile connection %s found!\n" "$mobileConnectionName" | tee -a $logFile $logHistoryFile
					net_con_count=$max_net_con_count
				fi
			else
				printf "\t LTE module is not connected!\n" | tee -a $logFile $logHistoryFile
			fi
		fi

		if [ $wifiNetworkSelected -eq 1 ]
		then
			networkInterfaceUnavailable=$(nmcli device | grep "$wifiInterfaceName" | awk -F' ' '{print $3}' | grep "unavail")
			networkInterfaceUnavailableName=$wifiInterfaceName
		else
			networkInterfaceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "unavail")
			networkInterfaceUnavailableName=$lteDeviceName
		fi

		if [ ! -z "$networkInterfaceUnavailable" ]
		then
			printf "\t Network interface %s unavailable!\n" "$networkInterfaceUnavailableName" | tee -a $logFile $logHistoryFile
			net_con_count=$max_net_con_count
			sleep $SAMPLING_PERIOD_SEC
			continue
		fi
		# ----------------------------------------------------------------------------------
	else
		# Mobile network is connected - get the IP address
		net_con_count=0
		mobileIpAddress=$(ip address show | grep -A2 $mobileInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

		if [ -z "$mobileIpAddress" ]
		then
			if [ $lteNetworkSelected -eq 1 ]
			then
				# Check the alternative LTE interface name
				mobileIpAddress=$(ip address show | grep -A2 $lteInterfaceNameAlt | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

				if [ -z "$mobileIpAddress" ]
				then
					printf "\t Waiting for IP address...\n" | tee -a $logFile $logHistoryFile
					ip_address_wait_count=$((ip_address_wait_count+1))

					if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
					then
						printf "\t Waiting for IP address timeout. Disconnecting from network...\n" | tee -a $logFile $logHistoryFile
						network_disconnect
						process_network_just_disconnected
						networkStatus=$Disconnected
						ip_address_wait_timout_occured=1
					fi

					sleep $SAMPLING_PERIOD_SEC
					continue
				else
					# Switch the LTE interface name
					mobileInterfaceName=$lteInterfaceNameAlt
					printf "\t LTE interface name switched from %s to %s.\n" "$lteInterfaceName" "$lteInterfaceNameAlt" | tee -a $logFile $logHistoryFile

					# Swap the main and alternative LTE interfaces 
					lteInterfaceNameAlt=$lteInterfaceName
					lteInterfaceName=$mobileInterfaceName
				fi
			else
				printf "\t Waiting for IP address...\n" | tee -a $logFile $logHistoryFile
				ip_address_wait_count=$((ip_address_wait_count+1))

				if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
				then
					printf "\t Waiting for IP address timeout. Disconnecting from network...\n" | tee -a $logFile $logHistoryFile
					network_disconnect
					process_network_just_disconnected
					networkStatus=$Disconnected
					ip_address_wait_timout_occured=1
				fi

				sleep $SAMPLING_PERIOD_SEC
				continue
			fi
		fi

		if [ $networkStatus -eq $Disconnected ]
		then
			if [ $wifiNetworkSelected -eq 1 ]
			then
				# Update the wifi interface name
				wifiInterfaceName=$(nmcli device | grep wifi | grep "$mobileConnectionName" | awk -F' ' '{print $1}')
				mobileInterfaceName=$wifiInterfaceName
				printf "\t Wifi interface set to %s\n" $wifiInterfaceName | tee -a $logFile $logHistoryFile
			fi

			nowTime=$(date +"%T")
			printf "%s Network is now connected! Mobile IP: %s\n" $nowTime $mobileIpAddress | tee -a $logFile $logHistoryFile
			printf "%s Starting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile

			service openvpn-autostart start
			networkStatus=$Reconnecting
			vpn_con_count=0
		fi

		# Get the IP address associated with the VPN network interface
		vpnIpAddress=$(ip address show | grep -A2 $VPN_INTERFACE_NAME | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

		if [ -z "$vpnIpAddress" ]
		then
			# No VPN IP address found - VPN is still connecting
			if [ $networkStatus -ne $Reconnecting ]
			then
				nowTime=$(date +"%T")

				# The VPN service is restarted when VPN connection is lost without losing mobile network connectivity
				networkStatus=$Reconnecting
				printf "%s VPN connection lost!\n" $nowTime | tee -a $logFile $logHistoryFile

				if [ $AUTO_SWITCH_TO_LOITER -eq 1 ]
				then
					printf "%s Switching to LOITER mode...\n" $nowTime | tee -a $logFile $logHistoryFile
					/usr/local/bin/chmod_offline.py $chmod_port $chmod_baudrate loiter | tee -a $logFile $logHistoryFile
				else
					printf "%s Auto switching to LOITER mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile
				fi

				nowTime=$(date +"%T")

				if [ $switch_to_RTL_mode_service_started -eq 0 ] && [ $AUTO_SWITCH_TO_RTL -eq 1 ];
				then
					printf "%s Starting switch to RTL service...\n" $nowTime | tee -a $logFile $logHistoryFile
					service switch-to-rtl start
					switch_to_RTL_mode_service_started=1
				else
					if [ $AUTO_SWITCH_TO_RTL -eq 0 ]
					then
						printf "%s Auto switching to RTL mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile
					fi
				fi

				# TODO: If dynamic gstreamer pipeline is created signal it to stop the streaming branch
				#if [ $camConnected -eq 1 ]
				#then
				#	nowTime=$(date +"%T")
				#fi

				nowTime=$(date +"%T")
				printf "%s Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi

			vpn_con_count=$((vpn_con_count+1))
			if [ $vpn_con_count -gt $max_vpn_con_count ]
			then
				nowTime=$(date +"%T")
				printf "%s Connection timeout. Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi
		else
			# VPN IP address found - get the first two octets and check the values
			oct1=$(ip address show | grep -A2 $VPN_INTERFACE_NAME | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $1}')
			oct2=$(ip address show | grep -A2 $VPN_INTERFACE_NAME | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $2}')

			if [ $oct1 -eq 192 ] && [ $oct2 -eq 168 ];
			then
				if [ $networkStatus -ne $Connected ]
				then
					nowTime=$(date +"%T")
					printf "%s VPN connected! VPN IP: %s Mobile IP: %s\n" $nowTime $vpnIpAddress $mobileIpAddress | tee -a $logFile $logHistoryFile
					networkStatus=$Connected

					if [ $switch_to_RTL_mode_service_started -eq 1 ] && [ $AUTO_SWITCH_TO_RTL -eq 1 ];
					then
						nowTime=$(date +"%T")
						printf "%s Stopping switch to RTL service.\n" $nowTime | tee -a $logFile $logHistoryFile
						service switch-to-rtl stop
						switch_to_RTL_mode_service_started=0
					fi

					nowTime=$(date +"%T")
					printf "%s Restarting MAVProxy.\n" $nowTime | tee -a $logFile $logHistoryFile
					restart_mavproxy

					# TODO: If dynamic gstreamer pipeline is created signal it to start the streaming branch 
					#if [ $camConnected -eq 1 ]
					#then
					#	nowTime=$(date +"%T")
					#fi
				fi
			else
				nowTime=$(date +"%T")
				printf "%s Error! VPN connected but IP address invalid. Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile

				# Restart the VPN service
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi
		fi
	fi

	if [ $logHistoryFileGenerated -eq 1 ]
	then
		num_lines_in_logFile=$(wc -l $logFile | awk -F' ' {'print $1'})
		num_lines_in_logHistoryFile=$(wc -l $logHistoryFile | awk -F' ' {'print $1'})

		if [ $num_lines_in_logFile -ne $num_lines_in_logHistoryFile ]
		then
			# Sync the log file and the log history file
			cp $logFile $logHistoryFile
		fi
	fi

	# Copy the current log file within the XOSS webpage root directory
	cp $logFile $WEBPAGE_NW_LOG_FILE

	sleep $SAMPLING_PERIOD_SEC
done
