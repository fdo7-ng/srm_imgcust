#!/usr/bin/perl

################################################################################
#  Copyright 2010-2018 VMware, Inc.  All rights reserved.
################################################################################

package RHEL6Customization;
use base qw(RedHatCustomization);

use strict;
use Debug;

# distro flavour detection constants
our $RHEL6 = "Red Hat Enterprise Linux 6";
our $CENTOS6 = "Cent OS 6.X";
our $OLINUX6 = "Oracle Linux 6.X";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+6/i) {
      $result = $RHEL6;
   } elsif ($content =~ /CentOS.*?release\s+6/i) {
      $result = $CENTOS6;
   } elsif ($content =~ /Oracle.*?release\s+6/i) {
      $result = $OLINUX6;
   }
   return $result;
}

sub CustomizeNetwork
{
   my ($self) = @_;

   RemoveOldIFCfgFiles();

   $self->SUPER::CustomizeNetwork();
}

sub RemoveOldIFCfgFiles
{
   # If there is an ifcfg-ethX file with NM_CONTROLLED=no, NM will ignore
   # the rest of the ifcfg-ethX files and instead create "Auth ethX" profiles.
   INFO("Removing old interface configuration files.");
   Utils::ExecuteCommand("rm -f /etc/sysconfig/network-scripts/ifcfg-eth*");
}

sub FormatIFCfgContent
{
   my ($self, $nic ,$interface) = @_;

   # Some server and most desktop default installations of RHEL6 have NM
   # enabled by default. These additional entries are needed to
   # cooperate with NM.
   my $macaddr = $self->{_customizationConfig}->GetMACAddress($nic);
   my @content;

   # Set fields to be visible in the NetworkManager gui applet.
   push(@content, "HWADDR=$macaddr\n");
   push(@content, "NAME=$interface\n");

   # Set up the default gateway.
   my @ipv4Gateways = $self->{_customizationConfig}->GetGateways($nic);

   # ifcfg-ethX file supports 1 default gateway.
   if (@ipv4Gateways) {
      if (scalar(@ipv4Gateways) > 1) {
         WARN("More than 1 gateway detected. Only the first one will be used.");
      }
      push(@content, "GATEWAY=$ipv4Gateways[0]\n");
   }

   # Set up name servers in ifcfg.
   # NetworkManager will overwrite /etc/resolv.conf on startup.
   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
   if ($dnsNameservers) {
      my $i = 1;

      foreach (@$dnsNameservers) {
         push(@content, "DNS$i=$_\n");
         $i++;
      }
   }

   # Set up dns suffix search list
   my $dnsSuffixes = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffixes && @$dnsSuffixes) {
      push(@content, "DOMAIN=\"" . join(' ', @$dnsSuffixes) . "\"\n");
   }

   # Set up the rest of the fields.
   push(@content, $self->SUPER::FormatIFCfgContent($nic, $interface));

   return @content;
}

sub FormatIPv6IFCfgContent
{
   my ($self, $nic) = @_;
   my @content;

   # Set up the default gateway.
   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   # ifcfg-ethX file supports 1 default gateway.
   if (@ipv6Gateways) {
      if (scalar(@ipv6Gateways) > 1) {
         WARN("More than 1 IPv6 gateway detected. Only the first one will be used.");
      }
      push(@content, "IPV6_DEFAULTGW=$ipv6Gateways[0]\n");
   }

   # Set up all other IPv6 fields.
   push (@content, $self->SUPER::FormatIPv6IFCfgContent($nic));

   return @content;
}

sub AddRoute
{
   # Some server and most desktop default installations of RHEL6 have NM
   # enabled by default.
   # NetworkManager's ifcfg-rh plugin does not like our "route-ethX" entries,
   # so we will no-op here and put default gateway into "ifcfg-ethX" file.
}

sub GetSystemUTC
{
   return  Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   # /etc/sysconfig/clock file UTC parameter does not work in RHEL 6.x,
   # set hardware clock using hwclock command.
   my $utc = ($cfgUtc =~ /yes/i) ? "utc" : "localtime";
   my $hwPath = Utils::GetHwclockPath();
   Utils::ExecuteCommand("$hwPath --systohc --$utc");
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self)  = @_;
   my $returnCode;

   Utils::ExecuteCommand('service network restart 2>&1',
                         'Restart Network Service',
                         \$returnCode);

   if ($returnCode) {
      die "Failed to restart network, service code: $returnCode";
   }
}

1;
