#!/vendor/bin/sh

PATH=/sbin:/vendor/sbin:/vendor/bin:/vendor/xbin
export PATH

scriptname=${0##*/}

notice()
{
	echo "$*"
	echo "$scriptname: $*" > /dev/kmsg
}

# We take this from cpuinfo because hex "letters" are lowercase there
set -A cinfo `cat /proc/cpuinfo | sed -n "/Revision/p"`
hw=${cinfo[2]#?}

# Now "cook" the value so it can be matched against devtree names
m2=${hw%?}
minor2=${hw#$m2}
m1=${m2%?}
minor1=${m2#$m1}
if [ "$minor2" == "0" ]; then
	minor2=""
	if [ "$minor1" == "0" ]; then
		minor1=""
	fi
fi
setprop ro.vendor.hw.revision p${hw%??}$minor1$minor2
unset hw cinfo m1 m2 minor1 minor2

# reload UTAGS
utag_status=$(cat /proc/config/reload)
if [ "$utag_status" == "2" ]; then
	notice "Utags are not ready, reloading"
	echo 1 > /proc/config/reload
	utag_status=$(cat /proc/config/reload)
	[ "$utag_status" != "0" ] && notice "Utags failed to reload"
fi

# Export these for factory validation purposes
iccid=$(cat /proc/config/iccid/ascii 2>/dev/null)
if [ ! -z "$iccid" ]; then
	setprop ro.vendor.mot.iccid $iccid
fi
unset iccid
cust_md5=$(cat /proc/config/cust_md5/ascii 2>/dev/null)
if [ ! -z "$cust_md5" ]; then
	setprop ro.vendor.mot.cust_md5 $cust_md5
fi
unset cust_md5

# Get FTI data and catch old units with incorrect/missing UTAG_FTI
pds_fti=/mnt/vendor/persist/factory/fti
if [ -r $pds_fti ]; then
	set -A fti $(od -A n -t x1 $pds_fti 2>/dev/null | tr '[A-F]' '[a-f]')
else
	notice "Can not read FTI data in persist"
fi

# If UTAG_FTI is readable, compare checksums
# and if they mismatch, assume PDS is valid and overwrite UTAG
utag_fti=/proc/config/fti
if [ -r $utag_fti/ascii ]; then
	set -A fti_utag $(cat ${utag_fti}/raw | sed 's/../& /g' | tr '[A-F]' '[a-f]')
	# Byte 128 is total cksum, if nothing there, PDS data is invalid/missing
	if [ ! -z "${fti[127]}" ]; then
		# Make sure fti in UTAG is the same as in persist. Checksum comparison
		if [ "${fti[126]}" != "${fti_utag[126]}" -o "${fti[127]}" != "${fti_utag[127]}" ]; then
			notice "Copying FTI data from persist"
			cat $pds_fti > ${utag_fti}/raw
		fi
	else
		# If PDS data is invalid, take UTAG and hope it is correct
		notice "Will use FTI from UTAG"
		set -A fti $(od -A n -t x1 ${utag_fti}/ascii 2>/dev/null)
	fi
else
	notice "Missing FTI UTAG; copying from persist"
	echo fti > /proc/config/all/new
	cat $pds_fti > ${utag_fti}/raw
fi

# Read HW version from FTI data
hw_v1="\x${fti[35]}"
hw_v2="\x${fti[36]}"
hw_v3="\x${fti[37]}"
if [ "$hw_v3" == "\x30" ]; then
	hw_v3=""
fi
hw_v4="\x${fti[38]}"
if [ "$hw_v4" == "\x30" ]; then
	hw_v4=""
fi
setprop ro.vendor.hw.boardversion $(printf "$hw_v1$hw_v2$hw_v3$hw_v4")

# Now we have set fti var either from PDS or UTAG
# Get Last Test Station stamp from FTI
# and convert to user-friendly date, US format
# Real offsets for year/month/day are 63/64/65
# If the month/date look reasonable, data is probably OK.
mdate="Unknown"
y=0x${fti[63]}
m=0x${fti[64]}
d=0x${fti[65]}
let year=$y month=$m day=$d
# Invalid data will often have bogus month/date values
if [ $month -le 12 -a $day -le 31 -a $year -ge 12 ]; then
	mdate=$month/$day/20$year
else
	notice "Corrupt FTI data"
fi
setprop ro.vendor.manufacturedate $mdate
unset fti y m d year month day utag_fti pds_fti fti_utag mdate

t=$(getprop ro.build.tags)
if [[ "$t" != *release* ]]; then
	for p in $(cat /proc/cmdline); do
		if [ ${p%%:*} = "@" ]; then
			v=${p#@:}; a=${v%=*}; b=${v#*=}
			${a%%:*} ${a##*:} $b
	fi
	done
fi
unset p v a b t

# Cleanup stale/incorrect programmed model value
# Real values will never contain substrings matching "internal" device name
product=$(getprop ro.vendor.hw.device)
model=$(cat /proc/config/model/ascii 2>/dev/null)
if [ $? -eq 0 ]; then
	if [ "${model#*_}" == "$product" -o "${model%_*}" == "$product" ]; then
		notice "Clearing stale model value"
		echo "" > /proc/config/model/raw
	fi
fi
unset model product

# set ro.vendor.bootreason, which be used to indicate kpanic/wdt boot status.
# When ro.boot.last_powerup_reason is set, it denotes this is a 2nd reboot
# after kpanic/wdt, we set ro.bootreason as coldboot to copy logs.
# Otherwise, we would set ro.bootreason the same as ro.boot.bootreason.
# ro.boot.bootreason is restricted as of android p, so get it another way:
bootreason_kvp=$(cat /proc/bootinfo | grep "Last boot reason")
last_power_up=$(getprop ro.boot.last_powerup_reason)
if [ ! -z "$last_power_up" ]
then
	setprop ro.vendor.bootreason "coldboot"
else
	setprop ro.vendor.bootreason ${bootreason_kvp##* }
fi

# export WFD HDCP key state which should be done in factory
wfd_complete_file="/mnt/vendor/persist/wfd_complete"
wfd_hdcp_state="no provisioned"
if [ -f "$wfd_complete_file" ]; then
	setprop ro.vendor.mot.hw.wfd_hdcp_key_state 1
	wfd_hdcp_state="already provisioned"
else
	setprop ro.vendor.mot.hw.wfd_hdcp_key_state 0
fi
notice "WFD HDCP key state on device is: $wfd_hdcp_state"
unset $wfd_complete_file
unset $wfd_hdcp_state
