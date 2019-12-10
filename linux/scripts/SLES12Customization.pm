#!/usr/bin/perl

###############################################################################
#  Copyright 2014-2018 VMware, Inc.  All rights reserved.
###############################################################################

package SLES12Customization;
use base qw(SLES11Customization);

use strict;
use Debug;

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;

   if (exists $self->{_distroFlavour}) {
      return $self->{_distroFlavour};
   }

   my $result = undef;

   if (!-e $Customization::ISSUEFILE) {
      WARN("Issue file not available. Ignoring it.");
   } else {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);

      # SLES 12 and SLES 15
      if ($issueContent =~ /suse.*enterprise.*(server|desktop).*(1[2-5])/i) {
         $result = "Suse Linux Enterprise $1 $2";
      }

      $self->{_distroFlavour} = $result;
   }
   return $result;
}

sub CustomizeHostName
{
   my ($self) = @_;

   # Invoking CustomizeHostName in SuseCustomization.pm which writes to
   # /etc/HOSTNAME with host and domain name. Setting hostname for current
   # session.
   my $newHostName   = $self->{_customizationConfig}->GetHostName();

   if (defined $newHostName) {
      Utils::ExecuteCommand("hostname $newHostName");
   }
   $self->SUPER::CustomizeHostName();
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ipAddrResult) = @_;

   return $self->GetInterfaceByMacAddressIPAddrShow($macAddress, $ipAddrResult);

}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self) = @_;
   #  /etc/init.d/network not present. So using systemctl command.
   Utils::ExecuteCommand('systemctl restart network.service 2>&1');
}

sub GetSystemUTC
{
   return  Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   # /etc/sysconfig/clock file not functional for hardware clock in SLES12,
   # set hardware clock using timedatectl command.
   my ($self, $cfgUtc) = @_;
   my $utc = ($cfgUtc =~ /yes/i) ? "0" : "1";
   my $timedatectlPath = Utils::GetTimedatectlPath();
   Utils::ExecuteCommand("$timedatectlPath set-local-rtc $utc");
}

1;
