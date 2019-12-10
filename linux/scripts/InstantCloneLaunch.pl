#!/usr/bin/perl

################################################################################
#  Copyright 2017 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantCloneLaunch.pl
#
#  The main script that starts the instant clone customization process.
#
#...............................................................................

use strict;
use InstantClone qw();

my $instantClone = new InstantClone($0, @ARGV);
$instantClone->Invoke(\&InstantClone::Customize);
