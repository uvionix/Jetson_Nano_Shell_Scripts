#!/bin/bash

# Get the FPS parameter
fps=$1

# Get the resolution parameter
res=$2

# Get the capture device parameter
dev=$3

# Get the container parameter
container=$4

# Get the file duration
file_duration=$5

# Get a username
usr=$(getent passwd | awk -F: "{if (\$3 >= $(awk '/^UID_MIN/ {print $2}' /etc/login.defs) && \$3 <= $(awk '/^UID_MAX/ {print $2}' /etc/login.defs)) print \$1}" | head -1)

# Get the current date
nowDate=$(date +"%b-%d-%y")

# Create the Videos directory if it does not exist
mkdir /home/$usr/Videos

# Create a directory for the current date
mkdir /home/$usr/Videos/$nowDate
chown $usr /home/$usr/Videos/$nowDate

while true
do
    # Get a filename
    file_cnt=1
    while true
    do
        filename="vid-$file_cnt.$container"
        file_exists=$(ls /home/$usr/Videos/$nowDate | grep -o $filename)

        if [ ! -z "$file_exists" ]
        then
            file_cnt=$((file_cnt+1))
        else
            break
        fi
    done

    # Start recording
    /usr/bin/ffmpeg -f v4l2 -s $res -input_format mjpeg -i $dev -r $fps -c:v libx264 -preset superfast -t $file_duration /home/$usr/Videos/$nowDate/$filename -y
    chown $usr /home/$usr/Videos/$nowDate/$filename
    echo "Recording ended. Starting new file..."
done
