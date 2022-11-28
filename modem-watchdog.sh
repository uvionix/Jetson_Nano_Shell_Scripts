#!/bin/bash

# Initialization in the case where the modem power enable GPIO is configured as a regular GPIO
initialize_case_regular_pwr_en_gpio()
{
    regular_gpioNumber="gpio$modem_pwr_en_gpio"
    echo "Exporting GPIO $modem_pwr_en_gpio ..."
    printf "Exporting GPIO %s ...\n" $modem_pwr_en_gpio >> $logFile
    gpio_exported=$(ls /sys/class/gpio/ | grep "$regular_gpioNumber" )
    
    if [ ! -z "$gpio_exported" ]
    then
        echo "GPIO $modem_pwr_en_gpio was already exported!"
        printf "GPIO %s was already exported!\n" $modem_pwr_en_gpio >> $logFile
    else
        echo $modem_pwr_en_gpio > /sys/class/gpio/export
    fi

    if [ $? -eq 0 ]
    then
        echo "Exporting successful!"
        echo "Configuring GPIO $modem_pwr_en_gpio as output..."
        printf "Exporting successful!\n" >> $logFile
        printf "Configuring GPIO %s as output...\n" $modem_pwr_en_gpio >> $logFile

        configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

        while true
        do
            if [ ! -z "$configured_direction_out" ]
            then
                echo "GPIO $modem_pwr_en_gpio was already configured as output!"
                printf "GPIO %s was already configured as output!\n" $modem_pwr_en_gpio >> $logFile
            else
                echo out > /sys/class/gpio/$regular_gpioNumber/direction
            fi

            if [ $? -eq 0 ]
            then
                configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

                if [ ! -z "$configured_direction_out" ]
                then
                    echo "GPIO $modem_pwr_en_gpio was configured as output successfuly! Initialization successful!"
                    printf "GPIO %s was configured as output successfuly! Initialization successful!\n" $modem_pwr_en_gpio >> $logFile
                    initializationSuccessful=1
                    pwr_on_of_method=$PWR_ON_OFF_METHOD_REGULAR_GPIO
                    break
                else
                    echo "Configuring GPIO $modem_pwr_en_gpio as output failed! Retrying..."
                    printf "Configuring GPIO %s as output failed! Retrying...\n" $modem_pwr_en_gpio >> $logFile
                fi
            else
                echo "Configuring GPIO $modem_pwr_en_gpio as output failed!"
                printf "Configuring GPIO %s as output failed!\n" $modem_pwr_en_gpio >> $logFile
                break
            fi
        done
    else
        echo "Exporting unsuccessful!"
        printf "Exporting unsuccessful!\n" >> $logFile
    fi
}

# Initialization in the case where the modem power enable GPIO is configured as an I2C mux GPIO
initialize_case_i2c_mux_pwr_en_gpio()
{
    echo "I2C bus identifier set to $i2c_bus_identifier"
    printf "I2C bus identifier set to %s\n" $i2c_bus_identifier >> $logFile

    # Get the I2C bus to select when the modem has to be powered on
    i2cBusPwrOn=$(i2cdetect -l | grep $i2c_bus_identifier | grep "chan_id 1" | awk -F' ' '{print $1}' | awk -F'-' '{print $2}')

    if [ ! -z "$i2cBusPwrOn" ]
    then
        echo "Modem power ON I2C bus set to i2c-$i2cBusPwrOn"
        printf "Modem power ON I2C bus set to i2c-%s\n" $i2cBusPwrOn >> $logFile

        # Get the I2C bus to select when the modem has to be powered off
        i2cBusPwrOff=$(i2cdetect -l | grep $i2c_bus_identifier | grep "chan_id 0" | awk -F' ' '{print $1}' | awk -F'-' '{print $2}')

        if [ ! -z "$i2cBusPwrOff" ]
        then
            echo "Modem power OFF I2C bus set to i2c-$i2cBusPwrOff"
            printf "Modem power OFF I2C bus set to i2c-%s\n" $i2cBusPwrOff >> $logFile
            printf "Initialization successful!\n" >> $logFile
            initializationSuccessful=1
            pwr_on_of_method=$PWR_ON_OFF_METHOD_I2C
        else
            echo "Error initializing the I2C bus to select when the modem has to be powered off!"
            printf "Error initializing the I2C bus to select when the modem has to be powered off!\n" >> $logFile
        fi
    else
        echo "Error initializing the I2C bus to select when the modem has to be powered on!"
        printf "Error initializing the I2C bus to select when the modem has to be powered on!\n" >> $logFile
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
logFile=$(grep -i "LOG_FILE" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
modemManufacturerName=$(grep -i "LTE_MANUFACTURER_NAME" /etc/default/network-watchdog-setup | awk -F'=' '{print $2}')
pwr_en_gpio_offset=$(grep -i "PWR_EN_GPIO_OFFSET" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
i2c_bus_identifier=$(grep -i "PWR_ON_OFF_I2C_BUS_IDENTIFIER" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
InitPowerOnDelayTimeSec=$(grep -i "PWR_ON_DELAY_SEC" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
InitWaitAfterPowerOnSec=$(grep -i "WAIT_AFTER_PWR_ON_SEC" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
waitTimeIncrementSec=$(grep -i "WAIT_INCREMENT_SEC" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
samplingPeriodSec=$(grep -i "SAMPLE_TIME_SEC" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
serviceStartDelaySec=$(grep -i "SERVICE_START_DELAY_SEC" /etc/default/modem-watchdog-setup | awk -F'=' '{print $2}')
powerOnDelayTimeSec=$InitPowerOnDelayTimeSec # Power on delay after the power to the modem has been switched off, [sec]
waitAfterPowerOnSec=$InitWaitAfterPowerOnSec # Wait time after the modem has been powered on before its status is re-evaluated, [sec]
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
echo "Initializing..."
printf "Initializing...\n" >> $logFile
sleep $serviceStartDelaySec
echo "Modem manufacturer name set to $modemManufacturerName"
echo "Power enable GPIO offset set to $pwr_en_gpio_offset"
printf "Modem manufacturer name set to %s\n" $modemManufacturerName >> $logFile
printf "Power enable GPIO offset set to %s\n" $pwr_en_gpio_offset >> $logFile

# Get the GPIO base value
echo "Getting GPIO base value..."
printf "Getting GPIO base value...\n" >> $logFile
gpio_base=$(cat /sys/kernel/debug/gpio | grep gpiochip0 | awk -F' ' '{print $3}' | awk -F'-' '{print $1}')
echo "GPIO base value set to $gpio_base"
printf "GPIO base value set to %s\n" $gpio_base >> $logFile

# Calculate the number of the modem power enable GPIO
modem_pwr_en_gpio=$((gpio_base+$pwr_en_gpio_offset))
echo "Modem power enable GPIO sysfs value set to $modem_pwr_en_gpio"
printf "Modem power enable GPIO sysfs value set to %s\n" $modem_pwr_en_gpio >> $logFile

# Check if the modem power enable GPIO is configured is an I2C mux GPIO
modem_pwr_en_gpio_as_i2c_mux=$(cat /sys/kernel/debug/gpio | grep "gpio-$modem_pwr_en_gpio" | grep "i2c-mux-gpio")
if [ ! -z "$modem_pwr_en_gpio_as_i2c_mux" ]
then
    echo "Modem power enable GPIO is configured as an I2C mux GPIO! Initializing related parameters..."
    printf "Modem power enable GPIO is configured as an I2C mux GPIO! Initializing related parameters...\n" >> $logFile
    initialize_case_i2c_mux_pwr_en_gpio
else
    # Check if the modem power enable GPIO is configured is a regular GPIO
    modem_pwr_en_gpio_as_regular_GPIO=$(cat /sys/kernel/debug/gpio | grep "gpio-$modem_pwr_en_gpio" | grep "GPIO06")
    if [ ! -z "$modem_pwr_en_gpio_as_regular_GPIO" ]
    then
        echo "Modem power enable GPIO is configured as a regular GPIO!"
        printf "Modem power enable GPIO is configured as a regular GPIO!\n" >> $logFile
        initialize_case_regular_pwr_en_gpio
    else
        echo "Unknown modem power enable GPIO configuration! Attempting initialization with regular GPIO configuration..."
        printf "Unknown modem power enable GPIO configuration! Attempting initialization with regular GPIO configuration...\n" >> $logFile
        initialize_case_regular_pwr_en_gpio
    fi
fi

# Main watchdog loop
while [ $initializationSuccessful -eq 1 ]
do
    # Check if the modem is connected
    modemConnected=$(lsusb | grep -i "$modemManufacturerName")

    if [ ! -z "$modemConnected" ]
    then
        # Modem is connected
        echo "Modem connected!"

        if [ $boolModemConnected -eq 0 ]
        then
            boolModemConnected=1
            printf "Modem connected! Power on wait time = %d sec\n" $lastPowerOnDelayTimeSec >> $logFile
            printf "Waiting for status from modem manager...\n" >> $logFile
            powerOnDelayTimeSec=$InitPowerOnDelayTimeSec
            waitAfterPowerOnSec=$InitWaitAfterPowerOnSec
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
                printf "Modem connected! Modem model: %s; Modem path: %s\n" $modemModel $modemPath >> $logFile
            fi

            modemStatus=$(mmcli -m $modemPath | grep -i -m1 -A3 "state" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g")
            echo $modemStatus >> $logFile
        fi
    else
        # Modem is not connected
        boolModemConnected=0
        boolStatusAquired=0
        modemPath=$(mmcli -L | grep -i "$modemManufacturerName" | awk -F' ' '{print $1}') # This line will empty the variable
        echo "Modem is not connected - attempting power cycle..."
        printf "Modem is not connected - attempting power cycle...\n" >> $logFile
        echo "Powering OFF..."
        printf "Powering OFF...\n" >> $logFile

        modem_pwr_off

        sleep $powerOnDelayTimeSec
        echo "Powering ON..."
        printf "Powering ON...\n" >> $logFile

        modem_pwr_on

        sleep $waitAfterPowerOnSec
        echo "Now checking if the modem is connected..."
        printf "Now checking if the modem is connected...\n" >> $logFile
        lastPowerOnDelayTimeSec=$powerOnDelayTimeSec
        powerOnDelayTimeSec=$((powerOnDelayTimeSec+$waitTimeIncrementSec))
        waitAfterPowerOnSec=$((waitAfterPowerOnSec+$waitTimeIncrementSec))
    fi

    sleep $samplingPeriodSec
done
