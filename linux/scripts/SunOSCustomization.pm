#!/usr/bin/perl

########################################################################################
#  Copyright 2008 VMware, Inc.  All rights reserved.
########################################################################################

package SunOSCustomization;
use base qw(Customization);

use strict;
use Debug;
use Utils qw();

# distro detection constants
my $SUNOS      = "Sun OS Intel Release";

# distro flavour detection constants
my $SUNOS_10   = "Sun OS release 10";

sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   my $unameResult = Utils::ExecuteCommand("/sbin/uname -a", "Getting hostname");

   if ($unameResult =~ /SunOS/i) {
      $result = $SUNOS;
   }

   return $result;
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (!-e $Customization::ISSUEFILE) {
      WARN("Issue file not available. Ignoring it.");
   }

   my $issueContent = Utils::ExecuteCommand(
      "cat $Customization::ISSUEFILE",
      "Reading issue file");

   my $unameResult = Utils::ExecuteCommand(
      "/sbin/uname -r",
      "Getting distro flavour");

   # is it solaris 10
   if($unameResult =~ /5\.10/) {
      $result = $SUNOS_10;
   }

   return $result;
}

sub InitGuestCustomization
{
   my ($self) = @_;

   $self->GetHostName();
   $self->BuildIndexNICAliasByMAC();
}

sub GetHostName
{
   my ($self) = @_;

   $self->{_oldHostName} = Utils::ExecuteCommand("hostname", "Getting hostname");
   chomp($self->{_oldHostName});
}

sub BuildIndexNICAliasByMAC
{
   my ($self) = @_;

   # Create NICAlias->IFConfigLines hash
   my @nicAliasIfConfigLines =
      split
         /(.+): flags=/,
         Utils::ExecuteCommand("/sbin/ifconfig -a", "Getting interfaces");

   shift @nicAliasIfConfigLines unless $nicAliasIfConfigLines[0];
   my %nicAliasIfConfigLines = @nicAliasIfConfigLines;

   # Create NormalizedMACAddress->NICAlias hash
   $self->{_indexNICAliasByMac} = {};

   foreach my $nicAlias (keys(%nicAliasIfConfigLines)) {
      if ($nicAliasIfConfigLines{$nicAlias} =~ /ether\s+([\da-f:]+)/i) {
         my $normalizedMAC = Utils::NormalizeMACAddress($1);
         $self->{_indexNICAliasByMac}->{$normalizedMAC} = $nicAlias;
         DEBUG("MAC address [$normalizedMAC] has NIC alias [$nicAlias]");
      }
   }
}

sub GetNICAliasByMAC
{
   my ($self, $macAddress) = @_;

   my $result = $self->{_indexNICAliasByMac}->{Utils::NormalizeMACAddress($macAddress)};
   $result || die "Could not look up NIC alias for MAC address [$macAddress]";

   return $result;
}

sub CustomizeNetwork
{
   my ($self) = @_;

   RemoveDHCPState();

   $self->CustomizeHostName();

   $self->CustomizeDefaultDomain();
}

sub RemoveDHCPState
{
   # Note:
   # Contains the configuration for interface.
   # These state files are written only when
   # the dhcpagent process is terminated and the
   # dhcpagent program is not configured to release its IP address on termination.

   INFO("Removing dhcp state...");
   Utils::ExecuteCommand("pkill dhcpagent", "Stop dhcp client");
   Utils::ExecuteCommand("rm /etc/dhcp/*.dhc", "Remove state files");
}

sub CustomizeHostName
{
   my ($self) = @_;

   # Customize hostname
   my $hostName = $self->{_customizationConfig}->GetHostName();

   # Hostname is optional
   if (defined $hostName) {
      my $hostNameFile = "/etc/nodename";

      DEBUG("Host name is $hostName");
      my @lines;
      push(@lines, $hostName . "\n");
      Utils::WriteBufferToFile($hostNameFile, \@lines);
      Utils::SetPermission($hostNameFile, $Utils::RWRR);

      # Rename the /var/crash directory
      Utils::ExecuteCommand("mv /var/crash/$self->{_oldHostName} /var/crash/$hostName");
   }
};

sub CustomizeDefaultDomain
{
   my ($self) = @_;

   # Write domain stuff
   my $domainfilename = "/etc/defaultdomain";
   my $domainname     = $self->{_customizationConfig}->GetDomainName();
   my @content;
   push(@content, $domainname);
   Utils::WriteBufferToFile($domainfilename,\@content);
   Utils::SetPermission($domainfilename, $Utils::RWRR);
};

sub CustomizeSpecificNIC
{
   # XXX IPv6 support not implemented

   my ($self, $nic) = @_;

   # get the params
   my $macaddr   = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $bootproto = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");

   # get the network suffix
   my $prefix = $self->GetNICAliasByMAC($macaddr);

   DEBUG("Processing NIC $prefix ... ");
   DEBUG("Boot Protocol = $bootproto");

   if ($bootproto =~ /dhcp/i) {
      Utils::ExecuteCommand(
         "touch /etc/dhcp." . $prefix,
         "Enabling DHCP for $prefix.\nCreating dhcp file for $prefix.");

      # We need this to tell whether to configure dns from dhcp.
      $self->{_dhcpEnabledNIC} = "true";
   } elsif ( $bootproto =~ /static/i )   {
      Utils::ExecuteCommand(
         "rm -f /etc/dhcp." . $prefix,
         "Enabling STATIC IP for $prefix.\nDeleting dhcp file for $prefix");

      Utils::ExecuteCommand(
         "touch /etc/hostname." . $prefix,
         "Creating hostname file for $prefix");

      my $netmask   = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");
      my $ipaddr    = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");
      my $gateway   = $self->{_customizationConfig}->Lookup($nic . "|GATEWAY");

      # set the network address
      my $hostnamefile = "/etc/hostname." . $prefix;
      my @hostnameContent;
      push(@hostnameContent, "$ipaddr\n");
      push(@hostnameContent, "netmask + $netmask\n");
      Utils::WriteBufferToFile($hostnamefile,\@hostnameContent);
      Utils::SetPermission($hostnamefile, $Utils::RWRR);

      # set the netmask
      my $netmaskfile = "/etc/inet/netmasks";
      my @netmasksContent;
      my $networknumber = ComputeNetwork($ipaddr, $netmask);
      my $line = $networknumber . " " . $netmask . "\n";
      push(@netmasksContent, $line);
      Utils::AppendBufferToFile($netmaskfile, \@netmasksContent);
      Utils::SetPermission($netmaskfile, $Utils::RWRR);

      # set the gateway
      # Fix Bug 197308 when this script becomes operational
      my $routerfile = "/etc/defaultrouter";
      my @defaultrouterContent;
      my @gateways = split(/,/, $gateway);
      push(@defaultrouterContent, @gateways);
      push(@defaultrouterContent,"\n");
      Utils::AppendBufferToFile($routerfile, \@defaultrouterContent);
      Utils::SetPermission($routerfile, $Utils::RWRR);
   } else {
      # unknown boot proto
      die "Unknown boot proto.";
   }
}

sub CustomizeHostsFile
{
   my ($self, $hostsFile) = @_;

   # Note from Sun's Doc:
   # If you need to add addresses, you must add IPv4 addresses to both the hosts and
   # ipnodes files. You add only IPv6 addresses to the ipnodes file.

   # For IPv4 we need to update both /etc/hosts and /etc/inet/ipnodes.
   $self->SUPER::CustomizeHostsFile($hostsFile);
   $self->SUPER::CustomizeHostsFile("/etc/inet/ipnodes");
}

sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   if ($self->{_dhcpEnabledNIC}) {
      my $dnsFromDHCP = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");

      my $dhcpFileName = "/etc/default/dhcpagent";
      my @content = Utils::ReadFileIntoBuffer ($dhcpFileName);
      my $lineIndex =
         Utils::FindLineInBuffer(
            "PARAM_REQUEST_LIST",
            \@content,
            $Utils::SMDONOTSEARCHCOMMENTS);

      my $requestDNSOption = 6;

      if ($lineIndex >= 0) {
         my $line = Utils::GetLineWithoutComments($content[$lineIndex]);
         chomp $line;

         my $lineReplacement = $line;

         if ($dnsFromDHCP =~ /yes/i) {
            if (!($line =~ /$requestDNSOption/)) {
               if ($line =~ /\,/) {
                  $lineReplacement = $line . ",$requestDNSOption";
               } else {
                  $lineReplacement = $line . "$requestDNSOption";
               }
            }
         } elsif ($dnsFromDHCP =~ /no/i) {
            $lineReplacement =~ s/[\,]*$requestDNSOption//;
         } else {
            die "Unknown value for DNSFROMDHCP options, value=$dnsFromDHCP.";
         }

         $content[$lineIndex] =  $lineReplacement . "\n";
      } else {
         # Nothing to be done
         if ($dnsFromDHCP =~ /yes/i) {
            # add it to the config file
            push(@content, "PARAM_REQUEST_LIST=$requestDNSOption\n");
         } else {
            # Nothing to do
            return;
         }
      }

      Utils::WriteBufferToFile($dhcpFileName, \@content);
      Utils::SetPermission($dhcpFileName, $Utils::RWRR);
   }
}

sub CustomizeNSSwitch
{
   my ($self, $database) = @_;

   $self->SUPER::CustomizeNSSwitch($database);
   $self->SUPER::CustomizeNSSwitch("ipnodes");
}

# Base Properties overrides

sub OldHostName
{
   my ($self) = @_;

   return $self->{_oldHostName};
}

# Private Helper Methods

#.......................................................................................
#
# ComputeNetwork
#
#     Compute the network parameter from the network mask and IP address.
#     Basically do a bitwise AND.
#
# Params:
#     $ipaddr     IP address as dot notation
#     $netmask    Network mask as dot notation
#
# Results:
#     The network value. (e.g. IP=10.17.164.251, NETMASK=255.255.254.0 would
#     produce network 10.17.164.0)
#
#.......................................................................................

sub ComputeNetwork
{
   my ($ipaddr, $netmask) = @_;

   INFO("Computing network for $ipaddr and $netmask." );

   my @arr1 = split(/\./, $ipaddr);
   my @arr2 = split(/\./, $netmask);
   my @arr3;

   for my $i (0..3) {
      push(@arr3, 0+$arr1[$i] & 0+$arr2[$i]);
      DEBUG("$i :: $arr1[$i] \.\. $arr2[$i] \=\=\> $arr3[$i]");
   }

   my $network = join (".", @arr3);
   return $network;
}

sub TZPath
{
   return "/usr/share/lib/zoneinfo";
}

sub SetTimeZone
{
   my ($self, $tz) = @_;

   Utils::AddOrReplaceInFile(
      "/etc/default/init",
      "TZ=",
      "TZ=$tz",
      $Utils::SMDONOTSEARCHCOMMENTS);
}

sub SetUTC
{
   my ($self, $utc) = @_;

   if ($utc =~ /yes/i) {
      Utils::ExecuteCommand("rtc -z UTC");
   } else {
      my $tz = $self->{_customizationConfig}->GetTimeZone();

      if (defined $tz) {
         Utils::ExecuteCommand("rtc -z $tz");
      }
   }
}

1;
