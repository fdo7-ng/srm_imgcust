#!/usr/bin/perl

################################################################################
#  Copyright 2017 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantCloneNicsUp.pl
#
#  During the instant clone customization process, the client calls the
#  EnableGuestNetworks VMODL API to bring up the customized VM's network. The
#  VMODL API shall connect the nics of the VM, and then invoke this script
#  to bring up the network, e.g. acquiring IPs from DHCP.
#  Please see the design page below for details.
#  https://wiki.eng.vmware.com/VMForkGen3GuestCustomization#EnableGuestNetworks_.28CONNECT_NICS_API.29
#
#...............................................................................

use strict;
use InstantClone qw();

my $instantClone = new InstantClone($0, @ARGV);
$instantClone->Invoke(\&InstantClone::NicsUp);
