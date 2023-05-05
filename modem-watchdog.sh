#!/bin/bash

# Initialization in the case where the modem power enable GPIO is configured as a regular GPIO
initialize_case_regular_pwr_en_gpio()
{
    regular_gpioNumber="gpio$modem_pwr_en_gpio"
    echo "Exporting GPIO $modem_pwr_en_gpio ..." | tee -a $logFile
    gpio_exported=$(ls /sys/class/gpio/ | grep "$regular_gpioNumber" )
    
    if [ ! -z "$gpio_exported" ]
    then
        echo "GPIO $modem_pwr_en_gpio was already exported!" | tee -a $logFile
    else
        echo $modem_pwr_en_gpio > /sys/class/gpio/export
    fi

    if [ $? -eq 0 ]
    then
        echo "Exporting successful!" | tee -a $logFile
        echo "Configuring GPIO $modem_pwr_en_gpio as output..." | tee -a $logFile

        configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

        while true
        do
            if [ ! -z "$configured_direction_out" ]
            then
                echo "GPIO $modem_pwr_en_gpio was already configured as output!" | tee -a $logFile
            else
                echo out > /sys/class/gpio/$regular_gpioNumber/direction
            fi

            if [ $? -eq 0 ]
            then
                configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

                if [ ! -z "$configured_direction_out" ]
                then
                    echo "GPIO $modem_pwr_en_gpio was configured as output successfuly! Initialization successful!" | tee -a $logFile
                    initializationSuccessful=1
                    pwr_on_of_method=$PWR_ON_OFF_METHOD_REGULAR_GPIO

                    gpio_value=$(cat /sys/class/gpio/$regular_gpioNumber/value)
                    if [ $gpio_value -eq 0 ]
                    then
                        echo "Modem power is disabled. Powering ON..." | tee -a $logFile
                        echo 1 > /sys/class/gpio/$regular_gpioNumber/value
                        sleep $waitAfterPowerOnSec
                    fi

                    break
                else
                    echo "Configuring GPIO $modem_pwr_en_gpio as output failed! Retrying..." | tee -a $logFile
                fi
            else
                echo "Configuring GPIO $modem_pwr_en_gpio as output failed!" | tee -a $logFile
                break
            fi
        done
    else
        echo "Exporting unsuccessful!" | tee -a $logFile
    fi
}

# Initialization in the case where the modem power enable GPIO is configured as an I2C mux GPIO
initialize_case_i2c_mux_pwr_en_gpio()
{
    echo "I2C bus identifier set to $PWR_ON_OFF_I2C_BUS_IDENTIFIER" | tee -a $logFile

    # Get the I2C bus to select when the modem has to be powered on
    i2cBusPwrOn=$(i2cdetect -l | grep $PWR_ON_OFF_I2C_BUS_IDENTIFIER | grep "chan_id 1" | awk -F' ' '{print $1}' | awk -F'-' '{print $2}')

    if [ ! -z "$i2cBusPwrOn" ]
    then
        echo "Modem power ON I2C bus set to i2c-$i2cBusPwrOn" | tee -a $logFile

        # Get the I2C bus to select when the modem has to be powered off
        i2cBusPwrOff=$(i2cdetect -l | grep $PWR_ON_OFF_I2C_BUS_IDENTIFIER | grep "chan_id 0" | awk -F' ' '{print $1}' | awk -F'-' '{print $2}')

        if [ ! -z "$i2cBusPwrOff" ]
        then
            echo "Modem power OFF I2C bus set to i2c-$i2cBusPwrOff" | tee -a $logFile
            echo "Initialization successful!" | tee -a $logFile
            initializationSuccessful=1
            pwr_on_of_method=$PWR_ON_OFF_METHOD_I2C
        else
            echo "Error initializing the I2C bus to select when the modem has to be powered off!" | tee -a $logFile
        fi
    else
        echo "Error initializing the I2C bus to select when the modem has to be powered on!" | tee -a $logFile
    fi
}

# Modem power ON
modem_pwr_on()
{
    case $pwr_on_of_method in
    $PWR_ON_OFF_METHOD_I2C)
        i2cdetect -y $i2cBusPwrOn
        ;;

    $PWR_ON_OFF_METHOD_REGULAR_GPIO)
        echo 1 > /sys/class/gpio/$regular_gpioNumber/value
        ;;
    esac
}

# Modem power OFF
modem_pwr_off()
{
    case $pwr_on_of_method in
    $PWR_ON_OFF_METHOD_I2C)
        i2cdetect -y $i2cBusPwrOff
        ;;

    $PWR_ON_OFF_METHOD_REGULAR_GPIO)
        echo 0 > /sys/class/gpio/$regular_gpioNumber/value
        ;;
    esac
}

### MAIN SCRIPT STARTS HERE ###

# Methods for powering the modem on/off
PWR_ON_OFF_METHOD_I2C=0
PWR_ON_OFF_METHOD_REGULAR_GPIO=1

# SCRIPT PARAMETERS
setup_file=$(grep -i EnvironmentFile /etc/systemd/system/modem-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
nw_setup_file=$(grep -i EnvironmentFile /etc/systemd/system/network-watchdog.service | awk -F'=' '{print $2}' | sed s/'\s'//g)
modemManufacturerName=$(grep -iw "LTE_MANUFACTURER_NAME" $nw_setup_file | awk -F'"' '{print $2}')
logFile=$LOG_FILE
powerOnDelayTimeSec=$PWR_ON_DELAY_SEC # Power on delay after the power to the modem has been switched off, [sec]
waitAfterPowerOnSec=$WAIT_AFTER_PWR_ON_SEC # Wait time after the modem has been powered on before its status is re-evaluated, [sec]
lastPowerOnDelayTimeSec=$powerOnDelayTimeSec
initializationSuccessful=0
boolModemConnected=0
boolStatusAquired=0
modemPath=""
modemModel=""
regular_gpioNumber=""
pwr_on_of_method=$PWR_ON_OFF_METHOD_I2C

# INITIALIZATION

> $logFile # Clear the log file
printf "============= INITIALIZING NEW LOG FILE =============\n" >> $logFile
echo "Initializing..." | tee -a $logFile

sleep $SERVICE_START_DELAY_SEC
echo "Modem manufacturer name set to $modemManufacturerName" | tee -a $logFile
echo "Power enable GPIO offset set to $PWR_EN_GPIO_OFFSET" | tee -a $logFile

# Check if the GPIO base value has already been configured - if not configure it
gpio_base_configured=$(grep -iw "GPIO_BASE" $setup_file)
if [ -z "$gpio_base_configured" ]
then
    echo "Configuring GPIO_BASE by examining the file /sys/kernel/debug/gpio ..." | tee -a $logFile

    # Read the GPIO base value by examining the file /sys/kernel/debug/gpio
    gpio_base=$(cat /sys/kernel/debug/gpio | grep gpiochip0 | awk -F' ' '{print $3}' | awk -F'-' '{print $1}')

    # Write the GPIO base value in the modem watchdog setup file
    echo "GPIO_BASE=$gpio_base" >> $setup_file
fi

# Get the GPIO base value
gpio_base=$(grep -iw "GPIO_BASE" $setup_file | awk -F'=' '{print $2}')
echo "GPIO base value set to $gpio_base" | tee -a $logFile

# Calculate the number of the modem power enable GPIO
modem_pwr_en_gpio=$((gpio_base+$PWR_EN_GPIO_OFFSET))
echo "Modem power enable GPIO sysfs value set to $modem_pwr_en_gpio" | tee -a $logFile

# Check if the modem power enable type has already been configured - if not configure it
modem_power_enable_type_configured=$(grep -iw "MODEM_PWR_EN_GPIO_AS_I2C_MUX" $setup_file)
if [ -z "$modem_power_enable_type_configured" ]
then
    echo "Configuring the modem power enable GPIO configuration type by examining the file /sys/kernel/debug/gpio ..." | tee -a $logFile

    # Determine if the modem power enable is configured as an I2C mux GPIO by examining the file /sys/kernel/debug/gpio
    pwr_en_gpio_as_i2c_mux=$(cat /sys/kernel/debug/gpio | grep "gpio-$modem_pwr_en_gpio" | grep "i2c-mux-gpio")

    if [ ! -z "$pwr_en_gpio_as_i2c_mux" ]
    then
        # The modem power enable is configured as an I2C mux GPIO
        echo "MODEM_PWR_EN_GPIO_AS_I2C_MUX=1" >> $setup_file
    else
        # The modem power enable is configured as a regular GPIO or in some other way
        echo "MODEM_PWR_EN_GPIO_AS_I2C_MUX=0" >> $setup_file
    fi
fi

# Check if the modem power enable GPIO is configured is an I2C mux GPIO
modem_pwr_en_gpio_as_i2c_mux=$(grep -iw "MODEM_PWR_EN_GPIO_AS_I2C_MUX" $setup_file | awk -F'=' '{print $2}')

if [ $modem_pwr_en_gpio_as_i2c_mux -eq 1 ]
then
    echo "Modem power enable GPIO is configured as an I2C mux GPIO! Initializing related parameters..." | tee -a $logFile
    initialize_case_i2c_mux_pwr_en_gpio
else
    echo "Modem power enable GPIO is configured as a regular GPIO! Initializing related parameters..." | tee -a $logFile
    initialize_case_regular_pwr_en_gpio
fi

# Main watchdog loop
while [ $initializationSuccessful -eq 1 ]
do
    # Check if the modem is connected
    modemConnected=$(lsusb | grep -i "$modemManufacturerName")

    if [ ! -z "$modemConnected" ]
    then
        # Modem is connected
        if [ $boolModemConnected -eq 0 ]
        then
            boolModemConnected=1
            #printf "Modem connected! Power on wait time = %d sec\n" $lastPowerOnDelayTimeSec >> $logFile
            echo "Modem connected! Waiting for status from modem manager..." | tee -a $logFile
            powerOnDelayTimeSec=$PWR_ON_DELAY_SEC
            waitAfterPowerOnSec=$WAIT_AFTER_PWR_ON_SEC
        fi

        if [ -z "$modemPath" ]
        then
            modemPath=$(mmcli -L | grep -i "$modemManufacturerName" | awk -F' ' '{print $1}')
        fi

        if [ ! -z "$modemPath" ]
        then
            if [ $boolStatusAquired -eq 0 ]
            then
                boolStatusAquired=1
                modemModel=$(mmcli -L | grep -i "$modemManufacturerName" | awk -F' ' '{print $3}')
                echo "Modem connected! Modem model: $modemModel; Modem path: $modemPath" | tee -a $logFile
            fi

            modemStatus=$(mmcli -m $modemPath | grep -i -m1 -A3 "state" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g")
            echo $modemStatus >> $logFile
        fi
    else
        # Modem is not connected
        boolModemConnected=0
        boolStatusAquired=0
        modemPath=$(mmcli -L | grep -i "$modemManufacturerName" | awk -F' ' '{print $1}') # This line will empty the variable
        echo "Modem is not connected - attempting power cycle..." | tee -a $logFile
        echo "Powering OFF..." | tee -a $logFile

        modem_pwr_off

        sleep $powerOnDelayTimeSec
        echo "Powering ON..." | tee -a $logFile

        modem_pwr_on

        sleep $waitAfterPowerOnSec
        echo "Now checking if the modem is connected..." | tee -a $logFile
        lastPowerOnDelayTimeSec=$powerOnDelayTimeSec
        powerOnDelayTimeSec=$((powerOnDelayTimeSec+$WAIT_INCREMENT_SEC))
        waitAfterPowerOnSec=$((waitAfterPowerOnSec+$WAIT_INCREMENT_SEC))
    fi

    # Copy the current log file within the XOSS webpage root directory
    cp $logFile $WEBPAGE_MW_LOG_FILE
    tail -1 $logFile > $WEBPAGE_MW_STATUS_FILE

    sleep $SAMPLE_TIME_SEC
done
