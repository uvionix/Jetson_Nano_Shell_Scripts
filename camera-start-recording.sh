#!/bin/bash

# Get the FPS parameters
fps_in=$1
fps_out=$2

# Get the resolution parameter
res=$3

# Get the capture device parameter
dev=$4

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
        filename="vid-$file_cnt.mkv"
        file_exists=$(ls /home/$usr/Videos/$nowDate | grep -o $filename)

        if [ ! -z "$file_exists" ]
        then
            file_cnt=$((file_cnt+1))
        else
            break
        fi
    done

    # Start recording
    # /usr/bin/ffmpeg -f v4l2 -r $fps -s $res -input_format mjpeg -i $dev -t 180 /home/$usr/Videos/$nowDate/$filename -async 1 -vsync 1 -y
    /usr/bin/ffmpeg -f v4l2 -r $fps_in -s $res -input_format mjpeg -i $dev -r $fps_out -t 180 /home/$usr/Videos/$nowDate/$filename -vsync 1 -y
    chown $usr /home/$usr/Videos/$nowDate/$filename
    echo "Recording ended. Starting new file..."
done
