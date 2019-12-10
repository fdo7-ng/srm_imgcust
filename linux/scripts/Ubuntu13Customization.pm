########################################################################################
#  Copyright 2012 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu13Customization;

# Inherit from Ubuntu12Customization.
use base qw(Ubuntu12Customization);

use strict;
use Debug;

# Convenience variables
my $UBUNTUINTERFACESFILE = $DebianCustomization::DEBIANINTERFACESFILE;

my $UBUNTURELEASEFILE      = "/etc/lsb-release";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);

      if ($issueContent =~ /Ubuntu\s+(1[3-4]\.(04|10))/i) {
         $result = "Ubuntu $1";
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }
   # beta versions has /etc/issue file contents of form
   # Ubuntu Trusty Tahr (development branch) \n \l
   if(! defined $result) {
      if (-e $UBUNTURELEASEFILE) {
         my $lsbContent = Utils::ExecuteCommand("cat $UBUNTURELEASEFILE");
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and $lsbContent =~ /DISTRIB_RELEASE=(1[3-4]\.(04|10))/) {
            $result = "Ubuntu $1";
         }
      }
   }

   return $result;
}

sub GetSystemUTC
{
   return Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   # /etc/default/rcS file UTC parameter is removed,
   # set hardware clock using hwclock command.
   my $utc = ($cfgUtc =~ /yes/i) ? "utc" : "localtime";
   my $hwPath = Utils::GetHwclockPath();
   Utils::ExecuteCommand("$hwPath --systohc --$utc");
}

1;
