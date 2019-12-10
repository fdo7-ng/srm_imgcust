#!/usr/bin/perl

########################################################################################
#  Copyright 2017 VMware, Inc.  All rights reserved.
########################################################################################

package Debian8Customization;
use base qw(DebianCustomization);

use strict;
use Debug;

# distro flavour detection constants
our $Debian8 = "Debian 8";
our $Debian9 = "Debian 9";
our $Debian10 = "Debian 10";

# default location for post-reboot script
our $POST_CUSTOMIZATION_AGENT_DEBIAN = "/etc/init.d/post-customize-guest";

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   #Pre-enabling 10 to work same way as 9
   if ($content =~ /Debian.*GNU.*Linux.*\s+(8|9|10)/i) {
      $result = "Debian $1";
   }

   return $result;
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ipAddrResult) = @_;

   return $self->GetInterfaceByMacAddressIPAddrShow($macAddress, $ipAddrResult);

}

sub DHClientConfPath
{
   # Starting with Debian 7, the DHCP client package changed from
   # dhcp3-client to isc-dhcp-client. This new package installs and uses conf
   # file from /etc/dhcp/. Prior to this, it was from /etc/dhcp3/
   return "/etc/dhcp/dhclient.conf";
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

# See Customization.pm#RestartNetwork
sub RestartNetwork
{
   my ($self) = @_;

   # If NetworkManager is running, wait before restarting.
   # Restarting NM too quickly after Customize() can put network in a bad state.
   # Mask STDERR "unrecognized service" when NM is not installed.
   my $nmStatus = Utils::ExecuteCommand("service network-manager status 2>&1");
   my $nmRunning = ($nmStatus =~ /running/i);
   if ($nmRunning) {
      sleep 5;
      Utils::ExecuteCommand("service network-manager restart 2>&1");
   }
   Utils::ExecuteCommand("/etc/init.d/networking restart 2>&1");
}


1;
