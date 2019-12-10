#!/usr/bin/perl

################################################################################
#  Copyright 2008-2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# StdDefinitions.pm
#
#     Global definitions.
#
#...............................................................................

use strict;

package StdDefinitions;

# Return Codes
our $CUST_SUCCESS = 0;
our $CUST_GENERIC_ERROR = 255;
our $CUST_NETWORK_ERROR = 254;
our $CUST_NIC_ERROR = 253;
our $CUST_DNS_ERROR = 252;
our $CUST_DATETIME_ERROR = 251;
our $CUST_PRE_CUSTOMIZATION_ERROR = 250;
our $CUST_POST_CUSTOMIZATION_ERROR = 249;
our $CUST_PASSWORD_ERROR = 248;
our $CUST_MARKER_ERROR = 247;
our $CUST_NIC_REFRESH_ERROR = 246;
our $CUST_NS_CONFIG_READ_ERROR = 245;
our $CUST_NETWORK_START_ERROR = 244;
our $CUST_LOCK_ACQUIRE_ERROR = 243;

# Instant clone specific code goes up from 1
our $CUST_ID_NOT_FOUND_ERROR = 1;

#...............................................................................
# Return value for module as required by Perl
#...............................................................................

1;
