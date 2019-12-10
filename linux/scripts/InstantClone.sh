#!/bin/sh

################################################################################
#  Copyright 2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantClone.sh
#
#  The wrapper shell script that VC calls when launching the instant clone
#  guest customization processes.
#  This is the script that VC knows about. This level of indirection allows
#  the VC side code to remain the same, while later versions of the guest
#  customization can change, e.g. Use python instead of perl.
#
#  The first argument of the script is a command that would dispatch
#  to a sub script that implements the command.
#  The remaining args are passed through to the command scripts as is.
#  The supported commands as of now are Customize and StartNetwork.
#
#...............................................................................

DIRNAME=/usr/bin/dirname
PERL=/usr/bin/perl
LOGFILEPATH=/var/log/vmware-gosc/instant_clone_customization.log
DOLOG=false
GOSC_DIR=`${DIRNAME} $0`

setupLogging()
{
    logdir=`$DIRNAME $LOGFILEPATH`
    /bin/mkdir -p $logdir && /bin/touch $LOGFILEPATH && DOLOG=true
}

log() {
    echo $@
    if [ "$DOLOG" = "true" ]; then
        echo >>$LOGFILEPATH $@
    fi
}

usage() {
    log "Usage: $0 <Customize|StartNetwork|Kill> [pass_through_args]"
    exit 1
}

setupLogging

if [ -z $1 ]; then
    log "Missing the first required command line argument, got none."
    usage
fi

command=$1
shift

case $command in
    Customize)
        cmd="$PERL -I${GOSC_DIR} ${GOSC_DIR}/InstantCloneLaunch.pl";;
    StartNetwork)
        cmd="$PERL -I${GOSC_DIR} ${GOSC_DIR}/InstantCloneNicsUp.pl";;
    Kill)
        cmd="$PERL -I${GOSC_DIR} ${GOSC_DIR}/InstantCloneKill.pl";;
    *)
        log "Unknown command: $command"
        usage;;
esac

log "Running: $cmd $@"
$cmd "$@"
exitCode=$?
log "Exiting with code $exitCode"
exit $exitCode
