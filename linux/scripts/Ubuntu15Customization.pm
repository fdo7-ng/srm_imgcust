########################################################################################
#  Copyright 2016-2018 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu15Customization;

# Inherit from Ubuntu13Customization.
# This is used for Ubuntu15.x/16.x/17.04 customization.
# And also a fallback route for Ubuntu 17.10/18.x customization,
# when both netplan and network-manager are installed.
use base qw(Ubuntu13Customization);

use strict;
use Debug;

# Convenience variables
my $UBUNTUINTERFACESFILE = $DebianCustomization::DEBIANINTERFACESFILE;

my $UBUNTURELEASEFILE      = "/etc/lsb-release";

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);
      if ($issueContent =~ /Ubuntu\s+(1[5-8]\.(04|10))/i) {
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
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and $lsbContent =~ /DISTRIB_RELEASE=(1[5-8]\.(04|10))/) {
            $result = "Ubuntu $1";
         }
      }
   }

   return $result;
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ifcfgResult) = @_;

   if (! defined $ifcfgResult) {
       DEBUG("Get interface name for MAC $macAddress, via [ip addr show]");
       return $self->GetInterfaceByMacAddressIPAddrShow($macAddress);
   }

   # The code below is to keep the unit test passing.
   my $result = undef;

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   if ($macAddressValid &&
      ($ifcfgResult =~ /^\s*(\w+?)(:\w*)?\s+.*?$macAddress/mi)) {
      $result = $1;
   }

   return $result;
}

sub CustomizeHostName
{
   my ($self) = @_;

   my $hostName = $self->{_customizationConfig}->GetHostName();

   # Hostname is optional
   if (! ConfigFile::IsKeepCurrentValue($hostName)) {
      DEBUG("Set the host name to $hostName via [hostnamectl set-hostname]");
      Utils::ExecuteCommand("hostnamectl set-hostname $hostName");
      # hostnamectl might nuke the hostname file on invalid input
      # looks like a bug with hostnamectl
      # work around it and keep the existing unit tests happy
      $self->SUPER::CustomizeHostName();
   }
};

1;
