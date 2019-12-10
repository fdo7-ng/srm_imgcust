#!/usr/bin/perl

################################################################################
#  Copyright 2008-2018 VMware, Inc.  All rights reserved.
################################################################################

package RedHatCustomization;
use base qw(Customization);

use strict;
use Debug;
use ConfigFile;

# Directory configurations for Redhat
my $RHSYSCONFIGDIR         = "/etc/sysconfig";
my $RHNETWORKDIR           = $RHSYSCONFIGDIR . "/network";
my $RHIFCFGDIR             = $RHSYSCONFIGDIR . "/network-scripts";

# distro detection configuration files
our $REDHATRELEASEFILE      = "/etc/redhat-release";

# distro detection constants
my $REDHAT                 = "RedHat Linux Distribution";

# distro flavour detection constants
my $RHEL_AS2               = "Red Hat Advanced Linux Server";
my $RHEL_ES2               = "Red Hat Enterprise Server";
our $RHEL3                 = "Red Hat Enterprise Linux";
our $REDHAT_GENERIC        = "Red Hat";
our $RHEL_21               = "Red Hat Enterprise Linux 2.1";
our $CENTOS_GENERIC        = "Cent OS";
our $OLINUX_GENERIC        = "Oracle Linux";


sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   if (-e $REDHATRELEASEFILE) {
      $result =  $REDHAT;
   }

   return $result;
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red\s*Hat\s*Enterprise\s*Linux.*?2\.1/i) {
      $result = $RHEL_21;
   } elsif ($content =~ /$RHEL_AS2/i) {
      $result = $RHEL_AS2;
   } elsif ($content =~ /$RHEL_ES2/i) {
      $result = $RHEL_ES2;
   } elsif ($content =~ /$RHEL3/i) {
      $result = $RHEL3;
   } elsif ($content =~ /$REDHAT_GENERIC/i) {
      $result = $REDHAT_GENERIC;
   } elsif ($content =~ /CentOS.*?release/i) {
      $result = $CENTOS_GENERIC;
   }  elsif ($content =~ /Oracle.*?release/i) {
      $result = $OLINUX_GENERIC;
   }

   return $result;
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

   # beta versions has /etc/issue file contents of form
   # \S
   # Kernel \r on an \m
   if(! defined $result) {
      if (-e $RedHatCustomization::REDHATRELEASEFILE) {
         DEBUG("Reading redhat-release file ... ");
         my $releaseContent = Utils::ExecuteCommand(
            "cat $RedHatCustomization::REDHATRELEASEFILE");
         DEBUG($releaseContent);
         $result = $self->FindOsId($releaseContent);
      } else {
         WARN("RedHat release file not available. Ignoring it.");
      }
   }

   if (defined $result) {
      DEBUG("Detected flavor: '$result'");
   } else {
      WARN("Redhat flavor not detected");
   }

   return $result;
}

sub InstallPostRebootAgent
{
   my ($self, $currDir) = @_;
   my $rclocal;

   INFO("Resolving rc.local using readlink");
   $rclocal = Utils::Trim(Utils::ExecuteCommand("$Utils::READLINK -f $Customization::RC_LOCAL"));
   $self->InstallPostRebootAgentGeneric($currDir, $rclocal);
}

sub InitOldHostname
{
   my ($self) = @_;

   $self->{_oldHostName} =
      Utils::GetValueFromFile(
         $RHNETWORKDIR,
         'HOSTNAME[\s\t]*=(.*)');

   INFO ("OLD HOST NAME = $self->{_oldHostName}");
}

#...............................................................................
#
# ReadExistingIPv6Settings
#
#     Reads IPv6 settings from the original interface file in order to be preserved later.
#
#     This is because the current design requires regenerating ifcfg-* files, so whenever
#     we can't (for some reason) to come up with a reasonable value, we'll try to use the
#     original one.
#
# Params & Result:
#     None
#
#...............................................................................

sub ReadExistingIPv6Settings
{
   my ($self) = @_;

   my $file;
   my @files = </etc/sysconfig/network-scripts/ifcfg-*>;
   foreach $file (@files) {
      if (-e $file) {
         my $interface = substr($file, length('/etc/sysconfig/network-scripts/ifcfg-'));

         my $value;

         $value = Utils::GetValueFromFile($file, '^DHCPV6C.*?=.*?(yes|no)');
         DEBUG("DHCPV6C is '$value'");
         if (defined $value) {
            $self->{_networkData}->{$interface . '.' . 'DHCPV6C'} = $value;
         }

         $value = Utils::GetValueFromFile($file, '^DHCPV6C_OPTIONS.*?=(.*?)$');
         DEBUG("DHCPV6C_OPTIONS is '$value'");
         if (defined $value) {
            $self->{_networkData}->{$interface . '.' . 'DHCPV6C_OPTIONS'} = $value;
         }

         $value = Utils::GetValueFromFile($file, '^IPV6_AUTOCONF.*?=.*?(yes|no)');
         DEBUG("IPV6_AUTOCONF is '$value'");
         if (defined $value) {
            $self->{_networkData}->{$interface . '.' . 'IPV6_AUTOCONF'} = $value;
         }

         $value = Utils::GetValueFromFile($file, '^IPV6INIT.*?=.*?(yes|no)');
         DEBUG("IPV6INIT is '$value'");
         if (defined $value) {
            $self->{_networkData}->{$interface . '.' . 'IPV6INIT'} = $value;
         }
      } else {
         DEBUG("'$file' does not exist or is a broken symlink");
      }
   }
}

sub ReadNetwork
{
   my ($self) = @_;

   $self->{_networkData} = {};

   $self->ReadExistingIPv6Settings();
}

sub CustomizeNetwork
{
   my ($self) = @_;

   RemoveDHCPState();

   ClearCachedNetworkConfig();

   $self->CustomizeNetworkFile();
}

sub RemoveDHCPState
{
   # Erase any saved leases given by dhcp so that they are not reused.
   INFO("Erasing DHCP leases");
   Utils::ExecuteCommand("pkill dhclient");
   Utils::ExecuteCommand("rm -f /var/lib/dhcp/*");
   # DHCPv6 leases are stored in this folder on RHEL6+
   Utils::ExecuteCommand("rm -f /var/lib/dhclient/*");
}

sub ClearCachedNetworkConfig
{
   # The /etc/sysconfig/networking/ directory is used by
   # the Network Administration Tool (redhat-config-network) and
   # its contents should not be edited manually
   # When started for the 1st time the GUI network manager creates a copy of
   # network settings that are applied.
   # Any following changing of settings at the original locations has no effect.
   INFO("Resetting Network Administration Tool (redhat-config-network)");
   Utils::ExecuteCommand("rm -rf /etc/sysconfig/networking/devices");
   Utils::ExecuteCommand("rm -rf /etc/sysconfig/networking/profiles");
}

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # It is undesired that ip aliases persist after customization.
   # RedHat keeps one alias per ifcfg-ethX:Y file.
   # Clean the aliases by removing their config files.
   my $macaddr   = $self->{_customizationConfig}->GetMACAddress($nic);
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC (MAC address = $macaddr)";
   };

   my $aliasConfigFilesPattern = $self->IFCfgFilePrefix() . $interface . ':*';
   Utils::DeleteFiles(glob($aliasConfigFilesPattern));

   my $ifConfigFile = $self->IFCfgFilePrefix() . $interface;
   if (-l $ifConfigFile) {
      DEBUG("$ifConfigFile is a symlink");
      if (!-e $ifConfigFile) {
         # on CentOs 6.3/5.6 this could point to /etc/sysconfig/networking/devices
         # which we already deleted
         DEBUG("$ifConfigFile symlink is broken, deleting it");
         (unlink($ifConfigFile) == 1) || die "File $ifConfigFile could not be deleted - $!";
      }
   }

   $self->SUPER::CustomizeSpecificNIC($nic);
}

sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   # For older RHEL dhcp client configuration should be in dhlcient-<IF>.conf for every
   # interface rather than one common dhlcient.conf; Newer RHELs support the old way
   for my $nic ($self->{_customizationConfig}->GetNICs()) {
      my $macaddr = $self->{_customizationConfig}->GetMACAddress($nic);
      $self->{_dhclientConfPathIFName} = $self->GetInterfaceByMacAddress($macaddr);
      $self->SUPER::CustomizeDNSFromDHCP();
   }

   # Remove this file as when stopped dhcpcd will restore it and overwrite the changes
   # we made to resolv.conf
   Utils::DeleteFiles("$Customization::RESOLVFILE.sv")
}

sub FormatIFCfgContent
{
   my ($self, $nic ,$interface) = @_;

   # get the params
   my $onboot      = $self->{_customizationConfig}->Lookup($nic . "|ONBOOT");
   my $bootproto   = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");
   my $netmask     = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");
   my $ipaddr      = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");
   my $dnsfromdhcp = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");
   my $userctl     = $self->{_customizationConfig}->Lookup($nic . "|USERCTL");
   my $ipv4Mode    = $self->{_customizationConfig}->GetIpV4Mode($nic);

   my $macaddr = $self->{_customizationConfig}->GetMACAddress($nic);
   my @content;

   push (@content, "DEVICE=$interface\n");
   #PR2046566, some customer want to keep MAC address in config file,
   #Otherwise nic order may change after customization
   push(@content, "HWADDR=$macaddr\n");

   # by default don't allow non-root users to control the interface
   $userctl = $userctl ? $userctl : "no";
   push(@content, "ONBOOT=$onboot\n");

   push(@content, "USERCTL=$userctl\n");

   # add common params to all distros

   # If DHCPV6C is set to 'yes', static IPv6 won't come up on RHEL6.4.

   if ($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
      INFO("Marking $interface as IPv4-disabled (BOOTPROTO=none)");
      $bootproto = 'none';

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

   # DNS from DHCP settings for Redhat
   push(@content, "PEERDNS=$dnsfromdhcp\n");

   push(@content, $self->FormatIPv6IFCfgContent($nic));

   # insert the check link fix for vlance card
   push (@content, "\ncheck_link_down() {\n return 1; \n}\n" );

   return @content;
}

#...............................................................................
#
# RestoreExistingIPv6Settings
#
#     Restores IPv6 settings from the original interface file.
#
#     Since we currently regenerate ifcfg-* files and don't really have the proper API
#     support to handle any combination of static/RA/DHCPv6 as permitted by RFC, we
#     simply rely on the user to configure whatever he wants on the template level and
#     only take care of putting in/taking out static values ourselves.
#
# Params:
#   $nic        NIC to be examined
#   $resultRef  reference to the array of the outgoing settings
#   $static     whether there are any static IPv6 addresses to be applied
#
#...............................................................................

sub RestoreExistingIPv6Settings
{
   my ($self, $nic, $resultRef, $static) = @_;

   my $macaddr = $self->{_customizationConfig}->GetMACAddress($nic);
   my $if = $self->GetInterfaceByMacAddress($macaddr);

   if (not $static) {
      if (defined $self->{_networkData}{$if . '.' . 'IPV6INIT'}) {
         INFO('Applying IPV6INIT from the original configuration');
         push(@$resultRef, 'IPV6INIT=' . $self->{_networkData}{$if . '.' . 'IPV6INIT'} . "\n");
      }
   }

   if (defined $self->{_networkData}{$if . '.' . 'DHCPV6C'}) {
      INFO('Applying DHCPV6C from the original configuration');
      push(@$resultRef, 'DHCPV6C=' . $self->{_networkData}{$if . '.' . 'DHCPV6C'} . "\n");
   }

   if (defined $self->{_networkData}{$if . '.' . 'DHCPV6C_OPTIONS'}) {
      INFO('Applying DHCPV6C_OPTIONS from the original configuration');
      push(@$resultRef, 'DHCPV6C_OPTIONS=' . $self->{_networkData}{$if . '.' . 'DHCPV6C_OPTIONS'} . "\n");
   }

   if (defined $self->{_networkData}{$if . '.' . 'IPV6_AUTOCONF'}) {
      INFO('Applying IPV6_AUTOCONF from the original configuration');
      push(@$resultRef, 'IPV6_AUTOCONF=' . $self->{_networkData}{$if . '.' . 'IPV6_AUTOCONF'} . "\n");
   }
}

sub FormatIPv6IFCfgContent
{
   my ($self, $nic) = @_;

   my @ipv6Addresses =
      ConfigFile::ConvertToIndexedArray(
         $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));

   my @ipv6Netmasks =
      ConfigFile::ConvertToIndexedArray(
         $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));

   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   my @result = ();

   if (@ipv6Settings) {
      push(@result, "IPV6INIT=yes\n");
      push(
         @result,
         'IPV6ADDR=' . $ipv6Settings[0]->[0] . '/' . $ipv6Settings[0]->[1] . "\n");
      push(
         @result,
         'IPV6ADDR_SECONDARIES="' .
         join(' ', map { $_->[0] . '/' . $_->[1] } @ipv6Settings[1 .. $#ipv6Settings])
         . "\"\n");
   }

   $self->RestoreExistingIPv6Settings($nic, \@result, (@ipv6Settings ? 1 : 0));

   return @result;
}

sub AddRoute
{
   my ($self, $interface, $ipv4Gateways, $ipv6Gateways) = @_;

   INFO("Configuring route (gateway settings) for $interface.");

   # IPv4 gateways
   my @ipv4Lines = map {INFO("Configuring route $_"); "default via $_\n"} @$ipv4Gateways;
   Utils::WriteBufferToFile($RHIFCFGDIR . "/route-" . $interface, \@ipv4Lines);

   # IPv6 gateways
   my @ipv6Lines = map {INFO("Configuring route $_"); "default via $_\n"} @$ipv6Gateways;
   Utils::WriteBufferToFile($RHIFCFGDIR . "/route6-" . $interface, \@ipv6Lines);
};

sub CustomizeNetworkFile
{
   my ($self) = @_;

   # map the required environment variables into less cryptic local variable names
   my $netconfigfile = $RHSYSCONFIGDIR . "/network";
   my $networking    = $self->{_customizationConfig}->Lookup('NETWORK|NETWORKING');
   my $hostname      = $self->{_customizationConfig}->GetHostName();

   # Hostname is optional
   if (ConfigFile::IsKeepCurrentValue($hostname)) {
      $hostname = $self->OldHostName();
   }

   # check if all the required params are there
   if (!$networking) {
      ERROR("Insufficient information under [NETWORK].");
      ERROR("NETWORKING is required.");
      die("Insufficient information for customization.\n");
   }

   my $primaryNic = $self->{_customizationConfig}->GetPrimaryNic();
   my $primaryNicGw = undef;
   my $primaryNicProto = undef;
   my $primaryNicInterface = undef;
   if (defined $primaryNic) {
      # get the interface
      my $macaddr = $self->{_customizationConfig}->GetMACAddress($primaryNic);
      INFO("Primary NIC is $macaddr");
      $primaryNicProto = $self->{_customizationConfig}->GetBootProto($primaryNic);
      my $primaryNicIpv4Mode = $self->{_customizationConfig}->GetIpV4Mode($primaryNic);
      if ($primaryNicIpv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
         INFO("Primary NIC is IPv4-disabled (BOOTPROTO=none), GATEWAY won't be set");
         $primaryNicProto = 'none';
      }
      my @gws = $self->{_customizationConfig}->GetGateways($primaryNic);
      $primaryNicGw = $gws[0];
      $primaryNicInterface = $self->GetInterfaceByMacAddress($macaddr);

      if (!$primaryNicInterface) {
         die "Error finding the specified NIC (MAC address = $macaddr)";
      };
   } else {
      INFO("Primary NIC is not defined");
   }

   # read the contents of the network configuration file
   my @content = Utils::ReadFileIntoBuffer($netconfigfile);
   my @newContent = ();
   my $networkAdded = 0;
   my $hostnameAdded = 0;
   my $gwDevAdded = 0;
   my $gwHandled = 0;

   foreach my $verbatimLine (@content) {
      DEBUG("Line : $verbatimLine");

      my $line = Utils::GetLineWithoutComments($verbatimLine);

      if ($line =~ /NETWORKING\s*=/) {
         push @newContent, "NETWORKING=$networking\n";
         $networkAdded = 1;
      } elsif ($line =~ /HOSTNAME\s*=/) {
         push @newContent, "HOSTNAME=$hostname\n";
         $hostnameAdded = 1;
      } elsif ((defined $primaryNic) and ($line =~ /GATEWAYDEV\s*=/)) {
         push @newContent, "GATEWAYDEV=$primaryNicInterface\n";
         $gwDevAdded = 1;
         INFO("Found GATEWAYDEV and patched with $primaryNicInterface");
      } elsif ((defined $primaryNic) and ($line =~ /GATEWAY\s*=/)) {
         INFO("Found GATEWAY");
         # for DHCP the line should be deleted
         if ($primaryNicProto =~ /static/i) {
            push @newContent, "GATEWAY=$primaryNicGw\n";
            INFO("Patched with $primaryNicGw");
         }
         $gwHandled = 1;
      } else {
         push @newContent, $verbatimLine;
      }
   }

   if (not $networkAdded) {
      push @newContent, "NETWORKING=$networking\n";
   }

   if (not $hostnameAdded) {
      push @newContent, "HOSTNAME=$hostname\n";
   }

   if ((defined $primaryNic) and (not $gwDevAdded)) {
      push @newContent, "GATEWAYDEV=$primaryNicInterface\n";
      INFO("GATEWAYDEV not found, created with $primaryNicInterface");
   }

   if ((defined $primaryNic) and (not $gwHandled)) {
        INFO("GATEWAY not found");
      # for DHCP the line should not be added
      if ($primaryNicProto =~ /static/i) {
         push @newContent, "GATEWAY=$primaryNicGw\n";
         INFO("Created with $primaryNicGw");
      }
   }

   # write to file
   Utils::WriteBufferToFile($netconfigfile, \@newContent);
   Utils::SetPermission($netconfigfile, $Utils::RWRR);

   # run hostname command to refresh the hostname for this session
   Utils::ExecuteCommand("hostname $hostname");
};

sub SetTimeZone
{
   my ($self, $tz) = @_;
   # As per PR 1650517, timezone for RHEL atomic guest OS was not getting set
   # properly. So the fix suggested by RHEL dev team is implemented.
   # SYSTEMD_IGNORE_CHROOT is set to 1 in RHEL atomic guest OS.
   if(defined $ENV{'SYSTEMD_IGNORE_CHROOT'}) {
      Utils::ExecuteCommand(
         "ln -sf /usr/share/zoneinfo/$tz /host/etc/localtime");
   } else {
      Utils::ExecuteCommand("ln -sf /usr/share/zoneinfo/$tz /etc/localtime");
   }
   Utils::AddOrReplaceInFile(
      "/etc/sysconfig/clock",
      "ZONE",
      "ZONE=\"$tz\"",
      $Utils::SMDONOTSEARCHCOMMENTS);
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   my $utc = ($cfgUtc =~ /yes/i) ? "true" : "false";

   Utils::AddOrReplaceInFile(
      "/etc/sysconfig/clock",
      "UTC",
      "UTC=$utc",
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

   return $RHIFCFGDIR .  "/ifcfg-";
};

sub DHClientConfPath
{
   my ($self) = @_;
   return "/etc/dhclient-$self->{_dhclientConfPathIFName}.conf";
}

# Param ipAddrResult is used in the unit tests.
# Do not drop it otherwise unit tests would fail.
sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ipAddrResult) = @_;

   return $self->GetInterfaceByMacAddressIPAddrShow($macAddress, $ipAddrResult);
}

#...............................................................................
#
# GetMACAddresses
#
#   Find out the MAC addresses of the NICs.
#
# Result:
#   The MAC addresses in an array.
#...............................................................................

sub GetMACAddresses
{
   my ($self) = @_;

   my $ipAddrResult = Utils::ExecuteCommand('/sbin/ip addr show');
   my @macs = ();

   while ($ipAddrResult =~ /link\/ether\s(\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2})/g) {
      my $mac = $1;
      my $interface = $self->GetInterfaceByMacAddress($mac);
      if ($interface =~ /^vir/) {
         next; # skip virtual interfaces by KVMs.
      }
      push(@macs, $mac);
   }

   return @macs;
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self)  = @_;

   my @macs = $self->GetMACAddresses();

   foreach my $mac (@macs) {
      my $if = $self->GetInterfaceByMacAddress($mac);
      if ($if) {
          Utils::ExecuteCommand("ifdown $if 2>&1 && ifup $if 2>&1");
      }
   }
}

1;
