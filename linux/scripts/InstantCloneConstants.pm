#!/usr/bin/perl

################################################################################
#  Copyright 2008-2017 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantCloneConstants.pm
#
#     Global definitions of the constants used in the instant clone
#     guest customization.
#
#...............................................................................

use strict;

package InstantCloneConstants;

# Guest customization notification states.
# https://wiki.eng.vmware.com/InstantCloneGuestCustomizationMeeting3Proposal

our $STATE_OK = 'OK';
our $STATE_ERR = 'ERR';

our $NS_DB_NAME = 'com.vmware.pmi.gosc';
our $NS_DB_KEY_CONFIG = 'config';
our $NS_DB_KEY_STATE = 'state';

#...............................................................................
# Return value for module as required by Perl
#...............................................................................

1;
