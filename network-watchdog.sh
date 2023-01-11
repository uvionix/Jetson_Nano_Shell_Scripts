#!/bin/bash

##########################
# The script monitors network connectivity and stops/restarts the VPN and MAVProxy services
# when the connectivity is lost and regained. When the connectivity is lost the vehicle mode is switched to LOITER.
# If the network connectivity is not regained after a defined period of time the vehicle mode is switched to RTL.
##########################

# SCRIPT FUNCTIONS

# Initialize script variables
init_variables()
{
	lteDeviceName=""
	mobileConnectionName=""
	mobileInterfaceName=""
	networkStatus=$Reconnecting
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
	media_devices_count=0
}

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
				echo "Keyboard detected: $dev"
				printf "Keyboard detected. WIFI connection type is selected.\n" >> $logFile
				hmiDetected=1
				return
			fi
		fi
	done

	echo "Keyboard not detected. LTE connection type is selected."
	printf "Keyboard not detected. LTE connection type is selected.\n" >> $logFile

	if [ $disable_wifi_if_lte_net_selected -eq 1 ]
	then
		disable_wifi
	fi

	sleep 20
}

# Check if media devices are connected
check_media_devices_connected()
{
	prev_media_devices_count=$media_devices_count
	media_devices_count=$(df --block-size=1K --output='source' | grep -c "/dev/sd")

	if [ $media_devices_count -ne $prev_media_devices_count ]
	then
		if [ $media_devices_count -eq 0 ]
		then
			echo "Media devices disconnected!"

			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Media devices disconnected!\n" >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Media devices disconnected!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
			fi
		else
			echo "Media devices connected!"
			media_devices_list=$(df --block-size=1K --output='source' | grep "/dev/sd")

			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Media devices %s are now connected!\n" $media_devices_list >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Media devices %s are now connected!\n" $nowTime $media_devices_list | tee -a $logFile $logHistoryFile > /dev/null
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

# Stop the gstreamer service
service_gstreamer_stop()
{
	/usr/bin/killall -2 gst-launch-1.0
	service gstreamer-autostart stop
}

# Update the vehicle armed status
update_vehicle_armed_status()
{
	read_file_wait_cnt=0
	while true
	do
		vehicle_armed=$(grep -i "armed" $armedDisarmedStatusFile)

	    if [ ! -z "$vehicle_armed" ]
	    then
	        break
	    fi

	    # If here the file $armedDisarmedStatusFile is currently being written to
	    sleep 1
		read_file_wait_cnt=$((read_file_wait_cnt+1))

		if [ $read_file_wait_cnt -gt 5 ]
		then
			echo "Wait timeout occured while trying to read the vehicle armed/disarmed status file!"
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Wait timeout occured while trying to read the vehicle armed/disarmed status file!\n" >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Wait timeout occured while trying to read the vehicle armed/disarmed status file!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
			fi
			vehicle_armed=$prev_vehicle_armed
			break
		fi
	done
}

# Check if a camera is connected
check_camera_connected()
{
	camDetected=$(ls /dev/* | grep $video_device)
	update_vehicle_armed_status

	if [ -z "$camDetected" ]
	then
		# Cammera is not connected
		if [ $camConnected -eq 1 ]
		then
			# Camera has been disconnected - stop gstreamer
			service_gstreamer_stop
			echo "Camera disconnected. GStreamer stopped."
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Camera disconnected. GStreamer stopped.\n" >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Camera disconnected. GStreamer stopped.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
			fi
		fi

		camConnected=0
	else
		# Camera is connected - start gstreamer only if no keyboard is detected
		if [ $hmiDetected -eq 1 ]
		then
			# Keyboard has been detected - stop gstreamer if started
			if [ $camConnected -eq 1 ]
			then
				service_gstreamer_stop
				echo "Keyboard connected. GStreamer stopped."
				if [ $logHistoryFileGenerated -eq 0 ]
				then
					printf "\t Keyboard connected. GStreamer stopped.\n" >> $logFile
				else
					nowTime=$(date +"%T")
					printf "%s Keyboard connected. GStreamer stopped.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
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

			# Camera has been connected - start gstreamer
			service gstreamer-autostart start
			echo "Camera connected and no keyboard detected. GStreamer started."
			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Camera connected and no keyboard detected. GStreamer started.\n" >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Camera connected and no keyboard detected. GStreamer started.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
			fi
		fi

		# Check the vehicle armed/disarmed status
		if [ $camConnected -eq 1 ] && [ "$prev_vehicle_armed" != "$vehicle_armed" ];
		then
			echo "Vehicle armed status has changed! Restarting gstreamer..."
			if [ ! "$vehicle_armed" != "DISARMED" ]
			then
				armed_status="DISARMED"
			else
				armed_status="ARMED"
			fi

			if [ $logHistoryFileGenerated -eq 0 ]
			then
				printf "\t Vehicle status has changed to %s! Restarting gstreamer...\n" $armed_status >> $logFile
			else
				nowTime=$(date +"%T")
				printf "%s Vehicle status has changed to %s! Restarting gstreamer...\n" $nowTime $armed_status | tee -a $logFile $logHistoryFile > /dev/null
			fi

			service gstreamer-autostart reload
		fi

		camConnected=1
	fi

	prev_vehicle_armed=$vehicle_armed
}

# Check the prerequisites for starting MAVProxy
check_mavproxy_prerequisites()
{
	# Get the UART device name
	uart_device=$(grep -i "device=" /etc/default/mavproxy-setup | awk -F'"' '{print $2}')
	echo "MAVProxy UART device is: $uart_device"
	printf "\t MAVProxy UART device is: %s\n" $uart_device >> $logFile

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
			echo "nvgetty service is enabled. Stopping and disabling the nvgetty service..."
			printf "\t nvgetty service is enabled. Stopping and disabling the nvgetty service...\n" >> $logFile
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
		echo "Port $uart_device permissions set to $port_rights. Changing permissions of port $uart_device to 666..."
		printf "\t Port %s permissions set to %s. Changing permissions of port %s to 666...\n" $uart_device $port_rights $uart_device >> $logFile
		chmod 666 $uart_device
		schedule_reboot=1
	else
		if [ ! -z "$port_rights" ] && [ $port_rights -ge 660 ];
		then
			echo "Port $uart_device permissions are set correctly!"
			printf "\t Port %s permissions are set correctly!\n" $uart_device >> $logFile
		else
			echo "Port $uart_device not found!"
			printf "\t Port %s not found!\n" $uart_device >> $logFile
		fi
	fi

	if [ $schedule_reboot -eq 1 ]
	then
		echo "Rebooting system..."
		printf "\t Rebooting system...\n" >> $logFile
		sleep 5
		reboot
	elif [ ! -z "$port_rights" ]
	then
		echo "MAVProxy prerequisites met!"
		printf "\t MAVProxy prerequisites met!\n" >> $logFile
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
			echo "Check if the LTE module is connected..."
			printf "Check if the LTE module is connected...\n" >> $logFile
		fi

		if [ $lteNetworkSelected -eq 0 ]
		then
			# WIFI connection type is selected -> check if a preffered WIFI connection is available
			echo "Check if a preffered WIFI connection is available..."
			printf "Check if a preffered WIFI connection is available...\n" >> $logFile
			# wifiConnectionName=$(nmcli connection | grep -m1 "wifi" | awk -F' ' '{print $1}')
			wifiConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 wifi | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
			len=`expr length "$wifiConnectionName"`

			if [ $len -gt $((min_wifi_con_name_length-1)) ]
			then
				wifiConnectionFound=$(nmcli device wifi list | grep -w "$wifiConnectionName")
				# pref_wifi_con_count=0
			else
				pref_wifi_con_count=$((pref_wifi_con_count+1))
				echo "Invalid WIFI connection name" "$wifiConnectionName" "obtained. Connection name must be at least" "$min_wifi_con_name_length" "characters long!"
				printf "Invalid WIFI connection name %s obtained. Connection name must be at least %d characters long!\n" "$wifiConnectionName" $min_wifi_con_name_length >> $logFile
				sleep $samplingPeriodSec

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
					echo "Preffered WIFI connection is not available. Check if the LTE module is connected..."
					printf "Preffered WIFI connection is not available. Check if the LTE module is connected...\n" >> $logFile
				fi

				lteNetworkSelected=1
				lteConnected=$(lsusb | grep -i "$lteManufacturerName")

				if [ ! -z "$lteConnected" ]
				then
					# LTE module is connected - get the associated device name
					lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
					echo "LTE module" "$lteManufacturerName" "connected. Getting device name..."
					printf "LTE module %s connected. Getting device name...\n" "$lteManufacturerName" >> $logFile

					if [ -z "$lteDeviceName" ]
					then
						if [ $pref_wifi_con_count -gt $((max_pref_wifi_con_count+5)) ]
						then
							echo "Failed initializing LTE device name. Process restarting..."
							printf "Failed initializing LTE device name. Process restarting...\n" >> $logFile
							pref_wifi_con_count=0
							lteNetworkSelected=0
						fi

						sleep $samplingPeriodSec
						continue
					fi

					echo "LTE module" "$lteManufacturerName" "connected. Device name:" "$lteDeviceName"
					printf "LTE module %s connected. Device name: %s.\n" "$lteManufacturerName" "$lteDeviceName" >> $logFile
					
					lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

					if [ ! -z "$lteDeviceUnavailable" ]
					then
						echo "LTE device is not available. Check the SIM card!"
						printf "LTE device is not available. Check the SIM card!\n" >> $logFile
						pref_wifi_con_count=0
						lteNetworkSelected=0
					else
						# LTE device is available - get the mobile connection name
						mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')

						echo "LTE interface name is set to" "$lteInterfaceName"
						printf "LTE interface name is set to %s.\n" "$lteInterfaceName" >> $logFile

						mobileInterfaceName=$lteInterfaceName
						wifiNetworkSelected=0
						lteNetworkSelected=1
						echo "Preffered mobile connection" "$mobileConnectionName" "found!"
						printf "Preffered mobile connection %s found!\n" "$mobileConnectionName" >> $logFile
						break
					fi
				else
					# LTE module is not connected
					if [ $hmiDetected -eq 1 ]
					then
						echo "LTE module is not connected. Scanning for a preffered WIFI connection..."
						printf "LTE module is not connected. Scanning for a preffered WIFI connection...\n" >> $logFile
					else
						echo "LTE module is not connected. Process restarting..."
						printf "LTE module is not connected. Process restarting...\n" >> $logFile
					fi

					pref_wifi_con_count=0
					lteNetworkSelected=0
				fi
			else
				echo "Preffered WIFI connection is not available."
				printf "Preffered WIFI connection is not available.\n" >> $logFile
			fi
		else
			# WIFI connection type is selected
			echo "Preffered WIFI connection" "$wifiConnectionName" "found!"
			printf "Preffered WIFI connection %s found!\n" "$wifiConnectionName" >> $logFile
			mobileConnectionName="$wifiConnectionName"
			mobileInterfaceName=$wifiInterfaceName
			wifiNetworkSelected=1
			lteNetworkSelected=0
			break
		fi

		sleep $samplingPeriodSec
	done
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

		echo "Attempting connection to" "$mobileConnectionName" "..."
		printf "Attempting connection to %s...\n" "$mobileConnectionName" >> $logFile
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

				printf "Connection successful! Synchronizing date and time...\n" >> $logFile
				echo "Connection successful! Synchronizing date and time..."
				timedatectl set-ntp off
				timedatectl set-ntp on
				sleep 10

				nowTime=$(date +"%T")
				nowDate=$(date +"%D")
				echo "Date and time set to " "$nowDate" "$nowTime"
				printf "Date and time set to %s %s\n" $nowDate $nowTime >> $logFile
				printf "============= %s %s STARTING LOG FILE =============\n" $nowDate $nowTime >> $logFile

				echo "Checking MAVProxy prerequisites..."
				printf "%s Checking MAVProxy prerequisites...\n" $nowTime >> $logFile
				check_mavproxy_prerequisites

				if [ $set_max_cpu_gpu_emc_clocks -eq 1 ]
				then
					# Set static max frequency to CPU, GPU and EMC clocks
					nowTime=$(date +"%T")
					echo "Setting static max frequency to CPU, GPU and EMC clocks..."
					printf "%s Setting static max frequency to CPU, GPU and EMC clocks...\n" $nowTime >> $logFile
					jetson_clocks
				else
					echo "Auto setting up static max frequency to CPU, GPU and EMC clocks is disabled!"
					printf "Auto setting up static max frequency to CPU, GPU and EMC clocks is disabled!\n" >> $logFile
				fi

				# Generate the filepath for the log history file
				mkdir -p $logHistoryDir
				logHistoryFile=$logHistoryDir$(date +"%Y-%m-%d-%T")
				logHistoryFileGenerated=1

				# Copy the filepath to an interface file to be used by other scripts for logging
				echo $logHistoryFile > $logHistoryFilepathContainer

				# Update the VPN configuration file
				nowTime=$(date +"%T")
				ovpn_config_file=$(find /etc/openvpn/ -iname *.ovpn)
				if [ -z "$ovpn_config_file" ]
				then
					echo "The directory /etc/openvpn/ does not contain a VPN configuration file. Aborting."
					printf "%s The directory /etc/openvpn/ does not contain a VPN configuration file. Aborting.\n" $nowTime >> $logFile
					cp $logFile $logHistoryFile
					exit 0
				fi

				echo "#PATH TO THE OPENVPN CONFIGURATION FILE" > /etc/default/openvpn-setup
				echo CONFIG_FILE_PATH=\"$ovpn_config_file\" >> /etc/default/openvpn-setup
				echo "Starting the VPN service..."
				printf "%s Starting the VPN service...\n" $nowTime >> $logFile
				printf "\t VPN configuration file set to %s\n" $ovpn_config_file >> $logFile
				service openvpn-autostart start

				# Create the log history file from the log file generated so far
				# (from now on every log message is written to $logFile and $logHistoryFile)
				cp $logFile $logHistoryFile
				break
			else
				echo "Connection failed! Retrying..."
				printf "Connection failed! Retrying...\n" >> $logFile
				nmcli connection down "$mobileConnectionName"
			fi
		fi

		sleep $samplingPeriodSec
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
	printf "%s Network disconnected!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null

	# Stop the VPN and MAVProxy services

	echo "Stopping the VPN service..."
	printf "%s Stopping the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
	service openvpn-autostart stop

	nowTime=$(date +"%T")
	echo "Stopping MAVProxy..."
	printf "%s Stopping MAVProxy...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
	service update-uav-latest-status stop
	service mavproxy-autostart stop
	sleep 2
	nowTime=$(date +"%T")
		
	if [ $auto_switch_to_loiter -eq 1 ]
	then
		echo "Switching to LOITER mode..."
		printf "%s Switching to LOITER mode...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
		/usr/local/bin/chmod_offline.py loiter | tee -a $logFile $logHistoryFile > /dev/null
	else
		echo "Auto switching to LOITER mode is disabled!"
		printf "%s Auto switching to LOITER mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
	fi
			
	nowTime=$(date +"%T")

	if [ $switch_to_RTL_mode_service_started -eq 0 ] && [ $auto_switch_to_rtl -eq 1 ];
	then
		echo "Starting switch to RTL service..."
		printf "%s Starting switch to RTL service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
		service switch-to-rtl start
		switch_to_RTL_mode_service_started=1
	else
		if [ $auto_switch_to_rtl -eq 0 ]
		then
			echo "Auto switching to RTL mode is disabled!"
			printf "%s Auto switching to RTL mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
		fi
	fi

	# TODO: If dynamic gstreamer pipeline is created signal it to stop the streaming branch
	#if [ $camConnected -eq 1 ]
	#then
	#	nowTime=$(date +"%T")
	#	service_gstreamer_stop
	#	echo "GStreamer stopped."
	#	printf "%s GStreamer stopped.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
	#fi

	net_con_count=0

	if [ $wifiNetworkSelected -eq 1 ]
	then
		echo "Attempting to switch to LTE connection mode..."
		printf "\t Attempting to switch to LTE connection mode...\n" | tee -a $logFile $logHistoryFile > /dev/null
	fi
}

# Disable WIFI via GPIO
disable_wifi()
{
	echo "Disabling WIFI..." | tee -a $logFile

	# Check if the GPIO base value has already been configured - if not configure it
	gpio_base_configured=$(grep -i "GPIO_BASE" /etc/default/network-watchdog-setup)
	if [ -z "$gpio_base_configured" ]
	then
    	echo "Configuring GPIO_BASE by examining the file /sys/kernel/debug/gpio ..." | tee -a $logFile

    	# Read the GPIO base value by examining the file /sys/kernel/debug/gpio
    	gpio_base=$(cat /sys/kernel/debug/gpio | grep gpiochip0 | awk -F' ' '{print $3}' | awk -F'-' '{print $1}')

    	# Write the GPIO base value in the network watchdog setup file
    	echo "GPIO_BASE=$gpio_base" | tee -a /etc/default/network-watchdog-setup > /dev/null
	fi

	# Get the GPIO base value
	gpio_base=$(grep -i "GPIO_BASE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
	echo "GPIO base value set to $gpio_base" | tee -a $logFile

	# Calculate the number of the wifi disable GPIO
	wifi_disable_gpio=$((gpio_base+$wifi_disable_gpio_offset))

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

				sleep $samplingPeriodSec
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
	lte_disconnected_after_cam_probing=0
	lte_wait_disconnected_cnt=0
	lte_max_wait_disconnected_cnt=10

	# Wait until the LTE module is connected
	echo "Waiting until the LTE module is connected..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$lteManufacturerName")

    	if [ ! -z "$lteConnected" ]
    	then
        	break
    	fi

    	sleep $samplingPeriodSec
	done

	# LTE module is connected - probe the camera connection
	echo "LTE module is connected. Probing the camera connection..." | tee -a $logFile
	sleep 20
	service gstreamer-camera-probe start

	# Wait to see if the LTE module will be disconnected as a result of the camera probing
	echo "Waiting to see if the LTE module will be disconnected as a result of the camera probing..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$lteManufacturerName")

    	if [ -z "$lteConnected" ]
    	then
			echo "LTE module disconnected!" | tee -a $logFile
			lte_disconnected_after_cam_probing=1
        	break
    	fi

    	lte_wait_disconnected_cnt=$((lte_wait_disconnected_cnt+1))

    	if [ $lte_wait_disconnected_cnt -gt $lte_max_wait_disconnected_cnt ]
    	then
			echo "Wait timeout! LTE is still connected." | tee -a $logFile
        	break
    	fi

    	sleep $samplingPeriodSec
	done

	# Stop camera probing
	echo "Stopping camera probing..." | tee -a $logFile
	service gstreamer-camera-probe stop

	if [ $lte_disconnected_after_cam_probing -eq 0 ]
	then
		return
	fi

	# Wait until the LTE module is reconnected
	echo "Waiting until the LTE module is reconnected..." | tee -a $logFile
	while true
	do
    	lteConnected=$(lsusb | grep -i "$lteManufacturerName")

    	if [ ! -z "$lteConnected" ]
    	then
			# LTE module is connected. Wait for device name...
			lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
			if [ ! -z "$lteDeviceName" ]
			then
				break
			fi
    	fi

    	sleep $samplingPeriodSec
	done

	echo "LTE module is reconnected!" | tee -a $logFile
	#sleep 10
}

### MAIN SCRIPT STARTS HERE ###

# SCRIPT PARAMETERS
Disconnected=0
Reconnecting=1
Connected=2
video_device=$(grep -i capture_dev /etc/default/gstreamer-setup | awk -F'"' '{print $2}')
lteManufacturerName=$(grep -i "LTE_MANUFACTURER_NAME" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
wifiInterfaceName=$(grep -i "WIFI_INTERFACE_NAME" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
wifi_disable_gpio_offset=$(grep -i "WIFI_DISABLE_GPIO_OFFSET" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
disable_wifi_if_lte_net_selected=$(grep -i "DISABLE_WIFI_IF_LTE_NETWORK_IS_SELECTED" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
lteInterfaceName="usb1"
lteInterfaceNameAlt="usb0"
vpnInterfaceName="tun0"
logFile=$(grep -i "LOG_FILE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
logHistoryDir=$(grep -i "LOG_HISTORY_DIR" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
logHistoryFilepathContainer=$(grep -i "LOG_HISTORY_FILEPATH_CONTAINER" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
auto_switch_to_loiter=$(grep -i "AUTO_SWITCH_TO_LOITER" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
auto_switch_to_rtl=$(grep -i "AUTO_SWITCH_TO_RTL" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
set_max_cpu_gpu_emc_clocks=$(grep -i "SET_MAX_CPU_GPU_EMC_CLOCKS" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
armedDisarmedStatusFile=$(grep -i "VEHICLE_ARMED_DISARMED_STATUS_FILE" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
max_net_con_count=15 # Final value of the mobile network connection counter after which a new connection attempt will be made if the mobile network is available
max_vpn_con_count=15 # Final value of the VPN network connection counter after which the VPN service is restarted
max_ip_address_wait_count=10 # Final value of the wait for IP address counter after which the network is disconnected
max_pref_wifi_con_count=10 # Final value of the preffered wifi connection scan counter after which the mobile network is selected
min_wifi_con_name_length=3 # Minimum number of characters in the WIFI connection name
max_wifi_disable_cnt=10 # Final value of the wifi disable count after which wifi disable attemts are canceled
samplingPeriodSec=2 # Time interval in which the network status is re-evaluated, [sec]
media_devices_count=0
logHistoryFileGenerated=0
logHistoryFile=""
lteDeviceName=""
mobileConnectionName=""
mobileInterfaceName=""
vehicle_armed=""
prev_vehicle_armed=""
networkStatus=0
vpn_con_count=0
net_con_count=0
ip_address_wait_count=0
pref_wifi_con_count=0
wifiNetworkSelected=0
lteNetworkSelected=0
switch_to_RTL_mode_service_started=0
hmiDetected=0
camConnected=0
schedule_reboot=0

# Check if the modem power enable type has been configured
modem_power_enable_type_configured=$(grep -i "MODEM_PWR_EN_GPIO_AS_I2C_MUX" /etc/default/modem-watchdog-setup)
if [ -z "$modem_power_enable_type_configured" ]
then
	camera_and_lte_connections_probed=0
else
	# Check if the modem power enable GPIO is configured is an I2C mux GPIO
	modem_pwr_en_gpio_as_i2c_mux=$(grep -i "MODEM_PWR_EN_GPIO_AS_I2C_MUX" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')

	if [ $modem_pwr_en_gpio_as_i2c_mux -eq 1 ]
	then
    	camera_and_lte_connections_probed=0
	else
    	echo "Modem power enable GPIO is NOT configured as an I2C mux GPIO. Camera probing is disabled!"
    	printf "Modem power enable GPIO is NOT configured as an I2C mux GPIO. Camera probing is disabled!\n" >> $logFile
    	camera_and_lte_connections_probed=1
	fi
fi

# Check the vehicle armed/disarmed status file
if [ ! -f $armedDisarmedStatusFile ]
then
	# The vehicle armed/disarmed status file does not exist - create it - the vehicle is initially disarmed
	echo "DISARMED" > $armedDisarmedStatusFile
fi

# Initialize the vehicle armed variables
update_vehicle_armed_status
prev_vehicle_armed=$vehicle_armed

> $logFile # Clear the log file
> $logHistoryFilepathContainer # Clear the log history filepath container
printf "============= INITIALIZING NEW LOG FILE =============\n" >> $logFile
printf "Initializing...\n" >> $logFile
echo "Initializing..."

# Initialize script variables
init_variables

# Check if a keyboard is connected
check_keyboard_connected

# Check if media devices are connected
check_media_devices_connected

# Start camera immediately if detected
camDetected=$(ls /dev/* | grep $video_device)

if [ ! -z "$camDetected" ] && [ $hmiDetected -eq 0 ];
then
	if [ $camera_and_lte_connections_probed -eq 0 ]
	then
		probe_camera_and_lte_connections
		camera_and_lte_connections_probed=1
	fi

	echo "Camera connected. Starting gstreamer..." | tee -a $logFile
	service gstreamer-autostart start
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
			echo "Network interface unavailable!"
			printf "\t Network interface %s unavailable!\n" "$wifiInterfaceName" | tee -a $logFile $logHistoryFile > /dev/null
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
				echo "LTE device name changed to $lteDeviceName!"
				printf "\t LTE device name changed to %s!\n" "$lteDeviceName" | tee -a $logFile $logHistoryFile > /dev/null
			fi
		fi

		# Check if the mobile interface is listed
		interfaceListed=$(nmcli device | grep "$lteDeviceName")
		if [ -z "$interfaceListed" ]
		then
			mobileConnectionState=""
			echo "Network interface unavailable!"
			printf "\t Network interface %s unavailable!\n" "$lteDeviceName" | tee -a $logFile $logHistoryFile > /dev/null
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
		echo "Network disconnected!"

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
			echo "Scanning for connection" "$mobileConnectionName" "..."
			printf "%s Scanning for connection %s...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile > /dev/null
			connectionFound=$(nmcli connection | grep -i -o "$mobileConnectionName")

			if [ ! -z "$connectionFound" ] && [ ! -z "$interfaceListed" ];
			then
				nowTime=$(date +"%T")
				echo "Connetion" "$mobileConnectionName" "found. Attempting connection..."
				printf "%s Connection %s found. Attempting connection...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile > /dev/null
				nmcli connection up "$mobileConnectionName"
				ip_address_wait_timout_occured=0
				net_con_count=0
				sleep $samplingPeriodSec
				continue
			else
				nowTime=$(date +"%T")
				echo "Connetion" "$mobileConnectionName" "not found. Retrying..."
				printf "%s Connection %s not found. Retrying...\n" $nowTime "$mobileConnectionName" | tee -a $logFile $logHistoryFile > /dev/null
			fi

			net_con_count=0
		fi

		# If a wifi connection was selected then switch to LTE connection ------------------
		if [ $wifiNetworkSelected -eq 1 ]
		then
			echo "Check if the LTE module is connected..."
			printf "\t Check if the LTE module is connected...\n" | tee -a $logFile $logHistoryFile > /dev/null
			lteConnected=$(lsusb | grep -i "$lteManufacturerName")

			if [ ! -z "$lteConnected" ]
			then
				# LTE module is connected - get the associated device name
				lteDeviceName=$(nmcli device | grep -m1 gsm | awk -F' ' '{print $1}')
				echo "LTE module" "$lteManufacturerName" "connected. Getting device name..."
				printf "\t LTE module %s connected. Getting device name...\n" "$lteManufacturerName" | tee -a $logFile $logHistoryFile > /dev/null

				if [ -z "$lteDeviceName" ]
				then
					echo "Failed initializing LTE device name. Process restarting..."
					printf "\t Failed initializing LTE device name. Process restarting...\n" | tee -a $logFile $logHistoryFile > /dev/null
					sleep $samplingPeriodSec
					continue
				fi

				echo "LTE module" "$lteManufacturerName" "connected. Device name:" "$lteDeviceName"
				printf "\t LTE module %s connected. Device name: %s.\n" "$lteManufacturerName" "$lteDeviceName" | tee -a $logFile $logHistoryFile > /dev/null

				lteDeviceUnavailable=$(nmcli device | grep "$lteDeviceName" | awk -F' ' '{print $3}' | grep "una")

				if [ ! -z "$lteDeviceUnavailable" ]
				then
					echo "LTE device is not available. Check the SIM card!"
					printf "\t LTE device is not available. Check the SIM card!\n" | tee -a $logFile $logHistoryFile > /dev/null
				else
					# LTE device is available - get the mobile connection name
					mobileConnectionName=$(nmcli -m multiline connection show | grep -m1 -B2 gsm | grep -i name | awk -F':' '{print $2}' | sed -e 's/^[ \t]*//')
					echo "LTE interface name is set to" "$lteInterfaceName"
					printf "\t LTE interface name is set to %s.\n" "$lteInterfaceName" | tee -a $logFile $logHistoryFile > /dev/null
					mobileInterfaceName=$lteInterfaceName
					wifiNetworkSelected=0
					lteNetworkSelected=1
					echo "Preffered mobile connection" "$mobileConnectionName" "found!"
					printf "\t Preffered mobile connection %s found!\n" "$mobileConnectionName" | tee -a $logFile $logHistoryFile > /dev/null
					net_con_count=$max_net_con_count
				fi
			else
				echo "LTE module is not connected!"
				printf "\t LTE module is not connected!\n" | tee -a $logFile $logHistoryFile > /dev/null
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
			echo "Network interface unavailable!"
			printf "\t Network interface %s unavailable!\n" "$networkInterfaceUnavailableName" | tee -a $logFile $logHistoryFile > /dev/null
			net_con_count=$max_net_con_count
			sleep $samplingPeriodSec
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
					echo "Waiting for IP address..."
					printf "\t Waiting for IP address...\n" | tee -a $logFile $logHistoryFile > /dev/null
					ip_address_wait_count=$((ip_address_wait_count+1))

					if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
					then
						echo "Waiting for IP address timeout. Disconnecting from network..."
						printf "\t Waiting for IP address timeout. Disconnecting from network...\n" | tee -a $logFile $logHistoryFile > /dev/null
						network_disconnect
						process_network_just_disconnected
						networkStatus=$Disconnected
						ip_address_wait_timout_occured=1
					fi

					sleep $samplingPeriodSec
					continue
				else
					# Switch the LTE interface name
					mobileInterfaceName=$lteInterfaceNameAlt
					echo "LTE interface name switched from" "$lteInterfaceName" "to" "$lteInterfaceNameAlt"
					printf "\t LTE interface name switched from %s to %s.\n" "$lteInterfaceName" "$lteInterfaceNameAlt" | tee -a $logFile $logHistoryFile > /dev/null

					# Swap the main and alternative LTE interfaces 
					lteInterfaceNameAlt=$lteInterfaceName
					lteInterfaceName=$mobileInterfaceName
				fi
			else
				echo "Waiting for IP address..."
				printf "\t Waiting for IP address...\n" | tee -a $logFile $logHistoryFile > /dev/null
				ip_address_wait_count=$((ip_address_wait_count+1))

				if [ $ip_address_wait_count -gt $max_ip_address_wait_count ]
				then
					echo "Waiting for IP address timeout. Disconnecting from network..."
					printf "\t Waiting for IP address timeout. Disconnecting from network...\n" | tee -a $logFile $logHistoryFile > /dev/null
					network_disconnect
					process_network_just_disconnected
					networkStatus=$Disconnected
					ip_address_wait_timout_occured=1
				fi

				sleep $samplingPeriodSec
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
				echo "Wifi interface set to $wifiInterfaceName"
				printf "\t Wifi interface set to %s\n" $wifiInterfaceName | tee -a $logFile $logHistoryFile > /dev/null
			fi

			nowTime=$(date +"%T")
			echo "Network is now connected!" "Mobile IP:" "$mobileIpAddress"
			echo "Starting the VPN service..."
			printf "%s Network is now connected! Mobile IP: %s\n" $nowTime $mobileIpAddress | tee -a $logFile $logHistoryFile > /dev/null
			printf "%s Starting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null

			service openvpn-autostart start
			networkStatus=$Reconnecting
			vpn_con_count=0
		fi

		# Get the IP address associated with the VPN network interface
		vpnIpAddress=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'/' '{print $1}')

		if [ -z "$vpnIpAddress" ]
		then
			# No VPN IP address found - VPN is still connecting
			if [ $networkStatus -ne $Reconnecting ]
			then
				nowTime=$(date +"%T")

				# The VPN service is restarted when VPN connection is lost without losing mobile network connectivity
				networkStatus=$Reconnecting
				echo "VPN connection lost."
				echo "Stopping MAVProxy..."
				printf "%s VPN connection lost. Stopping MAVProxy...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null

				service update-uav-latest-status stop
				service mavproxy-autostart stop
				sleep 2
				nowTime=$(date +"%T")

				if [ $auto_switch_to_loiter -eq 1 ]
				then
					echo "Switching to LOITER mode..."
					printf "%s Switching to LOITER mode...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					/usr/local/bin/chmod_offline.py loiter | tee -a $logFile $logHistoryFile > /dev/null
				else
					echo "Auto switching to LOITER mode is disabled!"
					printf "%s Auto switching to LOITER mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
				fi

				nowTime=$(date +"%T")

				if [ $switch_to_RTL_mode_service_started -eq 0 ] && [ $auto_switch_to_rtl -eq 1 ];
				then
					echo "Starting switch to RTL service..."
					printf "%s Starting switch to RTL service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					service switch-to-rtl start
					switch_to_RTL_mode_service_started=1
				else
					if [ $auto_switch_to_rtl -eq 0 ]
					then
						echo "Auto switching to RTL mode is disabled!"
						printf "%s Auto switching to RTL mode is disabled!\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					fi
				fi

				# TODO: If dynamic gstreamer pipeline is created signal it to stop the streaming branch
				#if [ $camConnected -eq 1 ]
				#then
				#	nowTime=$(date +"%T")
				#	service_gstreamer_stop
				#	echo "GStreamer stopped."
				#	printf "%s GStreamer stopped.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
				#fi

				nowTime=$(date +"%T")
				echo "Restarting the VPN service..."
				printf "%s Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi

			echo "Connecting to VPN..."

			vpn_con_count=$((vpn_con_count+1))
			if [ $vpn_con_count -gt $max_vpn_con_count ]
			then
				nowTime=$(date +"%T")
				echo "Restarting the VPN service..."
				printf "%s Connection timeout. Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
				service openvpn-autostart stop
				sleep 2
				service openvpn-autostart start
				vpn_con_count=0
			fi
		else
			# VPN IP address found - get the first two octets and check the values
			oct1=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $1}')
			oct2=$(ip address show | grep -A2 $vpnInterfaceName | grep "inet " | awk -F' ' '{print $2}' | awk -F'.' '{print $2}')

			if [ $oct1 -eq 192 ] && [ $oct2 -eq 168 ];
			then
				echo "VPN connected!" "VPN IP:" "$vpnIpAddress" "Mobile IP:" "$mobileIpAddress"

				if [ $networkStatus -ne $Connected ]
				then
					nowTime=$(date +"%T")
					printf "%s VPN connected! VPN IP: %s Mobile IP: %s\n" $nowTime $vpnIpAddress $mobileIpAddress | tee -a $logFile $logHistoryFile > /dev/null
					networkStatus=$Connected
					echo "Starting MAVProxy..."
					printf "%s Starting MAVProxy...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					service mavproxy-autostart start

					if [ $? -eq 0 ]
					then
						nowTime=$(date +"%T")
						echo "MAVProxy started."
						printf "%s MAVProxy started.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null

						if [ $switch_to_RTL_mode_service_started -eq 1 ] && [ $auto_switch_to_rtl -eq 1 ];
						then
							nowTime=$(date +"%T")
							echo "Stopping switch to RTL service."
							printf "%s Stopping switch to RTL service.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
							service switch-to-rtl stop
							switch_to_RTL_mode_service_started=0
						fi

						service update-uav-latest-status start
						nowTime=$(date +"%T")
						echo "Started UAV status update service."
						printf "%s Started UAV status update service.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					else
						nowTime=$(date +"%T")
						echo "MAVProxy starting failed. Restarting..."
						printf "%s MAVProxy starting failed. Restarting...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
						service mavproxy-autostart stop
						networkStatus=$Reconnecting
					fi
					
					# TODO: If dynamic gstreamer pipeline is created signal it to start the streaming branch 
					#if [ $camConnected -eq 1 ]
					#then
					#	service gstreamer-autostart start
					#	nowTime=$(date +"%T")
					#	echo "GStreamer started."
					#	printf "%s GStreamer started.\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null
					#fi
				fi
			else
				nowTime=$(date +"%T")
				echo "Error! VPN connected but IP address invalid. Restarting the VPN service..."
				printf "%s Error! VPN connected but IP address invalid. Restarting the VPN service...\n" $nowTime | tee -a $logFile $logHistoryFile > /dev/null

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
	cp $logFile /var/www/html/network-watchdog

	sleep $samplingPeriodSec
done
