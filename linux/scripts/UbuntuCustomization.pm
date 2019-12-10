#!/usr/bin/perl

########################################################################################
#  Copyright 2008 VMware, Inc.  All rights reserved.
########################################################################################

package UbuntuCustomization;
use base qw(DebianCustomization);

use strict;
use Debug;

# distro detection configuration files
my $UBUNTURELEASEFILE      = "/etc/lsb-release";

# distro detection constants
my $UBUNTU                 = "Ubuntu Linux Distribution";

# distro flavour detection constants
my $UBUNTU_GENERIC         = "Ubuntu";

sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   if (-e $UBUNTURELEASEFILE) {
      my $lsbContent = Utils::ExecuteCommand("cat $UBUNTURELEASEFILE");

      if ($lsbContent =~ /Ubuntu/i) {
         $result = $UBUNTU;
      }
   }

   return $result;
}

sub DetectDistroFlavour
{
   my ($self) = @_;

   if (!-e $Customization::ISSUEFILE) {
      WARN("Issue file not available. Ignoring it.");
   }

   DEBUG("Reading issue file ... ");
   DEBUG(Utils::ExecuteCommand("cat $Customization::ISSUEFILE"));

   return $UBUNTU_GENERIC;
}

1;