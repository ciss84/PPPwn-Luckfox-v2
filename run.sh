#!/bin/sh

read_json() {
  local key=$1
  awk -F"[,:}]" '/"'$key'"/{gsub(/"/, "", $2); print $2}' $CONFIG_FILE | tr -d ' '
}

# Define the path to the configuration file
CONFIG_FILE="/etc/pppwn/config.json"

# Read configuration values from config.json
FW_VERSION=$(read_json 'FW_VERSION')
TIMEOUT=$(read_json 'TIMEOUT')
WAIT_AFTER_PIN=$(read_json 'WAIT_AFTER_PIN')
GROOM_DELAY=$(read_json 'GROOM_DELAY')
BUFFER_SIZE=$(read_json 'BUFFER_SIZE')
AUTO_RETRY=$(read_json 'AUTO_RETRY')
NO_WAIT_PADI=$(read_json 'NO_WAIT_PADI')
REAL_SLEEP=$(read_json 'REAL_SLEEP')
AUTO_START=$(read_json 'AUTO_START')
HALT_CHOICE=$(read_json 'HALT_CHOICE')
PPPWN_EXEC=$(read_json 'PPPWN_EXEC')
DIR=$(read_json 'install_dir')
LOG_FILE=$(read_json 'log_file')
EN_NET=$(read_json 'en_inet')
RESTMODE=$(read_json 'RESTMODE');
PPPOE_WAIT=$(read_json 'PPPOE_WAIT');

STAGE1_FILE="$DIR/stage1/${FW_VERSION}/stage1.bin"
STAGE2_FILE="$DIR/stage2/${FW_VERSION}/stage2.bin"

CMD="$DIR/$PPPWN_EXEC --interface eth0 --fw $FW_VERSION --stage1 $STAGE1_FILE --stage2 $STAGE2_FILE"

# Append optional parameters
[ "$TIMEOUT" != "null" ] && CMD="$CMD --timeout $TIMEOUT"
[ "$WAIT_AFTER_PIN" != "null" ] && CMD="$CMD --wait-after-pin $WAIT_AFTER_PIN"
[ "$GROOM_DELAY" != "null" ] && CMD="$CMD --groom-delay $GROOM_DELAY"
[ "$BUFFER_SIZE" != "null" ] && CMD="$CMD --buffer-size $BUFFER_SIZE"
[ "$AUTO_RETRY" == "true" ] && CMD="$CMD --auto-retry"
[ "$NO_WAIT_PADI" == "true" ] && CMD="$CMD --no-wait-padi"
[ "$REAL_SLEEP" == "true" ] && CMD="$CMD --real-sleep"

start_internet() {
  echo "Bringing up wlan0..."
  ifconfig wlan0 up
  wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
  udhcpc -i wlan0
  echo "Setting up bridge between eth0 and wlan0..."
  brctl addbr br0
  brctl addif br0 eth0
  brctl addif br0 wlan0
  ifconfig br0 up
  udhcpc -i br0
}
kill_net() {
  ifconfig eth0 down
  ifconfig wlan0 down
  ifconfig br0 down
  brctl delbr br0
}

ifdown() {
    printf "Shutting down interface eth0... "
    ip link set eth0 down
    [ $? = 0 ] && echo "OK" || echo "FAIL"
}

ifup() {
    ip link show eth0 | grep -q "UP"
    [ $? = 0 ] && return
    printf "Bringing up interface eth0... "
    ip link set eth0 up
    [ $? = 0 ] && echo "OK" || echo "FAIL"
}

kill_services() {
	#Stop pppoe server, nginx, php-fpm and any running pppwn
	printf "Stopping services... "
	SERVICE_PIDS=`pidof pppoe pppoe-server php-fpm nginx pppwn1 pppwn2 pppwn3`
	[ "$SERVICE_PIDS" != "" ] && (kill -9 $SERVICE_PIDS && echo "OK" || echo "FAIL") || echo "NOT RUNNING"
}

execute_pppwn() {
    stop
    ifup
    if [ "$RESTMODE" = "true" -o "$PPPOE_WAIT" = "true" ]; then
		# Wait for PPPoE if needed
		wait_for_pppoe
		if [ "$RESTMODE" = "true" ]; then
			# Check if GoldHen is running
			check_status
			check_status_net
			if [ $? -eq 0 ]; then
				printf "GoldHen is running, Skipping PPPwn...\n"
			else
				printf "GoldHen is not running, Starting PPPwn...\n"
        stop
        ifup
				$CMD
			fi
		else
			# If RESTMODE is not true, proceed with PPPwn
			printf "Executing PPPwn...\n"
      stop
      ifup
			$CMD
		fi
	else
		# If neither RESTMODE nor PPPOE_WAIT is true, execute PPPwn directly
		printf "Executing PPPwn...\n"
    stop
    ifup
		$CMD
  fi
	restart_services
}

wait_for_pppoe() {
    IP="42.42.42.42"
    MAX_ATTEMPTS=20  # Maximum number of iterations

    printf "Waiting for $IP to be reachable"
    attempts=0
    while [ $attempts -lt $MAX_ATTEMPTS ]; do
        printf "."
        sleep 1

        if ping -c 1 -W 1 $IP >/dev/null 2>&1; then
            echo " Reachable!"
            break
        fi

        attempts=$((attempts + 1))

        if [ $attempts -ge $MAX_ATTEMPTS ]; then
            echo " Max attempts reached. $IP is still unreachable."
            break
        fi
    done
}

check_status_net() {
    STATUS=$(nmap -p 3232 192.168.1.2 | grep '3232/tcp' | awk '{print $2}')
    
    if [ "$STATUS" = "open" ]; then
        return 0  # Port is open (true)
    else
        return 1  # Port is closed or unreachable (false)
    fi
}

check_status() {
    STATUS=$(nmap -p 3232 42.42.42.42 | grep '3232/tcp' | awk '{print $2}')
    
    if [ "$STATUS" = "open" ]; then
        return 0  # Port is open (true)
    else
        return 1  # Port is closed or unreachable (false)
    fi
}

start_services() {
  ifup
	# Start PPPoE server, nginx, php-fpm
  if [ "$EN_NET" == "true" ]; then
        pppoe-server -I br0 -T 60 -N 10 -C isp -S isp -L 0.0.0.0 -R 0.0.0.0 &
        sleep 5
        start_internet
  else
        pppoe-server -I eth0 -T 60 -N 1 -C isp -S isp -L 192.168.1.1 -R 192.168.1.2 &
  fi  
  /etc/init.d/S50nginx start
  /etc/init.d/S49php-fpm start
}

restart_services() {
  stop
	start_services
}

stop() {
	kill_services
	ifdown
}

if [ "$AUTO_START" = "true" ]; then
  echo "Auto Start is enabled, Starting PPPwn..."
  (execute_pppwn >> $LOG_FILE) > /dev/null 2>&1 & 
else
  echo "Auto Start is disabled, skipping PPPwn..."
  restart_services
fi