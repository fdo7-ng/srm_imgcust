#!/usr/bin/perl

########################################################################################
#  Copyright 2008-2018 VMware, Inc.  All rights reserved.
########################################################################################

package SuSECustomization;
use base qw(Customization);

use strict;
use Debug;
use ConfigFile;

# Directory configuration for Suse
my $SUSESYSCONFIGDIR       = "/etc/sysconfig";
my $SUSENETWORKDIR         = $SUSESYSCONFIGDIR . "/config";
our $SUSEIFCFGDIR          = $SUSESYSCONFIGDIR . "/network";

# distro detection configuration files
my $SUSERELEASEFILE        = "/etc/SuSE-release";

# distro detection constants
my $SUSE                   = "SuSE Linux Distribution";

# distro flavour detection constants
my $SUSE_SLES              = "SuSE SLES";
my $SUSE_GENERIC           = "SuSE";

# Post-customization specific
our $POST_CUSTOMIZATION_AGENT_SLES           = "/etc/rc.d/post-customize-guest";

sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   my $SLES8RELEASEFILE = '/etc/lsb-release';

   if (-e $SUSERELEASEFILE) {
      $result = $SUSE;
   } elsif (-e $SLES8RELEASEFILE) {
      my $lsbContent = Utils::ExecuteCommand("cat $SLES8RELEASEFILE");

      if ($lsbContent =~ /UnitedLinux/i) {
         $result = $SUSE;
      }
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

   DEBUG("Reading issue file ... ");
   my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
   DEBUG($issueContent);

   if ($issueContent =~ /$SUSE_SLES/i) {
      $result = $SUSE_SLES;
   } elsif ($issueContent =~ /$SUSE_GENERIC/i) {
      $result = $SUSE_GENERIC;
   }

   return $result;
}

#........................................................................................
#
# InstallPostRebootAgentSles
#
#    Installs post-reboot customization agent as a service.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#........................................................................................
sub InstallPostRebootAgentSles
{
   my ($self, $currDir) = @_;
   INFO("Installing post-reboot customization agent for SLES...");

   if(not -e $POST_CUSTOMIZATION_AGENT_SLES) {
      INFO("Installing agent service");
      Utils::ExecuteCommand("$Utils::CP $currDir/scripts/post-customize-guest.sh $POST_CUSTOMIZATION_AGENT_SLES");
      Utils::ExecuteCommand("$Utils::CHMOD u+x $POST_CUSTOMIZATION_AGENT_SLES");
      $self->EnablePostCustomizeGuestService();
   } else {
      INFO("Agent service is already installed");
   }

   $Customization::runPostCustomizationBeforeReboot = 0;

   INFO("Installing post-reboot customization agent for SLES finished");
}

sub EnablePostCustomizeGuestService
{
   Utils::ExecuteCommand("chkconfig --add post-customize-guest");
}

sub InstallPostRebootAgent
{
   my ($self, $currDir) = @_;

   $self->InstallPostRebootAgentSles($currDir);
}

sub InitOldHostname
{
   my ($self) = @_;

   # The content of the /etc/HOSTNAME is Fully Qualified Domain Name.
   $self->{_oldHostName} = Utils::ExecuteCommand('cat /etc/HOSTNAME');
   chomp($self->{_oldHostName});
   Utils::Trim($self->{_oldHostName});

   INFO("OLD HOST NAME = $self->{_oldHostName}");
}

sub CustomizeNetwork
{
   my ($self) = @_;

   $self->CustomizeHostName();
}

sub CustomizeHostName
{
   my ($self) = @_;

   my $newHostName   = $self->{_customizationConfig}->GetHostName();
   my $newDomainName = $self->{_customizationConfig}->GetDomainName();

   my $changeHostFQDN = 0;

   if (ConfigFile::IsKeepCurrentValue($newHostName)) {
      $newHostName = Utils::GetShortnameFromFQDN($self->OldHostName());
   } else {
      $changeHostFQDN = 1;
   }

   if (ConfigFile::IsKeepCurrentValue($newDomainName)) {
      $newDomainName = Utils::GetDomainnameFromFQDN($self->OldHostName());
   } else {
      if (ConfigFile::IsRemoveCurrentValue($newDomainName)) {
         $newDomainName = '';
      }

      $changeHostFQDN = 1;
   }

   if ($changeHostFQDN) {
      if (! $newHostName) {
         die 'Cannot customize domain name only because ' .
             'the current hostname is invalid.';
      }

      my $newFQDN = $newHostName;

      if ($newDomainName) {
         $newFQDN .= ".$newDomainName";
      }

      my $hostNameFile = '/etc/HOSTNAME';
      Utils::WriteBufferToFile($hostNameFile, ["$newFQDN\n"]);
      Utils::SetPermission($hostNameFile, $Utils::RWRR);
   }
}

sub CleanupDefaultRoutes
{
   my ($self) = @_;

   INFO("Cleaning up default routes");
   my $ROUTES = $SUSEIFCFGDIR."/routes";
   if (-e $ROUTES) {
      Utils::ExecuteCommand("$Utils::CAT $ROUTES | $Utils::GREP -v default > $ROUTES.tmp");
      Utils::ExecuteCommand("$Utils::MV $ROUTES.tmp $ROUTES");
   } else {
      INFO("No routes file - nothing to clean");
   }
}

sub CustomizeNICS
{
   my ($self) = @_;

   # XXX
   # The dynamic device name assignment runs async to customization
   # Do not assume that dynamic device name assignment happens before customization
   # $self->ClearSuse10PersistentNameRules();

   # Wait for some time, so the dynamic name assignment ends before customization
   # FIX: Remove interface name dependency. Refer the interface by MAC address
   sleep(8);

   $self->CleanupDefaultRoutes();

   $self->SUPER::CustomizeNICS();
}

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # It is undesired that ip aliases persist after customization.
   # SuSe 8 allows that aliases are configured one per ifcfg-ethX:Y file.
   # Clean the aliases by removing their config files.
   my $macaddr   = $self->{_customizationConfig}->GetMACAddress($nic);
   my $interface = $self->GetInterfaceByMacAddress($macaddr);
   my $aliasConfigFilesPattern = $self->IFCfgFilePrefix() . $interface . ':*';
   Utils::DeleteFiles(glob($aliasConfigFilesPattern));

   # The existing interface config file may be ifcfg-eth-id-XX:XX:XX:XX:XX:XX.
   # If present it is preferred by getcfg over ifcfg-ethN as more device-specific.
   # Remove it so that the created by this code ifcfg-ethN is used.
   Utils::DeleteFiles($self->IFCfgFilePrefix() . 'eth-id-' . lc($macaddr),
                      $self->IFCfgFilePrefix() . 'eth-id-' . uc($macaddr));

   $self->SUPER::CustomizeSpecificNIC($nic);
}

#..............................................................................
#
#   ClearSuse10PersistentNameRules
#
#     Suse uses dynamic device names controlled by rules in /etc/udev/rules.d
#     When a device is first configured, a rule is added to one of the files
#     in this directory to ensure that the device will have the same
#     configuration name regardless of order of discovery or hotplugging. For
#     nics, each rule matches the MAC address to a specific ethX name.
#     When VMware clones a VM, we give the nics new MAC addresses, so after
#     the rules execute, the nics get new device names, so if the old nic
#     was eth0, the new one might get eth1, even though eth0 doesn't exist
#     anymore.
#
#     Unfortunately, the dynamic device name assignment doesn't run until after
#     customization, so this script would actually see eth0 for the new nic in
#     the above example, but when the nic is actually brought up on the next
#     boot, it comes up as eth1 and the configuration we generate here doesn't
#     match the device name.
#
#     The solution is to remove the old persistent name rules, and allow them
#     to be regenerated in the order of device discovery.
#
#     A better solution might be to write our own rules in the file and skip
#     the ifconfig -a discovery altogether, but since this is only applicable
#     to suse10, ifconfig is a more general way to do it.
#
#     See chapter 33 in http://www.novell.com/documentation/suse10/index.html
#     for details.
#
#..............................................................................

sub ClearSuse10PersistentNameRules()
{
   if (open RULES, "/etc/udev/rules.d/30-net_persistent_names.rules") {
      my @lines = grep !/SYSFS\{address}/, <RULES>;
      close RULES;
      open NORULES, "> /etc/udev/rules.d/30-net_persistent_names.rules";
      print NORULES @lines;
      close NORULES;
   }
};

sub FormatIFCfgContent
{
   my ($self, $nic ,$interface) = @_;

   my $onboot      = $self->{_customizationConfig}->Lookup($nic . "|ONBOOT");
   my $bootproto   = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");
   my $netmask     = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");
   my $ipaddr      = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");
   my $userctl     = $self->{_customizationConfig}->Lookup($nic . "|USERCTL");
   my $ipv4Mode    = $self->{_customizationConfig}->GetIpV4Mode($nic);

   my @content;

   push (@content, "DEVICE=$interface\n");

   if ($onboot =~ /yes/i) { #startup on boot
      push(@content, "STARTMODE=onboot\n");
   } else { #don't startup on boot
      push(@content, "STARTMODE=off\n");
   }

   # by default don't allow non-root users to control the interface
   $userctl = $userctl ? $userctl : "no";
   push(@content, "USERCONTROL=$userctl\n");

   # add common params to all distros

   # If there is a static IPv6, DHCPv6 one won't come up on SUSE12.

   if ($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
      # see /etc/sysconfig/network/ifcfg.template#BOOTPROTO

      # Since we currently don't distinguish between RA and DHCPv6 we need to make sure the latter
      # one works. Also static IPv6 seems to work under this setting too.
      $bootproto = 'dhcp6';

      INFO("$interface is IPv4-disabled with BOOTPROTO=$bootproto");

      push(@content, "BOOTPROTO=$bootproto\n");
   } else {
      push(@content, "BOOTPROTO=$bootproto\n");

      # netmask and ip address may be null if using "dhcp"
      if ($netmask) {
         push(@content, "NETMASK=$netmask\n");
      }
      if ($ipaddr) {
         push(@content, "IPADDR=$ipaddr\n");
      }
   }

   push(@content, $self->FormatIPv6IFCfgContent($nic));

   push(@content, $self->FormatIpMiscIfCfgContent($nic, $interface));

   return @content;
}

sub FormatIpMiscIfCfgContent
{
   my ($self, $nic, $interface) = @_;

   my @result = ();

   my $interfaceConfigFile = $self->IFCfgFilePrefix() . $interface;

   if (! -f $interfaceConfigFile) {
      return @result;
   }

   # Bug 1713444. The Guest customization needs to preserve
   # the MTU setting for the NIC. In future, when needed, we need
   # to add new misc settings to the following list.
   my @miscIPSettings = ("MTU");
   my %miscIPSettingsMap = map { $_ => 1} @miscIPSettings;

   my @content =
      Utils::ReadFileIntoBuffer($interfaceConfigFile);

   foreach (@content) {
      chomp($_);
      if (Utils::GetLineWithoutComments($_) =~ /^\s*([a-zA-Z0-9]+)\s*=/) {
         if (exists($miscIPSettingsMap{$1})) {
            push(@result, $_ . "\n");
         }
      }
   }

   return @result;
}

sub FormatIPv6IFCfgContent
{
   my ($self, $nic) = @_;

   my @result = ();

   my @ipv6Addresses =
      ConfigFile::ConvertToIndexedArray(
         $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));

   my @ipv6Netmasks =
      ConfigFile::ConvertToIndexedArray(
         $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));

   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   if (@ipv6Settings) {
      for (my $index = 0; $index <= $#ipv6Settings; $index++) {
         my $addr =  $ipv6Settings[$index]->[0] . '/' . $ipv6Settings[$index]->[1];
         push(@result, "IPADDR$index=$addr\n");
      }
   }

   return @result;
}

sub AddRoute
{
   my ($self, $interface, $ipv4Gateways, $ipv6Gateways, $nic) = @_;

   my $primaryNic = $self->{_customizationConfig}->GetPrimaryNic();
   if (defined $primaryNic) {
      # This code will not be called for DHCP primary NIC, since Gateways will
      # be empty, so there will be no invalid global record as in T2.
      if ($primaryNic ne $nic) {
         INFO("Skipping default routes non-primary NIC '$nic'");
         return 0;
      } else {
         INFO("Configuring route from the primary NIC '$nic'");
      }
   } else {
      INFO("No primary NIC defined. Adding all routes as default.");
   }

   INFO("Configuring route (gateway settings) for '$interface'.");

   my @lines;

   my $ipv4Mode = $self->{_customizationConfig}->GetIpV4Mode($nic);

   if (!($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED)) {
      # IPv4 gateways
      foreach (@$ipv4Gateways) {
         INFO("Configuring route $_");
         push(@lines, "default " . $_ . " - " . $interface ."\n");
      }
   }

   # IPv6 gateways
   foreach (@$ipv6Gateways) {
      INFO("Configuring route $_");
      push(@lines, "default " . $_ . " - " . $interface ."\n");
   }

   # Append it to the file
   Utils::AppendNotContainedLinesToFile($SUSEIFCFGDIR  . "/routes", \@lines);
};

sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   # Fix DNS & DHCP
   my $dhcpfile = $SUSESYSCONFIGDIR . "/network/dhcp";

   # Map the required parameters
   my @content = Utils::ReadFileIntoBuffer($dhcpfile);

   Utils::ReplaceOrAppendInLines(
      "DHCLIENT_SET_HOSTNAME[/s/t]*=.*",
      "DHCLIENT_SET_HOSTNAME=no \n",
      \@content,
      $Utils::SMDONOTSEARCHCOMMENTS);

   my $dnsFromDHCP = $self->{_customizationConfig}->GetDNSFromDHCP() ? "yes" : "no";

   Utils::ReplaceOrAppendInLines(
      "DHCLIENT_MODIFY_RESOLV_CONF[/s/t]*=.*",
      "DHCLIENT_MODIFY_RESOLV_CONF=\"$dnsFromDHCP\"\n",
      \@content,
      $Utils::SMDONOTSEARCHCOMMENTS);

   # Whether to merge the resolv.conf search list with the sent by DHCP
   Utils::ReplaceOrAppendInLines(
      "DHCLIENT_KEEP_SEARCHLIST[/s/t]*=.*",
      "DHCLIENT_KEEP_SEARCHLIST=\"$dnsFromDHCP\"\n",
      \@content,
      $Utils::SMDONOTSEARCHCOMMENTS);

   Utils::WriteBufferToFile($dhcpfile, \@content );
   Utils::SetPermission($dhcpfile, $Utils::RWRR);

   # Remove these files as stopping dhcpcd will restore them and overwrite our
   # changes to resolv.conf; On SLES10 file ends with ifname and doesn't on SLES 8.
   Utils::DeleteFiles(glob("$Customization::RESOLVFILE.saved.by.dhcpcd*"));
}

sub SetTimeZone
{
   my ($self, $tz) = @_;

   Utils::ExecuteCommand("ln -sf /usr/share/zoneinfo/$tz /etc/localtime");
   Utils::AddOrReplaceInFile(
      '/etc/sysconfig/clock',
      '^\s*TIMEZONE=',
      "TIMEZONE=\"$tz\"",
      $Utils::SMDONOTSEARCHCOMMENTS);
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   my $utc = ($cfgUtc =~ /yes/i) ? "-u" : "--localtime";

   Utils::AddOrReplaceInFile(
      '/etc/sysconfig/clock',
      '^\s*HWCLOCK=',
      "HWCLOCK=\"$utc\"",
      $Utils::SMDONOTSEARCHCOMMENTS);
}

# Base properties overrides

sub OldHostName
{
   my ($self) = @_;

   return $self->{_oldHostName};
}

sub IFCfgFilePrefix
{
   my ($self) = @_;

   return $SUSEIFCFGDIR . "/ifcfg-";
};

1;
