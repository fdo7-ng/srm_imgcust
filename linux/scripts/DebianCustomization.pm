#!/usr/bin/perl

########################################################################################
#  Copyright 2008-2017 VMware, Inc.  All rights reserved.
########################################################################################

package DebianCustomization;
use base qw(Customization);

use strict;
use Debug;
use ConfigFile;

# Directory configurations
my $DEBIANNETWORKDIR       = "/etc/network";

# distro detection configuration files
my $DEBIANVERSIONFILE      = "/etc/debian_version";

# distro detection constants
my $DEBIAN                 = "Debian Linux Distribution";

# distro flavour detection constants
my $DEBIAN_GENERIC         = "Debian";

my $DEBIANHOSTNAMEFILE     = "/etc/hostname";
our $DEBIANINTERFACESFILE   = $DEBIANNETWORKDIR . "/interfaces";

sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   if (-e $DEBIANVERSIONFILE) {
      if (-e $Customization::ISSUEFILE and
         (! (Utils::ExecuteCommand("cat $Customization::ISSUEFILE") =~ /debian/i))) {
         # We are sure that this is not a Debian distro
         $result = undef;
      } else {
         # Otherwise, we suppose this is a Debian distro
         $result =  $DEBIAN;
      }
   }

   return $result;
}

sub FindOsId
{
   my ($self, $content) = @_;

   return $DEBIAN_GENERIC;
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG ("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);
      $result = $self->FindOsId($issueContent);
   } else {
      WARN("Issue file not available. Ignoring it.");
   }

   return $result;
}

sub InstallPostRebootAgent
{
   my ($self, $currDir) = @_;

   $self->InstallPostRebootAgentGeneric($currDir, $Customization::RC_LOCAL);
}

sub InitOldHostname
{
   my ($self) = @_;

   $self->{_oldHostName} = Utils::GetValueFromFile($DEBIANHOSTNAMEFILE, "(.*)");
   INFO("OLD HOST NAME = $self->{_oldHostName}");
}

sub CustomizeNetwork
{
   my ($self) = @_;

   RemoveDHCPState();

   $self->CustomizeHostName();
}

sub RemoveDHCPState
{
   # Erase any saved leases given by dhcp so that they are not reused.
   INFO("Erasing DHCP leases");
   Utils::ExecuteCommand("pkill dhclient");
   Utils::ExecuteCommand("rm -f /var/lib/dhcp/*");
}

sub CustomizeHostName
{
   my ($self) = @_;

   my $hostName = $self->{_customizationConfig}->GetHostName();

   # Hostname is optional
   if (! ConfigFile::IsKeepCurrentValue($hostName)) {
      my @lines;

      DEBUG("Host name is $hostName");
      push(@lines, $hostName);

      Utils::WriteBufferToFile($DEBIANHOSTNAMEFILE, \@lines);
      Utils::SetPermission($DEBIANHOSTNAMEFILE, $Utils::RWRR);
   }
};

sub CustomizeNICS
{
   my ($self) = @_;

   # The interfaces file containts the config for all interfaces.
   # Its structure is not simple, so trying to understand it form a script is tricky.
   # This is why, we overwrite the old file with a new one.

   $self->{_interfacesFileLines} = [];
   push(@{$self->{_interfacesFileLines}}, "iface lo inet loopback\n");
   push(@{$self->{_interfacesFileLines}}, "auto lo\n\n");

   $self->SUPER::CustomizeNICS();

   # Create a backup before rewriting the interfaces file.
   Utils::ExecuteCommand(
      "mv $DEBIANINTERFACESFILE $DEBIANINTERFACESFILE.BeforeVMwareCustomization");

   $self->FlushInterfacesFile();
}

sub FlushInterfacesFile {
   my ($self) = @_;

   Utils::WriteBufferToFile($DEBIANINTERFACESFILE, $self->{_interfacesFileLines});
}

sub CustomizeSpecificNIC
{
   # map the function params
   my ($self, $nic) = @_;

   # get the params
   my $macaddr     = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $onboot      = $self->{_customizationConfig}->Lookup($nic . "|ONBOOT");
   my $bootproto   = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");
   my $ipv4Mode    = $self->{_customizationConfig}->GetIpV4Mode($nic);

   # get the network suffix
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC for MAC address = $macaddr";
   };

   INFO ("NIC suffix = $interface");

   if ($onboot) {
      push(@{$self->{_interfacesFileLines}}, "auto $interface\n");
   }

   if ($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
      INFO("Marking $interface as IPv4-disabled ('manual')");
      # static IPv4 configuration won't be executed below (including 'primary NIC' logic)
      $bootproto = 'manual';
   }

   # Customize IPv4
   push(@{$self->{_interfacesFileLines}}, "iface $interface inet $bootproto\n");

   if ($bootproto =~ /static/i) {
      my $netmask     = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");
      my $ipaddr      = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");

      if ($ipaddr) {
         push(@{$self->{_interfacesFileLines}}, "address $ipaddr\n");
      }

      if ($netmask) {
         push(@{$self->{_interfacesFileLines}}, "netmask $netmask\n");
      }

      # set up the gateways -- routes for addresses outside the subnet
      # GATEWAY parameter is not used to support multiple gateway setup,
      # except for the 'primary' NIC situation
      my @ipv4Gateways =
         split(/,/, $self->{_customizationConfig}->Lookup($nic . "|GATEWAY"));

      if (@ipv4Gateways) {
         $self->AddRouteIPv4($interface, \@ipv4Gateways, $nic);
      }
   }

   # IPv6 entries MUST be after IPv4 ones according to manual testing and
   # description from 'man interfaces'.
   # NOTE: If IPv6 fails, load the ipv6 module in /etc/init.d/networking
   $self->CustomizeIPv6Address($nic);

   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   if (@ipv6Gateways) {
      $self->AddRouteIPv6($interface, \@ipv6Gateways);
   }
}

sub CustomizeIPv6Address
{
   my ($self, $nic) = @_;

   my @ipv6Addresses = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));

   my @ipv6Netmasks = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));

   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   if (@ipv6Settings) {
      my $macaddr = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
      my $ifName = $self->GetInterfaceByMacAddress($macaddr);

      if (!$ifName) {
         die "Error finding the specified NIC for MAC address = $macaddr";
      }

      push(@{$self->{_interfacesFileLines}}, "iface $ifName inet6 static\n");
      push(@{$self->{_interfacesFileLines}}, "address " . $ipv6Settings[0]->[0] . "\n");
      push(@{$self->{_interfacesFileLines}}, "netmask " . $ipv6Settings[0]->[1] . "\n");

      for (@ipv6Settings[1..$#ipv6Settings]) {
         my $addr = $_->[0] . "/" .  $_->[1];
         push(@{$self->{_interfacesFileLines}}, "up ifconfig $ifName add $addr\n");
      }
   }
}

sub AddRouteIPv4
{
   my ($self, $interface, $ipv4Gateways, $nic) = @_;

   my $primaryNic = $self->{_customizationConfig}->GetPrimaryNic();
   if (defined $primaryNic) {
      # This code will not be called for DHCP primary NIC, since Gateways will
      # be empty.
      if ($primaryNic ne $nic) {
         INFO("Skipping default gateway for non-primary NIC '$nic'. Setting metric to 1.");
         push(@{$self->{_interfacesFileLines}}, "metric 1\n");
         return 0;
      } else {
         INFO("Configuring gateway from the primary NIC '$nic'");
         my $primaryNicGw = @$ipv4Gateways[0];
         # With 'primary' NIC we don't support multiple gateways
         push(@{$self->{_interfacesFileLines}}, "gateway $primaryNicGw\n");
         push(@{$self->{_interfacesFileLines}}, "metric 0\n");
         return 0;
      }
   } else {
      INFO("No primary NIC defined. Adding all routes as default.");
   }

   INFO("Configuring ipv4 route (gateway settings) for $interface.");

   foreach (@$ipv4Gateways) {
      INFO("Configuring default route $_");

      push(
         @{$self->{_interfacesFileLines}},
         "up route add default gw $_\n");
   }
}

sub AddRouteIPv6
{
   my ($self, $interface, $ipv6Gateways) = @_;

   INFO("Configuring ipv6 route (gateway settings) for $interface.");

   foreach (@$ipv6Gateways) {
      INFO("Configuring default route $_");

      push(
         @{$self->{_interfacesFileLines}},
         "up route -A inet6 add default gw $_\n");
   }
}

sub SetTimeZone
{
   my ($self, $tz) = @_;

   Utils::ExecuteCommand("ln -sf /usr/share/zoneinfo/$tz /etc/localtime");

   my @tzcontent = ($tz);
   Utils::WriteBufferToFile("/etc/timezone", \@tzcontent);
}

sub SetUTC
{
   my ($self, $utc) = @_;

   Utils::AddOrReplaceInFile(
      "/etc/default/rcS",
      "UTC",
      "UTC=$utc",
      $Utils::SMDONOTSEARCHCOMMENTS);
}

# Base proprties overrides

sub OldHostName
{
   my ($self) = @_;

   return $self->{_oldHostName};
}

sub DHClientConfPath
{
   return "/etc/dhcp3/dhclient.conf";
}

1;
