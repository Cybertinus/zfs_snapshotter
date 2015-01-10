#!/usr/bin/env bash
#
# Create new snapshots of Owncloud userdata directories on ZFS level to
# provide a way to get old versions of files back
#
# Copyright (c) 2015 Tijn Buijs <tijn@cybertinus.nl>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

##########
# CONFIG #
##########

# Number of daily backups to store
daybackups=21
# Number of weekly backups to store
weekbackups=8
# Number of monthly backups to store
monthbackups=6
# Define the day of the week you want to save (0 = sunday, 1 = monday, .... 6 is saturday)
firstdayofweek=1
# The directory in which all the userdata is found
userdirs=/usr/local/www/owncloud/data


#################
# ACTUAL SCRIPT #
#################

# get the name of the zfs pool, needed to be able to manipulate snapshots and clones
zfspoolname=$(zpool list -H | grep -v bootpool | awk '{print $1}')

# get todays date, needed for naming of snapshots and stuff
today=$(date +%Y%m%d)

# go to the directory in which all the user directories are, makes the rest of the script easier
if [ ! -d "${userdirs}" ] ; then
	echo "Specified directory with the userdata (${userdirs}) doesn't exist." 1>&2
	exit 1
fi
cd "${userdirs}"

# extract the MySQL data, to be able to update the file cache table
dbhost=$(grep dbhost ../config/config.php | cut -d "'" -f 4)
dbname=$(grep dbname ../config/config.php | cut -d "'" -f 4)
dbuser=$(grep dbuser ../config/config.php | cut -d "'" -f 4)
dbpass=$(grep dbpassword ../config/config.php | cut -d "'" -f 4)
dbprefix=$(grep dbtableprefix ../config/config.php | cut -d "'" -f 4)

# define a function to run mysql queries
function mysql_query()
{
	mysql -h "${dbhost}" -u "${dbuser}" "-p${dbpass}" -s -e "${*}" "${dbname}"
}

# find user directories and loop through them
for userdir in $(find . -type d -maxdepth 1 | grep -v '^\.$' | sed 's/^\.\///'); do
	# extract the storage id from the MySQL database, so only the correct cache entries can be updated
	storageid=$(mysql_query "SELECT numeric_id FROM ${dbprefix}storages WHERE id = \"home::${userdir}\"");

	# check to see if we don't create a second snapshot on the same day
	if [ ! -d "${userdirs}/${userdir}/files/backups/${today}" ] ; then
		# create a new datedirectory for the new snapshot
		mkdir -p "${userdirs}/${userdir}/files/backups/${today}"

		# create a new snapshot
		zfs snapshot "${zfspoolname}/${userdir}@${today}"

		# clone it
		zfs clone -o mountpoint="${userdirs}/${userdir}/files/backups/${today}" "${zfspoolname}/${userdir}@${today}" "${zfspoolname}/${userdir}_${today}"

		# remove the backup directory structure from the clone
		rm -rf "${userdir}/files/backups/${today}/backups"

		# set the readonly option on the clone
		zfs set readonly=on "${zfspoolname}/${userdir}_${today}"

		# Remove the indexes of the backup listing from the cache, to have and up-to-date overview in the webbrowser
		mysql_query "DELETE FROM ${dbprefix}filecache WHERE storage = ${storageid} AND path = 'files/backups'"
		mysql_query "DELETE FROM ${dbprefix}filecache WHERE storage = ${storageid} AND path = 'files'"
	fi
	
	# loop through all the snapshots, to see if there are expired snapshots
	for snapshot in $(zfs list -H -t snapshot | grep "${userdir}" | awk '{print $1}') ; do
		# extract the snapshot date
		snapshotdate=$(echo $snapshot | cut -d '@' -f 2)

		# check to see if the snapshot isn't older then $daybackups
		todayepoch=$(date -j -f "%Y%m%d" ${today} "+%s")
		snapshotepoch=$(date -j -f "%Y%m%d" ${snapshotdate} "+%s")
		snapshotage_inseconds=$(( $todayepoch - $snapshotepoch ))
		maxage_inseconds=$(( $daybackups * 24 * 60 * 60 ))
		if [ $snapshotage_inseconds -gt $maxage_inseconds ] ; then
			# it is, tag this snapshot for deletions
			tagfordelete=Y

			# check to see if it is a first day of the week backup
			snapshot_dow=$(date -j -f "%Y%m%d" ${snapshotdate} "+%w")
			if [ ${snapshot_dow} -eq ${firstdayofweek} ] ; then
				# it is, untag this snapshot for deletion
				tagfordelete=N

				# check to see if it is older then $weekbackups
				maxage_inseconds=$(( $weekbackups * 7 * 24 * 60 * 60 ))
				if [ $snapshotage_inseconds -gt $maxage_inseconds ] ; then
					# it is, tag this snapshot for deletion
					tagfordelete=Y
				fi
			fi

			# check to see if it is a first day of the month backup
			snapshot_dom=$(date -j -f "%Y%m%d" ${today} "+%e" | sed 's/ //')
			if [ ${snapshot_dom} -eq 1 ] ; then
				# it is, untag this snapshot for deletion
				tagfordelete=N
				# check to see if it is older then $monthbackups
				todayyear=$(echo ${today:0:4})
				todaymonth=$(echo ${today:4:2})
				snapshotyear=$(echo ${snapshotdate:0:4})
				snapshotmonth=$(echo ${snapshotdate:4:2})
				yeardiff=$(( $todayyear - $snapshotyear ))
				if [ ${todayyear} -gt ${snapshotyear} ] ; then
					extramonths=$(( $yeardiff * 12 ))
					todaymonth=$(( $todaymonth + $extramonths ))
				fi
				monthdiff=$(( $todaymonth - $snapshotmonth ))
				if [ ${monthdiff} -gt ${monthbackups} ] ; then
					# it is, tag this snapshot for deletion
					tagfordelete=Y
				fi
			fi

			# check to see if this snapshot is taged for deletion
			if [ ${tagfordelete} = 'Y' ] ; then
				# it is

				# remove clone
				clone=$(echo ${snapshot} | sed 's/@/_/')
				zfs destroy ${clone}
				# remove snapshot
				zfs destroy ${snapshot}
				# remove the mountpoint
				rmdir ${userdirs}/${userdir}/files/backups/${snapshotdate}
				
				# Delete the old stale cache entries from MySQL
				mysql_query "DELETE FROM ${dbprefix}filecache WHERE storage = ${storageid} AND path LIKE 'files/backups/${snapshotdate}/%'"
				mysql_query "DELETE FROM ${dbprefix}filecache WHERE storage = ${storageid} AND path = 'files/backups/${snapshotdate}'"
			fi
		fi
	# end loop through all the snapshots
	done

# End of loop through user directories
done
