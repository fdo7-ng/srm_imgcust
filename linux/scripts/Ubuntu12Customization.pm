########################################################################################
#  Copyright 2012 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu12Customization;

# Inherit from Ubuntu11Customization.
use base qw(Ubuntu11Customization);

use strict;
use Debug;
use ConfigFile;

# Distro flavour detection constants
my $UBUNTU12_04 = "Ubuntu 12.04";
my $UBUNTU12_10 = "Ubuntu 12.10";

# Convenience variables
my $UBUNTUINTERFACESFILE = $DebianCustomization::DEBIANINTERFACESFILE;

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

      if ($issueContent =~ /Ubuntu\s+12\.10/i) {
         $result = $UBUNTU12_10;
      } elsif ($issueContent =~ /Ubuntu\s+12\.04/i) {
         $result = $UBUNTU12_04;
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }

   return $result;
}

sub CustomizeReslovFile
{
   # Ubuntu 12 introduces 2 big changes which affect DNS resolution.
   #
   # Package 'resolvconf' exclusively manages resolv.conf.
   # - Equivalent entries from resolv.conf now belong in the interfaces file.
   #
   # Package 'dnsmasq' installed on Desktop versions to serve as a local resolver.
   # - The dnsmasq instance is managed by NetworkManager.
   # - DNS server will be 127.0.0.1 as seen in resolv.conf.
   # - Testing reveals NM disables dnsmasq when the following conditions are detected:
   #   1. NetworkManager.conf: [ifupdown] managed = false (this is the default).
   #   2. interfaces file: NICs are explicitly configured in this file.
   #
   #   Customizing the NICs trigger these conditions so no further action is required
   #   to disable or to coordinate with dnsmasq.
   #
   # This leaves us with only having to set DNS entries in the interfaces file.

   my ($self) = @_;

   # By this point, the interfaces file has already been customized (CustomizeNICS).
   # Re-read in the interfaces file.
   my @content = Utils::ReadFileIntoBuffer($UBUNTUINTERFACESFILE);

   # Add DNS entries. Differences from resolv.conf:
   # - "dns-" prefixes.
   # - "nameservers" instead of "nameserver".
   # - Multiple nameservers belong on the same line.
   my $dnsSuffixes = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffixes && @$dnsSuffixes) {
      push(@content, "dns-search\t" . join(' ', @$dnsSuffixes) . "\n");
   }

   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
   if ($dnsNameservers && @$dnsNameservers) {
      push(@content, "dns-nameservers\t" . join(' ', @$dnsNameservers) . "\n");
   }

   # Re-write the interfaces file.
   Utils::WriteBufferToFile($UBUNTUINTERFACESFILE, \@content);
}

sub CustomizeIPv6Address
{
   my ($self, $nic) = @_;

   $self->SUPER::CustomizeIPv6Address($nic);

   my @ipv6Addresses = ConfigFile::ConvertToIndexedArray(
   $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));

   my @ipv6Netmasks = ConfigFile::ConvertToIndexedArray(
   $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));

   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   if (@ipv6Settings) {
      # Since the API doesn't allow to specify a combination of static/RA/DHCPv6, we enforce RA
      # and assume that it can be disabled somehow else (sysctl, recompile kernel, the network
      # itself shold not advirtise it, etc.).
      push(@{$self->{_interfacesFileLines}}, "accept_ra 1\n");
      push(@{$self->{_interfacesFileLines}}, "autoconf 1\n");
   } else {
      my $ipv4Mode    = $self->{_customizationConfig}->GetIpV4Mode($nic);

      # It seems like 'inet manual' marks NIC as not used, so we need to tell whether it's alive.
      # It's probably ok to do this for the static4/dhcp4 mode as well, but it's not required for
      # the 2015 release where we don't support dual protocol mode. It can always be related later.
      if ($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
         my $macaddr = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
         my $ifName = $self->GetInterfaceByMacAddress($macaddr);

         if (!$ifName) {
            die "Error finding the specified NIC for MAC address = $macaddr";
         }

         push(@{$self->{_interfacesFileLines}}, "iface $ifName inet6 auto\ndhcp 1\n");
      }
   }
}

sub AddRouteIPv6
{
   my ($self, $interface, $ipv6Gateways) = @_;

   INFO("Configuring Ubuntu 12 ipv6 route (gateway settings) for $interface.");

   foreach (@$ipv6Gateways) {
      INFO("Configuring default route $_");

      push(
         @{$self->{_interfacesFileLines}},
         "gateway $_\n");
   }
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

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

   # https://bugs.launchpad.net/ubuntu/+source/ifupdown/+bug/1301015
   Utils::ExecuteCommand("ifdown --verbose --exclude=lo -a 2>&1 && " .
                         "ifup --verbose --exclude=lo -a 2>&1");
}

1;