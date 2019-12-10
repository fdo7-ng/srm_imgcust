#!/usr/bin/perl

################################################################################
#  Copyright 2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantCloneKill.pl
#
#  During the instant clone customization, there is a chance that
#  the customization process might hang for some reason. A hanging
#  customization process still holds the customization lock, and would
#  cause any new customization to fail. In order to get us out of this,
#  we need a mechanism to kill the hanging process and remove the lock.
#
#  We shall add an AbortCustomization VMODL API that call into this script
#  to do that.
#...............................................................................

use strict;
use InstantClone qw();

my $instantClone = new InstantClone($0, @ARGV);
$instantClone->KillRunning();
