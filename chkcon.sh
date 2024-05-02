#!/bin/bash

#SCRIPT written by CNH Jan 2024 to baby sit connections on m5/m6 hotspots.  
#this is designed to run from cron every 10+ mins to check on the connection state and attempt to resolve issues automatically
#do not run this more often then 10 mins because of the waits and steps in this script - it will auto close itself if it findsitsel already running though
#this assumes you have enabled root telnet and have crond running on your hotspot.  both of these are required to use this. 
#crond does not automatically run on the M5/M6s but you can start it with a script  - this assumes that you have already done this and crond is running
#this script needs to be run by root 
#This has been tested on mr5100, mr5200, mr6150 and mr6400 
#not responsible for anything you do with this 


# example crontab entries
#1       *       *       *       *       /bin/chkcon.sh
#16      *       *       *       *       /bin/chkcon.sh
#31      *       *       *       *       /bin/chkcon.sh
#46      *       *       *       *       /bin/chkcon.sh

#if you feel you need to run this more often - just convert this to a service script and run it as a service with a wait for each loop vs starting from cron




#********************************Settings***************************
#log to terminal 0/1
LOG_TERM=1

#look up pub ip and log 0/1
LOG_PUBIP=1

#file of log file. - if you use /var/log or /tmp it will automatically wipe on actual reboot.   
LOG_FILE=/home/admin/chkcon.log

#maximum log entries  - will be trimmed to this number plus new entries
#there is ~20k per month at 15 min intervals 
MAX_LOG_ENTRY=25000

#dns server used to check 
DNS_SERVER=8.8.8.8

#dns name to check
DNS_NAME_TO_CHECK=www.google.com

# URL to get public IP - 
#can be any page that returns a raw ip  - below are a few examples
#	         http://myexternalip.com/raw
#            http://ifconfig.me/ip
#            http://ident.me
#            http://ipinfo.io/ip
#            http://icanhazip.com
#            http://smart-ip.net/myip

IP_HTTP_ADDR=http://ident.me


#URL to check - can be any page you want to check be sure to include a path though 
#some URLS will always fail because of TLS ex https://www.t-mobile.com will work

CHECK_WEBPAGE=https://www.google.com/

#Minimum Minuets the system must be up before checks can be preformed
MIN_UPTIME_MIN=15
TELNET_ADDRESS="" # just declare the global for the telnet address we set this later 


#********************************end Settings***************************


#global defaults
#set strict variables.  this script uses return codes so dont use e or o 
set -u pipefail




######################## functions ###############################



function f_main() {
####################################################
#DESCRIPTION: main function for this script
#PARM
#TEST DRIVER:
#	f_main
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#	f_set_telnet_add
#	f_logger
#	f_cleanup_log
#	f_kill_telnet_client
#	f_validate_con
#	f_exit_if_running
#CHANGE LOG:
#main function for this script
	#verify system has been up long enough 
	f_exit_if_recent_boot
	f_logger "Chkcon Script Starting... "
	#exit if this script is already running 
	f_exit_if_running
	#clean up log file
	f_cleanup_log
	#set the global TELNET_ADDRESS
	f_set_telnet_add
	#telnet to the modem only allows one connection - if for some reason one already exists  kill it 
	f_kill_telnet_client
	#validate the connection and attempt to correct 
	f_validate_con
	f_logger "Chkcon Script Finished!"
####################################################
}

function f_cleanup_log() {
#####################################################
#DESCRIPTION: limits the log file from getting too large
#PARM
#TEST DRIVER:
#	f_cleanup_log
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#	LOG_FILE
#	MAX_LOG_ENTRY
#REQUIRED FUNCTIONS: 
#CHANGE LOG:
#
	if test -f $LOG_FILE ; then
		tail -n $MAX_LOG_ENTRY $LOG_FILE > /tmp/chkcon2.log
		mv -f /tmp/chkcon2.log $LOG_FILE
	fi
}



function f_exit_if_running() {
#####################################################
#DESCRIPTION: exit if the script is already running 
#PARM
#TEST DRIVER:
#	f_exit_if_running
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#	f_logger
#CHANGE LOG:
	#if the script is already running  - exit 
	if pidof -o $$ "$(basename "$0")" >/dev/null; then
		f_logger "Found $(basename "$0") already running - check scheduling to prevent this.  Exiting"
		exit 1
	fi
}



function f_kill_telnet_client() {
####################################################
#DESCRIPTION: kill telnet if telnet client is connected to modem 
#PARM
#TEST DRIVER:
#	f_kill_telnet_client
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#	f_logger
#CHANGE LOG:
#verify if telnet client is stuck running on hotspot - kill if it is
	TELNET_PID=$(ps|grep "{telnet}"|cut -c0-100|grep 5510|tr "root" " "|cut -c0-10)
	if [[ -n $TELNET_PID ]]; then
		f_logger "Found telnet running  - killing it"
		kill $TELNET_PID
	fi
}


function f_airplane_mode_reset() {
####################################################
#DESCRIPTION: 
#	airplane mode on / off
#	this function telnets into the modem sets airplane mode 
#	waits 30 seconds then sets normal mode
#	resolves most connection issues.
#	if a failure happens it reboots the hotspot to attempt to resolve. 
#PARM
#TEST DRIVER:
#	f_airplane_mode_reset
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#	f_kill_telnet_client 
#	f_logger
#CHANGE LOG:

# info for AT+cfun command
# AT+cfun=*
# 0 causes sim failure
# 1 normal
# 2 no wireless transmitter - not implemented on m6
# 3 no wire;less receiver - not implemented on m6
# 4 no transmiter or receiver - Causes disconnect / airplane mode
# 5 RF test mode - do not use
# 6 Allow SIM-TK - do not use
# 7 Disable SIM-TK  - do not use

	f_kill_telnet_client
	# set to airplane mode
	{ echo "AT+cfun=4"; } | telnet $TELNET_ADDRESS
	if [ $? -eq 0 ]; then
		f_logger "Successfully Set to Airplane mode"
	else
		f_logger "Failed to set to Airplane mode - rebooting via shutdown "
		/sbin/shutdown -r now
		exit 0
	fi
	f_logger "Waiting for 30 seconds ..."
	sleep 30
	f_kill_telnet_client
	{ echo "AT+cfun=1"; } | telnet $TELNET_ADDRESS
	if [ $? -eq 0 ]; then
		f_logger "Successfully set to normal mode"
	else
		f_logger "Failed to set to normal mode - rebooting via shutdown"
		/sbin/shutdown -r now
		exit 0
	fi
####################################################
}

function f_reboot_via_atreset() {
####################################################
#DESCRIPTION: 
#	restart via at reset modem command
#	if it failes to issue at reset it reboots via shutdown command
#PARM
#TEST DRIVER:
#	f_reboot_via_atreset
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#	f_kill_telnet_client
#	f_logger 
#CHANGE LOG:

	f_kill_telnet_client 
	{ echo "at!reset"; } | telnet $TELNET_ADDRESS
	if [ $? -eq 0 ]; then
		f_logger "successfully issued at!reset ${TELNET_ADDRESS}"
	else
		f_logger "Failed to telnet - rebooting via shutdown ${TELNET_ADDRESS}"
		/sbin/shutdown -r now
		exit 1
	fi
###################################################
}




function f_ChkDNS() {
####################################################
#DESCRIPTION:uses DNS query to check the connection
#PARM
#TEST DRIVER:
#	f_ChkDNS
#RETURNS: 0/1 for success or failure
#GLOBAL VARIABLES REQUIRED: 
#	DNS_SERVER
#	DNS_NAME_TO_CHECK
#REQUIRED FUNCTIONS:
#	f_logger
#CHANGE LOG:

	f_logger "testing DNS ${DNS_NAME_TO_CHECK} ${DNS_SERVER}"
	vTEST_CON=$(nslookup $DNS_NAME_TO_CHECK $DNS_SERVER|grep timed)
	if [ -n "$vTEST_CON" ] ; then #if string is not empty then return fail
		f_logger "DNS check FAILED! ${DNS_NAME_TO_CHECK} ${DNS_SERVER}"
		return 1
	else
		f_logger "DNS check SUCCESS! ${DNS_NAME_TO_CHECK} ${DNS_SERVER}"
		return 0
	fi 

####################################################
}

function f_validate_con() {
####################################################
#DESCRIPTION: validates the connection and attempts to correct via airplane mode, at reset or shutdown 
#PARM
#TEST DRIVER:
#	f_validate_con
#RETURNS: 
#GLOBAL VARIABLES REQUIRED: 
#REQUIRED FUNCTIONS: 
#	f_ChkDNS
#	f_reboot_via_atreset
#	f_logger
#CHANGE LOG:


#validate connection and take actions if it is not up 
# first check if the device thinks its connected
# 	if it fails twice  - put in airplane mode and back
# 	if it fails thrice - atreset to reboot
# 	if atreset fails tested by script still running after 2 mins - use shutdown to reboot
# validate connection via dns and www checks
# 	if it fails twice  - put in airplane mode and back
# 	if it fails thrice - atreset to reboot
# 	if atreset fails tested by script still running after 2 mins - use shutdown to reboot


	if test "$(dx wwan.connection)" = "Disconnected" ; then 
		f_logger "Failed dx wwan.connection - waiting 30 seconds to check agian "
		sleep 30 
		if test "$(dx wwan.connection)" = "Disconnected" ; then 
			f_logger "Failed wwan.connection check again 2nd time - starting airplane mode reset"
			f_airplane_mode_reset
			f_logger "Finished airplane reset - waiting 30 seconds"
			sleep 30
		fi
		if test "$(dx wwan.connection)" = "Disconnected" ; then 
			f_logger "Failed wwan.connection again 3rd time - starting at!reset "
			f_reboot_via_atreset
			f_logger "Waiting 2 mins for at!reset"
			sleep 2m
			f_logger "still on after at!reset  - rebooting via shutdown"
			#force reboot if at reset didnt work
			/sbin/shutdown -r now 
			exit
		fi 
	fi
	f_logger "wwan.connection is Connected! - testing connection...."
	if ! (f_ChkDNS && f_ChkWWW $CHECK_WEBPAGE); then  #if both DNS and WWW fail 
		f_logger "Failed dns /web check - waiting 30 seconds to check agian "
		sleep 30 
	else
		f_logger "Connection passed!"
		if [ $LOG_PUBIP -eq 1 ]; then f_logger "Pub IP: $(f_getIP)"; fi
		return 
	fi
	if ! (f_ChkDNS && f_ChkWWW $CHECK_WEBPAGE) ; then    #if both DNS and WWW fail 
		f_logger "Failed dns / web check again 2nd time - starting airplane mode reset"
		f_airplane_mode_reset
		f_logger "Finished airplane reset - waiting 30 seconds"
		sleep 30
	else
		f_logger "Connection passed!"
		if [ $LOG_PUBIP -eq 1 ]; then f_logger "Pub IP: $(f_getIP)"; fi
		return 
	fi
	if ! (f_ChkDNS || f_ChkWWW $CHECK_WEBPAGE); then  ##only reboot if both DNS and www both fail  - if either is working let it go
		f_logger "Failed con again 3rd time - starting at!reset "
		f_reboot_via_atreset
		f_logger "Waiting 2 mins for at!reset"
		sleep 2m
		f_logger "still on after at!reset  - rebooting via shutdown"
		#force reboot if at reset didnt work
		/sbin/shutdown -r now 
		exit
	else
		f_logger "Connection passed!"
		if [ $LOG_PUBIP -eq 1 ]; then f_logger "Pub IP: $(f_getIP)"; fi
		return 
	fi
####################################################
}


function f_getIP() {
#####################################################
#DESCRIPTION: gets public IP
#PARM
#TEST DRIVER:
#	$(f_getIP)
#RETURNS:  IP address
#GLOBAL VARIABLES REQUIRED:
#REQUIRED FUNCTIONS: 
#CHANGE LOG:
#
	if  [ -f /tmp/ip.txt ]; then rm /tmp/ip.txt ; fi
	wget -q -O /tmp/ip.txt $IP_HTTP_ADDR >/dev/null
	if  [ -f /tmp/ip.txt ]; then 
		echo $(cat /tmp/ip.txt )
		rm /tmp/ip.txt
		return 0
	else
		return 1
	fi
	


}

function f_ChkWWW() {
#####################################################
#DESCRIPTION: checks ability to load url 
#PARM
#	$1 - URL to check
#TEST DRIVER:
#	f_ChkWWW "https://www1.t-mobile.com/" 
#RETURNS: 0 true / 1 false
#GLOBAL VARIABLES REQUIRED:
#
#REQUIRED FUNCTIONS: 
#CHANGE LOG:
#

	f_logger "testing www - $1"
	if  [ -f /tmp/chkpg.txt ]; then rm /tmp/chkpg.txt ; fi
	wget -q -T 5 -O /tmp/chkpg.txt $1 2>/dev/null
	if  [ -f /tmp/chkpg.txt ]; then 
		rm /tmp/chkpg.txt
		
		f_logger "www Success! - $1"
		return 0
	else
		f_logger "Failed to download $1"
		return 1
	fi
	


}




function f_logger() {
#####################################################
#DESCRIPTION: logs the parmater past $1 to the log file and potentialy to screen 
#PARM
#TEST DRIVER:
#	f_logger "my test message"
#PARM
#	$1 - message to log
#TEST DRIVER:
#	f_logger "this is my test message"
#RETURNS: status 0/1 and IP
#GLOBAL VARIABLES REQUIRED:
#	LOG_FILE
#	LOG_TERM 
#
#REQUIRED FUNCTIONS: 
#CHANGE LOG:
#
	log_date=$(date -Isec)
	echo $log_date $1>>$LOG_FILE
	if [ $LOG_TERM -eq 1 ]; then echo $log_date $1; fi
	


}


function f_exit_if_recent_boot()   {
#####################################################
#DESCRIPTION: will exit the program if the system has not been up long enough 
#PARM
#TEST DRIVER:
#	f_exit_if_recrent_boot
#PARM
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#	MIN_UPTIME_MIN
#REQUIRED FUNCTIONS: 
#	f_logger
#CHANGE LOG:
#

	uptime_min=$(awk '{print int($1 / 60)}' /proc/uptime)
	if !(($uptime_min > $MIN_UPTIME_MIN)) ; then
		f_logger "System not up long enough (Uptime Minutes:$uptime_min) - exiting" 
		exit
	fi 

}



function f_set_telnet_add()   {
#####################################################
#DESCRIPTION: will set the global TELNET_ADDRESS based on the model number
#PARM
#TEST DRIVER:
#	f_set_telnet_add
#PARM
#RETURNS: 
#GLOBAL VARIABLES REQUIRED:
#	TELNET_ADDRESS
#REQUIRED FUNCTIONS: 
#	f_logger
#CHANGE LOG:
#

#telnet address
	if  test "$( dx General.MODEL|cut -c1-3)" = "MR6" ; then 
		#m6
		TELNET_ADDRESS=$(ps|grep "nc -l"|cut -c62-100|grep 5510|tr : " ")
		
	else
		#M5
		TELNET_ADDRESS=$(ps|grep "nc -l"|cut -c28-50|grep 5510|tr : " ")
	fi
	f_logger "Telnet_Address: $TELNET_ADDRESS"
}

#call f_main 
f_main



