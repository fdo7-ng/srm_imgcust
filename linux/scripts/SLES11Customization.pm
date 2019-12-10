#!/usr/bin/perl

########################################################################################
#  Copyright 2009-2018 VMware, Inc.  All rights reserved.
########################################################################################

package SLES11Customization;
use base qw(SuSECustomization);

use strict;
use Debug;

my $SUSE_SLES11 = "SLES 11";

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
   }

   DEBUG("Reading issue file ... ");
   my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
   DEBUG($issueContent);

   if ($issueContent =~ /suse.*?enterprise.*?server.*?11/i) {
      $result = $SUSE_SLES11;
   }

   $self->{_distroFlavour} = $result;

   return $result;
}

sub CustomizeReslovFile
{
   my ($self) = @_;

   # SLES 11 introduces netcofnig - a modular tool that merges static(set by user) and
   # dynamic(sent by e.g dhcp) network settings. Yast uses netconfig.
   # See /usr/share/packages/sysconfig/README.netconfig.

   # Edit suffixes and nameservers in the netconfig settings. GUI(yast) shows them.
   my $netconfigConfigFile = "$SuSECustomization::SUSEIFCFGDIR/config";

   # Using netconfig is the preferred over resolv.conf
   # However, it can't ignore settings from dhcp and always merges them in resolv.conf
   # This is undesired when DNSFROMDHCP=no
   my $useDnsFromDhcp = $self->{_customizationConfig}->GetDNSFromDHCP();
   my $useNetconfig = ((! defined $useDnsFromDhcp) || $useDnsFromDhcp);

   my $dnsPolicy = $useNetconfig ? 'auto' : '';
   Utils::AddOrReplaceInFile($netconfigConfigFile,
                             'NETCONFIG_DNS_POLICY=',
                             "NETCONFIG_DNS_POLICY=\"$dnsPolicy\"");

   # netconfig - name servers
   my $nameServerList = $self->{_customizationConfig}->GetNameServers();
   if (defined $nameServerList) {
      my $ncNameservers = join(' ', @$nameServerList);
      Utils::AddOrReplaceInFile($netconfigConfigFile,
                                'NETCONFIG_DNS_STATIC_SERVERS=',
                                "NETCONFIG_DNS_STATIC_SERVERS=\"$ncNameservers\"");
   }

   # netconfig - search suffixes
   my $dnsSuffixList = $self->{_customizationConfig}->GetDNSSuffixes();
   if (defined $dnsSuffixList) {
      my $ncSuffixes = join(' ', @$dnsSuffixList);
      Utils::AddOrReplaceInFile($netconfigConfigFile,
                                'NETCONFIG_DNS_STATIC_SEARCHLIST=',
                                "NETCONFIG_DNS_STATIC_SEARCHLIST=\"$ncSuffixes\"");
   }

   # Create resolv.conf
   if ($useNetconfig) {
      # Force netconfig to overwrite resolv.conf
      Utils::ExecuteCommand('netconfig update -f');
   } else {
      # Override netconfig and edit resolv.conf directly
      $self->SUPER::CustomizeReslovFile();
   }
}

sub CustomizeDNSFromDHCP
{
   # SLES 11 /network/dhcp doesn't support the key DHCLIENT_MODIFY_RESOLV_CONF
   my ($self) = @_;

   # Fix DNS & DHCP
   my $dhcpfile = "$SuSECustomization::SUSEIFCFGDIR/dhcp";

   # Map the required parameters
   my @content = Utils::ReadFileIntoBuffer($dhcpfile);

   Utils::ReplaceOrAppendInLines(
      "DHCLIENT_SET_HOSTNAME[/s/t]*=.*",
      "DHCLIENT_SET_HOSTNAME=\"no\" \n",
      \@content,
      $Utils::SMDONOTSEARCHCOMMENTS);

   Utils::WriteBufferToFile($dhcpfile, \@content );
   Utils::SetPermission($dhcpfile, $Utils::RWRR);
}

sub EnablePostCustomizeGuestService
{
   # Using insserv for suse11 and above because chkconfig is giving warning message
   # causing Guest customziation to fail
   Utils::ExecuteCommand("insserv post-customize-guest");
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self) = @_;

   Utils::ExecuteCommand('nscd --shutdown');
   Utils::ExecuteCommand('/etc/init.d/network restart 2>&1');
}

1;
