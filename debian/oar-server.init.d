#! /bin/sh
### BEGIN INIT INFO
# Provides:          oar-server
# Required-Start:    $network $local_fs $remote_fs $all
# Required-Stop:     $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: OAR server init script
# Description:       This script starts or stops the OAR resource manager
#                    
### END INIT INFO

# Author: Bruno Bzeznik <Bruno.Bzeznik@imag.fr>
#

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/usr/sbin:/bin:/usr/bin
DESC="OAR resource manager (server)"
NAME=oar-server
DAEMON=/usr/sbin/Almighty
DAEMON_NAME=Almighty
DAEMON_ARGS=""
PIDFILE=/var/run/$NAME.pid
SCRIPTNAME=/etc/init.d/$NAME

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions

#
# Function that starts the daemon/service
#
do_start()
{
	# Return
	#   0 if daemon has been started
	#   1 if daemon was already running
	#   2 if daemon could not be started
        
	CHECK_STRING=`oar_checkdb 2>&1` 
	if [ "$?" -ne "0" ]
        then
          echo 
          echo "  Database is not ready! Maybe not initiated or no DBMS running?"
          echo "  You must have a running MySQL or Postgres server."
          echo "  To init the DB, run oar_mysql_db_init or oar_psql_db_init"
          echo "  Also check the DB_* variables in /etc/oar/oar.conf"
          echo -n "  The error was: "
          echo $CHECK_STRING
          return 2
        fi
	#start-stop-daemon --start --quiet --pidfile $PIDFILE --name $DAEMON_NAME --test > /dev/null \
	#	|| return 1
        pidofproc -p $PIDFILE > /dev/null && { echo -n " already running" ; return 1 ;}
	start-stop-daemon --start --make-pidfile --pidfile $PIDFILE --background --exec $DAEMON -- \
		$DAEMON_ARGS \
		|| return 2
}

#
# Function that stops the daemon/service
#
do_stop()
{
	# Return
	#   0 if daemon has been stopped
	#   1 if daemon was already stopped
	#   2 if daemon could not be stopped
	#   other if a failure occurred
	start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --pidfile $PIDFILE
	RETVAL="$?"
	[ "$RETVAL" = 2 ] && return 2
        # Sarko is often frozed when the database is unreachable
	start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --name sarko
        # Extermination...
	start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --name $DAEMON_NAME
	[ "$?" = 2 ] && return 2
	# Many daemons don't delete their pidfiles when they exit.
	rm -f $PIDFILE
	return "$RETVAL"
}

#
# Function that sends a SIGHUP to the daemon/service
#
do_reload() {
	#
	# If the daemon can reload its configuration without
	# restarting (for example, when it is sent a SIGHUP),
	# then implement that here.
	#
        # start-stop-daemon --stop --signal 1 --quiet --pidfile $PIDFILE --name $NAME
	return 0
}

case "$1" in
  start)
	[ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
	do_start
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  stop)
	[ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
	do_stop
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  #reload|force-reload)
	#
	# If do_reload() is not implemented then leave this commented out
	# and leave 'force-reload' as an alias for 'restart'.
	#
	#log_daemon_msg "Reloading $DESC" "$NAME"
	#do_reload
	#log_end_msg $?
	#;;
  restart|force-reload)
	#
	# If the "reload" option is implemented then remove the
	# 'force-reload' alias
	#
	log_daemon_msg "Restarting $DESC" "$NAME"
	do_stop
	case "$?" in
	  0|1)
		do_start
		case "$?" in
			0) log_end_msg 0 ;;
			1) log_end_msg 1 ;; # Old process is still running
			*) log_end_msg 1 ;; # Failed to start
		esac
		;;
	  *)
	  	# Failed to stop
		log_end_msg 1
		;;
	esac
	;;
  *)
	#echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
	echo "Usage: $SCRIPTNAME {start|stop|restart|force-reload}" >&2
	exit 3
	;;
esac

: