#!/usr/bin/perl

################################################################################
#  Copyright 2015-2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# Customization.pm
#
#  This module implements a framework for OS customization.
#
#...............................................................................

package Customization;

use strict;
use Debug;
use Utils qw();
use StdDefinitions qw();
use TimezoneDB qw();
use File::Temp qw/ tempfile /;

# By design GOSC normally should be executed within 1-5 sec, because it affects
# the provisioning time. The absolute pessimistic scenario is 100 sec currently
# hard-coded in linuxDeployment.c. To achieve that we don't want any individual
# command to take longer than 5 sec.
our $MAX_CMD_TIMEOUT = 5;

# Network specific
our $HOSTNAMEFILE          = "/etc/HOSTNAME";
our $HOSTSFILE             = "/etc/hosts";
our $RESOLVFILE            = "/etc/resolv.conf";

# Distro detection configuration files
our $ISSUEFILE             = "/etc/issue";

# Password specific
our $SHADOW_FILE = '/etc/shadow';
our $SHADOW_FILE_COPY = "$SHADOW_FILE.copy";

# Post-customization specific
# We rely on /etc/rc.local for the most cases as it's available or is a symlink in most distributives.
# TODO [aneverov] investigate possibility of using "chkconfig" on RHEL when it's available as it's more consistent
our $RC_LOCAL                                = "/etc/rc.local";
our $RC_LOCAL_TMP                            = "${RC_LOCAL}.tmp";
our $CUSTOMIZATION_TMP_DIR                   = "/tmp/.vmware/linux/deploy";
our $POST_CUSTOMIZATION_TMP_DIR              = "/root/.customization";
our $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME  = "$POST_CUSTOMIZATION_TMP_DIR/post-customize-guest.sh";
our $POST_CUSTOMIZATION_TMP_SCRIPT_NAME      = "$POST_CUSTOMIZATION_TMP_DIR/customize.sh";

our $POST_REBOOT_PENDING_MARKER              = "/.guest-customization-post-reboot-pending";

our $runPostCustomizationBeforeReboot        = 1;

#...............................................................................
#
# new
#
#     Constructor
#
# Input:
#     None
#
# Result:
#     Returns the customization object.
#
#...............................................................................

sub new
{
   my $class = shift;
   my $self = {};
   # Initialize the result to CUST_GENERIC_ERROR, so that if any lower layer
   # code throws an exception, the result correctly reflects an error.
   $self->{_customizationResult} = $StdDefinitions::CUST_GENERIC_ERROR;
   bless $self, $class;
   return $self;
}

#...............................................................................
#
# DetectDistro
#
#     Detects the OS distro.
#
# Input:
#     None
#
# Result:
#     Returns the distro name if supported by the customization object, otherwise undef.
#
#...............................................................................

sub DetectDistro
{
   die "DetectDistro not implemented";
}

#...............................................................................
#
# DetectDistroFlavour
#
#     Detects the flavour of the distribution.
#     Currently no decision is based on the flavour.
#     Must be called after the distro is detected by DetectDistro method.
# Params:
#     None
#
# Result:
#     Returns the distribution flavour if the distro is supported by
#     the customization object, otherwise undef.
#
#...............................................................................

sub DetectDistroFlavour
{
   die "DetectDistroFlavour not implemented";
}

#...............................................................................
#
# Customize
#
#     Customizes the guest using the passed customization configuration.
#     Must be called after the distro is detected by DetectDistro method.
#
# Params:
#     $customizationConfig  ConfigFile instance
#     $directoryPath        Path to the root of the deployed package
#
# Result:
#     None.
#
#...............................................................................

sub Customize
{
   my ($self, $customizationConfig, $directoryPath) = @_;

   $self->{_customizationResult} = $StdDefinitions::CUST_GENERIC_ERROR;

   if (defined $customizationConfig) {
      $self->{_customizationConfig} = $customizationConfig;
   } else {
      die "Customize called with an undefined customization configuration";
   }

   $self->InitGuestCustomization();

   $self->CustomizeGuest($directoryPath);

   $self->{_customizationResult} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# RefreshNics
#
#     Refresh the Nics in the kernel.
#     The instant cloned VM shall get new MAC addresses. However, the guest
#     kernel still caches the old MAC addresses. The function does the
#     refresh.
#     Note: reloading the driver does not always work. Experiments show
#     that the driver reload method works for e1000 but not for vmxnet, and
#     vmxnet3.
#     The proven method is to use the /sys virtual file system to achieve the
#     MAC refresh.
#
# Params:
#     $self  this object.
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................
sub RefreshNics
{
   my ($self) = @_;

   my @netFiles = </sys/class/net/*>;

   foreach my $netPath (@netFiles) {
      if (not -l "$netPath/device") {
         # Skip virtual interfaces such as vpn, lo, and vmnet1/8
         next;
      }
      my $dev = Utils::ExecuteCommand("readlink -f \"$netPath/device\"");
      $dev = Utils::Trim($dev);

      my $busid = Utils::ExecuteCommand("basename \"$dev\"");
      $busid = Utils::Trim($busid);

      my $driverPath = Utils::ExecuteCommand("readlink -f \"$dev/driver\"");
      $driverPath = Utils::Trim($driverPath);

      Utils::ExecuteCommand("echo $busid > \"$driverPath\"/unbind");
      Utils::ExecuteCommand("echo $busid > \"$driverPath\"/bind");

      # TBD: Add verification once VC can pass down the new MAC addresses.
   }
}

#...............................................................................
#
# InstantCloneCustomize
#
#     InstantClone flavor of Guest Customization.
#
# Params:
#     $customizationConfig  ConfigFile instance
#     $directoryPath        Path to the guest customization scripts
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................

sub InstantCloneCustomize
{
   my ($self, $customizationConfig, $directoryPath) = @_;

   $self->{_customizationConfig} = $customizationConfig;
   $self->InitGuestCustomization();

   INFO("Refreshing MAC addresses ... ");
   eval {
      $self->RefreshNics();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_REFRESH_ERROR;
      die $@;
   }

   INFO("Customizing network settings ... ");
   eval {
      $self->ReadNetwork();
      $self->CustomizeNetwork();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NETWORK_ERROR;
      die $@;
   }

   INFO("Customizing NICS ... ");
   eval {
      $self->CustomizeNICS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing the hosts file ... ");
      $self->CustomizeHostsFile($HOSTSFILE);

      INFO("Customizing DNS ... ");
      $self->CustomizeDNS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DNS_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing date and time ... ");
      $self->CustomizeDateTime();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DATETIME_ERROR;
      die $@;
   }

   # Customization of password not required, TBD XXX

   $self->{_customizationResult} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# InitGuestCustomization
#
#    This method is called prior to the customization.
#
# Params:
#     None
#
# Result:
#     None
#
#...............................................................................

sub InitGuestCustomization
{
   my ($self) = @_;

   $self->{_oldHostnameCmd} = Utils::ExecuteCommand('hostname 2>/dev/null');
   chomp ($self->{_oldHostnameCmd});

   $self->{_oldResolverFQDN} = GetResolverFQDN();

   $self->InitOldHostname();
}

#...............................................................................
#
# InitOldHostname
#
#    This method inits the old host name taken from config file.
#
# Params:
#     None
#
# Result:
#     None
#
#...............................................................................

sub InitOldHostname
{
   die "InitOldHostname not implemented";
}

#...............................................................................
#
# CustomizePassword
#
#    Sets and/or resets root password.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................

sub CustomizePassword
{
   my ($self, $currDir) = @_;
   my $exitCode;
   my $setPassword = 1;

   $currDir = "$currDir/scripts";

   my $resetPassword = $self->{_customizationConfig}->GetResetPassword();
   my $adminPassword = $self->{_customizationConfig}->GetAdminPassword();

   if (!defined $adminPassword) {
      $setPassword = 0;
   }
   if ($setPassword == 1 || $resetPassword == 1) {
      INFO("Changing the password...");
      Utils::ExecuteCommand("$Utils::CP -f $SHADOW_FILE $SHADOW_FILE_COPY");
      # resetpwd.awk was part of Toledo and T2 VCD releases and copied "as is"
      # it operates in temporary files and provides 5 ways to change/reset root password
      Utils::ExecuteCommand(
         "$Utils::AWK -v expirepassword=$resetPassword -v setpassword=$setPassword -v password=$adminPassword -f ${currDir}/resetpwd.awk $SHADOW_FILE_COPY",
         'password utils',
         \$exitCode,
         1); #secure
      if ($exitCode != 0) {
         die "Unable to expire password for root users OR set password for root user";
      }
      Utils::ExecuteCommand("$Utils::RM $SHADOW_FILE_COPY");
      INFO("Changing the password is complete");
   } else {
      INFO("Changing password is not needed");
   }
}

#...............................................................................
#
# InstallPostRebootAgentGeneric
#
#    Installs post-reboot customization agent into rc.local.
#
# Params:
#    $currDir     Path to the root of the deployed package
#    $rclocal     Path to rc.local
#
# Result:
#    None
#
#...............................................................................
sub InstallPostRebootAgentGeneric
{
   my ($self, $currDir, $rclocal) = @_;
   my $exitCode;

   INFO("Installing post-reboot customization agent from '$currDir' to '$rclocal'...");

   if(-e $RC_LOCAL) {
      Utils::ExecuteCommand("$Utils::CP $currDir/scripts/post-customize-guest.sh $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME");

      INFO("Checking rc.local for previous customization agent installation...");
      Utils::ExecuteCommand("$Utils::GREP '# Run post-reboot guest customization' $rclocal", 'grep for agent', \$exitCode);
      if ($exitCode != 0) {
         INFO("Adding post-reboot guest customization agent to rc.local");
         Utils::ExecuteCommand("$Utils::GREP -v \"exit 0\" $rclocal > $RC_LOCAL_TMP");
         Utils::ExecuteCommand("$Utils::ECHO >> $RC_LOCAL_TMP");
         Utils::ExecuteCommand("$Utils::ECHO \"# Run post-reboot guest customization\" >> $RC_LOCAL_TMP");
         Utils::ExecuteCommand("$Utils::ECHO \"$Utils::SH $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME\" >> $RC_LOCAL_TMP");
         Utils::ExecuteCommand("$Utils::ECHO \"exit 0\" >> $RC_LOCAL_TMP");
         Utils::ExecuteCommand("$Utils::MV $RC_LOCAL_TMP $rclocal");
         # "x" flag should be set
         Utils::ExecuteCommand("$Utils::CHMOD u+x $rclocal");
         Utils::ExecuteCommand("$Utils::CHMOD u+x $RC_LOCAL");
      } else {
         INFO("Post-reboot guest customization agent is already registered in rc.local");
      }

      $runPostCustomizationBeforeReboot = 0;
   } else {
      WARN("Can't find rc.local, post-customization will be run before reboot");
   }

   INFO("Installing post-reboot customization agent finished: $runPostCustomizationBeforeReboot");
}

#...............................................................................
#
# InstallPostRebootAgentUnknown
#
#    Installs post-reboot customization agent for unknown Linux. Normally isn't
#    used.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................
sub InstallPostRebootAgentUnknown
{
   my ($self, $currDir) = @_;
   my $rclocal;

   INFO("Installing post-reboot customization agent for unknown Linux from '$currDir'...");

   if(-e $RC_LOCAL) {
      INFO("rc.local detected, will try to use it for installing customization agent");
      if(-e $Utils::READLINK) {
         INFO("Resolving rc.local using readlink");
         $rclocal = Utils::Trim(Utils::ExecuteCommand("$Utils::READLINK -f $RC_LOCAL"));
      } else {
         WARN("No realink detected, using rc.local directly");
         $rclocal = $RC_LOCAL;
      }
      INFO("rc.local resolved to '$rclocal'");
      $self->InstallPostRebootAgentGeneric($currDir, $rclocal);
   } else {
      WARN("Can't find rc.local, post-customization will be run before reboot");
   }

   INFO("Installing post-reboot customization agent for unknown linux finished");
}

#...............................................................................
#
# InstallPostRebootAgent
#
#    Installs post-reboot customization agent unless it's already installed.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    Sets the $runPostCustomizationBeforeReboot global variable.
#
#...............................................................................
sub InstallPostRebootAgent
{
   my ($self, $currDir) = @_;

   $self->InstallPostRebootAgentUnknown($currDir);
}

#...............................................................................
#
# RunCustomScript
#
#    Handles the pre-/post-customization script if any.
#
#    Pre-customization is executed inline. Post-customization is normally
#    scheduled to be run after reboot.
#
# Params:
#    $customizationDir     Path to the root of the deployed package
#    $customizationType    'precustomization' or 'postcustomization'
#
# Result:
#    None
#
#...............................................................................

sub RunCustomScript
{
   my ($self, $customizationDir, $customizationType) = @_;

   INFO("RunCustomScript invoked in '$customizationDir' for '$customizationType'");

   my $scriptName = $self->{_customizationConfig}->GetCustomScriptName();
   my $exitCode;

   if (defined $scriptName) {
      my $scriptPath = "$customizationDir/$scriptName";

      if(-e $scriptPath) {
         # Strip any CR characters from the decoded script
         Utils::ExecuteCommand("$Utils::CAT $scriptPath | $Utils::TR -d '\r' > $scriptPath.tmp");
         Utils::ExecuteCommand("$Utils::MV $scriptPath.tmp $scriptPath");

         Utils::ExecuteCommand("$Utils::CHMOD u+x $scriptPath");

         if ($customizationType eq 'precustomization') {
            INFO("Executing pre-customization script...");
            Utils::ExecuteCommand("$Utils::SH $scriptPath \"$customizationType\"",
                                  $customizationType,
                                  \$exitCode);
            if ($exitCode != 0) {
               die "Execution of $customizationType failed!";
            }
         } else { # post-customization
            if(not -d $POST_CUSTOMIZATION_TMP_DIR) {
               INFO("Making temporary post-customization directory");
               Utils::ExecuteCommand("$Utils::MKDIR $POST_CUSTOMIZATION_TMP_DIR");
            }

            $runPostCustomizationBeforeReboot = 1; # set global var
            $self->InstallPostRebootAgent($customizationDir);

            if ($runPostCustomizationBeforeReboot) {
               WARN("Executing post-customization script inline...");
               Utils::ExecuteCommand("$Utils::SH $scriptPath \"$customizationType\"",
                                     $customizationType,
                                     \$exitCode);
               if ($exitCode != 0) {
                  die "Execution of $customizationType failed!";
               }
            } else {
                  INFO("Scheduling post-customization script");

                  INFO("Copying post customization script");
                  Utils::ExecuteCommand("$Utils::CP $scriptPath $POST_CUSTOMIZATION_TMP_SCRIPT_NAME");

                  INFO("Creating post-reboot pending marker");
                  Utils::ExecuteCommand("$Utils::RM $POST_REBOOT_PENDING_MARKER");
                  Utils::ExecuteCommand("$Utils::TOUCH $POST_REBOOT_PENDING_MARKER");
            }
         }
      } else {
         WARN("Customization script '$scriptPath' does not exist");
      }
   } else {
      INFO("No customization script to run");
   }

   INFO("RunCustomScript has completed");
}

#...............................................................................
#
# SetupMarkerFiles
#
#    In case marker id is defined, deletes old markers and creates a new one.
#
# Params:
#    None
#
# Result:
#    None
#
#...............................................................................

sub SetupMarkerFiles
{
   my ($self) = @_;
   my $markerId = $self->{_customizationConfig}->GetMarkerId();

   if (!defined $markerId) {
      return;
   }

   my $markerFile = "/.markerfile-$markerId.txt";

   Utils::ExecuteCommand("$Utils::RM /.markerfile-*.txt");
   Utils::ExecuteCommand("$Utils::TOUCH $markerFile");
}

#...............................................................................
#
# CheckMarkerExists
#
#    Checks existence of marker file in case marker id is provided.
#
# Params:
#    None
#
# Result:
#    1 if marker file exists, 0 if not or undefined.
#
#...............................................................................

sub CheckMarkerExists
{
    my ($self) = @_;
    my $markerId = $self->{_customizationConfig}->GetMarkerId();

    if (!defined $markerId) {
       return 0;
    }

    my $markerFile = "/.markerfile-$markerId.txt";

    if (-e $markerFile) {
       return 1;
    } else {
       return 0;
    }
}

#...............................................................................
#
# CustomizeGuest
#
#    Executes the customization steps for the guest OS customization.
#
# Params:
#    $directoryPath     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................

sub CustomizeGuest
{
   my ($self, $directoryPath) = @_;

   my $markerId = $self->{_customizationConfig}->GetMarkerId();
   my $markerExists = $self->CheckMarkerExists();

   if (defined $markerId && !$markerExists) {
      INFO("Handling pre-customization ... ");
      eval {
         $self->RunCustomScript($directoryPath, 'precustomization');
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_PRE_CUSTOMIZATION_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, pre-customization is not needed");
   }

   INFO("Customizing Network settings ... ");
   eval {
      $self->ReadNetwork();
      $self->CustomizeNetwork();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NETWORK_ERROR;
      die $@;
   }

   INFO("Customizing NICS ... ");
   eval {
      $self->CustomizeNICS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing Hosts file ... ");
      $self->CustomizeHostsFile($HOSTSFILE);

      INFO("Customizing DNS ... ");
      $self->CustomizeDNS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DNS_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing Date&Time ... ");
      $self->CustomizeDateTime();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DATETIME_ERROR;
      die $@;
   }

   if (defined $markerId && !$markerExists) {
      INFO("Handling password settings ... ");
      eval {
         $self->CustomizePassword($directoryPath);
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_PASSWORD_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, password settings are not needed");
   }

   if (defined $markerId && !$markerExists) {
      INFO("Handling post-customization ... ");
      eval {
         $self->RunCustomScript($directoryPath, 'postcustomization');
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_POST_CUSTOMIZATION_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, post-customization is not needed");
   }

   if (defined $markerId) {
      INFO("Handling marker creation ... ");
      eval {
         $self->SetupMarkerFiles();
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_MARKER_ERROR;
         die $@;
      }
   } else {
      INFO("Marker creation is not needed");
   }
}

#...............................................................................
# GetCustomizationResult
#
#   Returns the error code for customization failure.
#
# Params:
#   None
#
# Result:
#   An error code from StdDefinitions
#...............................................................................

sub GetCustomizationResult
{
   my ($self) = @_;
   return $self->{_customizationResult};
}

#...............................................................................
# ReadNetwork
#
#   Reads any relevant network settings
#
# Result & Params: None
#...............................................................................

sub ReadNetwork
{
   # do nothing
}

#...............................................................................
# CustomizeNetwork
#
#   Customizes the network setting
#
# Result & Params: None
#...............................................................................

sub CustomizeNetwork
{
   die "CustomizeNetwork not implemented";
}

#...............................................................................
#
# CustomizeNICS
#
#   Customize network interface. This is generic to all distribution as we know.
#
# Params & Result:
#   None
#
# NOTE:
#...............................................................................

sub CustomizeNICS
{
   my ($self) = @_;

   # pcnet32 NICs fail to get a device name following a tools install. Refer PR
   # 29700: http://bugzilla/show_bug.cgi?id=29700 Doing a modprobe here solves
   # the problem for this boot.

   my $modproberesult = Utils::ExecuteCommand("modprobe pcnet32 2> /dev/null");

   # When doing the first boot up, "ifconfig -a" may only display information
   # about the loopback interface -- bug ? Doing an "ifconfig ethi" once seems
   # to wake it up.

   my $ifcfgresult = Utils::ExecuteCommand("/sbin/ifconfig eth0 2> /dev/null");

   # get information on the NICS to configure
   my $nicsToConfigure = $self->{_customizationConfig}->Lookup("NIC-CONFIG|NICS");

   # split the string by ","
   my @nics = split(/,/, $nicsToConfigure);

   INFO("Customizing NICS. { $nicsToConfigure }");

   # iterate through each NIC
   foreach my $nic (@nics) {
      INFO("Customizing NIC $nic");
      $self->CustomizeSpecificNIC($nic);
   }
};

#...............................................................................
#
# CustomizeSpecificNIC
#
#   Customize an interface.
#
# Params:
#   $nic    NIC name as specified in the config file like NIC-LO
#
# Returns:
#   None
#
# NOTE:
#
#...............................................................................

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # get the interface
   my $macaddr = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC (MAC address = $macaddr)";
   };

   INFO ("Writing ifcfg file for NIC suffix = $interface");

   # write to config file
   my @content = $self->FormatIFCfgContent($nic, $interface);
   my $ifConfigFile = $self->IFCfgFilePrefix() . $interface;
   Utils::WriteBufferToFile($ifConfigFile, \@content);
   Utils::SetPermission($ifConfigFile, $Utils::RWRR);

   # set up the gateways -- routes for addresses outside the subnet
   # GATEWAY parameter is not used to support multiple gateway setup
   my @ipv4Gateways =
      split(/,/, $self->{_customizationConfig}->Lookup($nic . "|GATEWAY"));
   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   if (@ipv4Gateways || @ipv6Gateways) {
      $self->AddRoute($interface, \@ipv4Gateways, \@ipv6Gateways, $nic);
   }
}

#...............................................................................
#
# GetInterfaceByMacAddress
#
#   Get the interface for the network card based on the MAC address. This is
#   like querying for the interface based on MAC address. This information is
#   present in /proc/sys/net but unfortunately in binary format. So, we have to
#   use ifconfig output to extract it.
#
# Params:
#   $macAddress     Mac address as hex value separated by ':'
#   $ifcfgResult    Optional. The ifconfig output
#
# Returns:
#   The interface for this mac address
#   or
#   undef if the mac address cannot be mapped to interface
#
# NOTE: /sbin/ifconfig should be available in the guest.
#...............................................................................

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ifcfgResult) = @_;

   if (! defined $ifcfgResult) {
      $ifcfgResult = Utils::ExecuteCommand('/sbin/ifconfig -a');
   }

   my $result = undef;

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   if ($macAddressValid &&
      ($ifcfgResult =~ /^\s*(\w+?)(:\w*)?\s+.*?$macAddress/mi)) {
      $result = $1;
   }

   return $result;
}

sub GetInterfaceByMacAddressIPAddrShow
{
   # This function is same as GetInterfaceByMacAddress but uses
   # '/sbin/ip addr show' instead of/sbin/ifconfig

   my ($self, $macAddress, $ipAddrResult) = @_;
   my $result = undef;
   if (! defined $ipAddrResult) {
      my $ipPath = Utils::GetIpPath();
      if ( defined $ipPath){
         $ipAddrResult = Utils::ExecuteCommand("$ipPath addr show");
      } else {
         WARN("Path to 'ip addr' not found.");
      }
   }

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   # output of /usr/sbin/ip addr show in RHEL7 is
   # 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
   # link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   # inet 127.0.0.1/8 scope host lo
   #    valid_lft forever preferred_lft forever
   # inet6 ::1/128 scope host
   #    valid_lft forever preferred_lft forever
   # 2: ens192: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP qlen 1000
   # link/ether 00:50:56:af:67:d2 brd ff:ff:ff:ff:ff:ff
   # inet 10.20.116.200/22 brd 10.20.119.255 scope global ens192
   #    valid_lft forever preferred_lft forever
   # inet6 fc00:10:20:119:250:56ff:feaf:67d2/128 scope global dynamic
   #    valid_lft 2573184sec preferred_lft 2573184sec

   if ($macAddressValid && ($ipAddrResult =~
      /^\d+:\s([^\s.:]+):\s[^\n]+[^\n]+\s+link\/\w+\s+$macAddress/mi)) {
      $result = $1;
   }

   return $result;
}

#...............................................................................
#
# FormatIFCfgContent
#
#   Formats the contents of the ifcfg-<interface> file.
#
# Params:
#   $nic
#   $interface
#
# Returns:
#   Array with formatted lines.
#
# NOTE:
#
#...............................................................................

sub FormatIFCfgContent
{
   die "FormatIFCfgContent not implemented";
}

#...............................................................................
#
# AddRoute
#
# Add a route (gateway) for the guest w.r.t a given NIC.
#
# Params:
#     $destination   The gateway IP address(es)
#     $nicname       Prefix of the NIC
#
# Return:
#     None.
#
#...............................................................................

sub AddRoute
{
   die "AddRoute not implemented";
}

#...............................................................................
# BuildFQDN
#
# Build the FQDN to the right value
#
# Params:
#     #newHostnameFQDN       The new Hostname FQDN
#     $newDomainname         The domain name
#
# Return:
#     The new FQDN
#...............................................................................
sub BuildFQDN
{
   my ($self, $newHostnameFQDN, $newDomainname) = @_;
   DEBUG("Building FQDN. HostnameFQDN: $newHostnameFQDN, Domainname: $newDomainname");
   my $newFQDN;
   my $lengthHostnameFQDN = length ($newHostnameFQDN);
   my $lengthDomainname = length ($newDomainname);

   my $rInd = rindex($newHostnameFQDN, ".$newDomainname");
   my $pos = $lengthHostnameFQDN - $lengthDomainname - 1;

   if ($newDomainname eq "") {
        $newFQDN = "$newHostnameFQDN";
   } elsif ($rInd == -1 || $rInd != $pos) {
        $newFQDN = "$newHostnameFQDN.$newDomainname";
   } else {
        # Domainname is already included in the hostname as required by certain programs.
        # In the normal case the hostname is not expected to contain domainname or any dots for that matter.
        $newFQDN = "$newHostnameFQDN";
   }

   return $newFQDN;
}

#...............................................................................
#
# CustomizeHostsFile
#
#     Hosts file is the static host lookup. If appropriately configured this
#     preceeds the DNS lookup. Customization process removes all reference for
#     the old hostname and replaces it with the new host name. It also adds
#     ethernet IPs as reference to the host name.
#
# Params & Result:
#     None
#
# NOTE: No support for IPv6 entries.
# TODO: What about IP settings from the old ethernets ?
#
#...............................................................................

sub CustomizeHostsFile
{
   my ($self, $hostsFile) = @_;

   # Partial customization - calculate new hostname and new FQDN
   # based on the existing values and new customization spec values

   # Retrieve old hostname and FQDN
   my $oldHostname = $self->OldHostnameCmd();
   my $oldFQDN = $self->OldFQDN();
   DEBUG("Old hostname=[$oldHostname]");
   DEBUG("Old FQDN=[$oldFQDN]");

   my $cfgHostname = $self->{_customizationConfig}->GetHostName();
   my $newHostname = $cfgHostname;
   # FQDN may not include hostname, prepare to preserve FQDN
   my $newHostnameFQDN = $cfgHostname;
   if (ConfigFile::IsKeepCurrentValue($cfgHostname)) {
      $newHostname = $oldHostname;
      $newHostnameFQDN = Utils::GetShortnameFromFQDN($oldFQDN);

      # Old hostname is not resolved and hence old FQDN is not available
      # Use hostname as new FQDN
      if (! $newHostnameFQDN) {
         $newHostnameFQDN = $oldHostname;
      }
   }
   DEBUG("New hostname=[$newHostname]");
   if (! $newHostname) {
      # Cannot create new hostname as old one is invalid
      die 'Invalid old hostname';
   }

   my $cfgDomainname = $self->{_customizationConfig}->GetDomainName();
   my $newDomainname = $cfgDomainname;
   if (ConfigFile::IsKeepCurrentValue($cfgDomainname)) {
      $newDomainname = Utils::GetDomainnameFromFQDN($oldFQDN);
   } elsif (ConfigFile::IsRemoveCurrentValue($newDomainname)) {
      $newDomainname = '';
   }
    my $newFQDN = $self->BuildFQDN($newHostnameFQDN , $newDomainname);
   DEBUG("New FQDN=[$newFQDN]");

   my @newContent;
   my $hostnameSet = 0;

   # Algorithm overview
   # 1.Do not modify '127... ...' and '::1' entries unless oldhostname is there: programs may fail
   # 2.Do not replace a localhost: localhost should always remain
   # 3.Remove non loopback entries with old hostname (assuming this is the old ip)
   # 4.Remove non loopback entries with new hostname if already there
   # 5.Setting hostname does only replacements of oldhostname
   # 6.Setting FQDN does an insert as first name because FQDN should be there
   # 7.Add new line that is <newip> <newhostname>, if <newip> is available
   # 8.Unless new hostname is set by (5) or (7) add a 127.0.1.1 <newhostname> entry

   foreach my $inpLine (Utils::ReadFileIntoBuffer($hostsFile)) {
      DEBUG("Line (inp): $inpLine");
      my $line = Utils::GetLineWithoutComments($inpLine);

      if ($line =~ /^\s*(\S+)\s+(.*)/) {
         my %lineNames = map {$_ => 1} split(/\s+/, $2);
         my $isLoopback = (($1 =~ /127\./) || ($1 eq '::1') || ($1 eq '0:0:0:0:0:0:0:1'));

         if ($isLoopback) {
            my $newLine = $line;
            chomp($newLine);

            # LOOPBACK - REPLACE all non-localhost old hostnames with new hostname
            if (exists $lineNames{$oldHostname} &&
                !ConfigFile::IsKeepCurrentValue($cfgHostname) &&
                !($oldHostname eq 'localhost') &&
                !($oldHostname eq 'localhost.localdomain') ) {
               DEBUG("Replacing [$oldHostname]");
               $newLine = join(
                  ' ',
                  map { $_ eq $oldHostname ? $newHostname : $_  }
                      split(/\s/, $newLine));
            }

            my $newLineContainsNewhostname = ($newLine =~ /\s+$newHostname(\s+|$)/);
            $hostnameSet ||= $newLineContainsNewhostname;

            if ($newLineContainsNewhostname) {
               # LOOPBACK with new hostname - REPLACE all old FQDN with new FQDN
               if (!($oldFQDN eq $newHostname)) {
                  # Don't replace new hostname
                  DEBUG("Replacing [$oldFQDN]");
                  $newLine = join(
                     ' ',
                     map { $_ eq $oldFQDN ? $newFQDN : $_  }
                        split(/\s/, $newLine));
               }

               # LOOPBACK with new hostname - INSERT new FQDN as first name
               if ($newLine =~ /^\s*(\S+)\s+(.*)/) {
                  my ($ip, $aliases) = ($1, $2);
                  DEBUG("Adding [$newFQDN]");
                  # New FQDN is not the first name
                  if ($aliases !~ /^$newFQDN(\s|$)/) {
                     # Make it
                     $newLine = "$ip\t$newFQDN $aliases";
                  }
               }

               # LOOPBACK with new hostname - REMOVE duplicates of FQDN from aliases
               if ($newLine =~ /^\s*(\S+)\s+(\S+)\s(.*)/) {
                  my ($ip, $fqdn, $aliases)    = ($1, $2, $3);
                  DEBUG("Removing duplicating FQDNs");
                  my @aliases = split(/\s/, $aliases);
                  $newLine = "$ip\t$fqdn " . join(' ', grep { !($_ eq $fqdn) } @aliases);
               }
            }

            push(@newContent, "$newLine\n");
         } elsif (! (exists $lineNames{$oldHostname}) &&
                  ! (exists $lineNames{$newHostname})) {
            # NONLOOPBACK - Leave entries to hosts different from:
            #     - old hostname
            #     - new hostname
            push(@newContent, $inpLine);
         }
      } else {
         # Leave comments
         push(@newContent, $inpLine);
      }
   }

   # Add mapping to the customized static ip
   my $newStaticIPEntry;
   foreach my $nic ($self->{_customizationConfig}->GetNICs()) {
      my $ipaddr = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");

      if ($ipaddr) {
         $newStaticIPEntry = "$ipaddr\t$newFQDN";
         if (! ($newFQDN eq $newHostname)) {
            $newStaticIPEntry .= " $newHostname";
         }

         DEBUG("Static ip entry added");
         push(@newContent, "\n$newStaticIPEntry\n");
         $hostnameSet = 1;

         last;
      }
   }

   # Add mapping to loopback 127.0.1.1 if new hostname is still not set
   if (! $hostnameSet) {
      # Hostname still not added - use a loopback entry to
      # create mapping

      my $newLine = "127.0.1.1\t$newFQDN";
      if (! ($newFQDN eq $newHostname)) {
         $newLine .= " $newHostname";
      }

      DEBUG("Loopback entry added");
      Utils::ReplaceOrAppendInLines("127.0.1.1", "\n$newLine\n",\@newContent);
   }

   foreach (@newContent) {
      DEBUG("Line (out): $_");
   }

   Utils::WriteBufferToFile($hostsFile, \@newContent);
   Utils::SetPermission($hostsFile, $Utils::RWRR);
}

#...............................................................................
#
# CustomizeDNS
#
#     Customizes the DNS settings for the guest
#
# Params & Result:
#     None
#
#...............................................................................

sub CustomizeDNS
{
   my ($self) = @_;

   $self->CustomizeNSSwitch("hosts");
   $self->CustomizeReslovFile();
   $self->CustomizeDNSFromDHCP();
}

#...............................................................................
#
# CustomizeNSSwitch
#
#     Add dns to the nsswitch.conf file. This basically includes dns in
#     the resolving mechanism.
#
# Params
#     $database   To which database to add the dns
#
# Result
#
#...............................................................................

sub CustomizeNSSwitch
{
   my ($self, $database) = @_;

   my $nsswitchFileName = "/etc/nsswitch.conf";
   my @content = Utils::ReadFileIntoBuffer ($nsswitchFileName);
   my $databaseLineIndex =
      Utils::FindLineInBuffer (
         $database,
         \@content,
         $Utils::SMDONOTSEARCHCOMMENTS);

   if ($databaseLineIndex >= 0) {
      # Rewrite line with chopped comment from end-of-line, because it is used by dhcp to delete the line when turned off.
      my $databaseLine = Utils::GetLineWithoutComments($content[$databaseLineIndex]);
      chomp $databaseLine;

      $content[$databaseLineIndex] =
         ($databaseLine =~ /\bdns\b/i) ?
            $databaseLine . "\n" :
            $databaseLine . " dns\n";
   } else {
      push(@content, "$database: files dns\n");
   }

   Utils::WriteBufferToFile($nsswitchFileName, \@content);
   Utils::SetPermission($nsswitchFileName, $Utils::RWRR);
}

#...............................................................................
#
# CustomizeReslovFile
#
#     Replaces the resolv.conf file with the  following
#
#     1. Search (Usually contains the local domain)
#     2. List of nameservers to query
#
# Params & Result:
#     None
#
#...............................................................................

sub CustomizeReslovFile
{
   my ($self) = @_;

   my @content = ();

   my $returnCode;
   my $restoreCon;
   my $dnsSuffices = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffices && @$dnsSuffices) {
      push(@content, "search\t" . join(' ', @$dnsSuffices) . "\n");
   }

   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
   if ($dnsNameservers) {
      foreach (@$dnsNameservers) {
         push(@content, "nameserver\t" . $_ . "\n" );
      }
   }

   # Overwrite the resolv.conf file
   Utils::WriteBufferToFile($RESOLVFILE, \@content);
   Utils::SetPermission($RESOLVFILE, $Utils::RWRR);

   $restoreCon = "/sbin/restorecon";
   Utils::ExecuteCommand("/usr/bin/test -f $restoreCon",
                         "Check if restorecon exists in /sbin", \$returnCode);
   if ($returnCode) { # restorecon does not exist in /sbin, try in /usr/sbin
      $restoreCon = "/usr/sbin/restorecon";
      Utils::ExecuteCommand("/usr/bin/test -f $restoreCon",
                            "Check if restorecon exists in /usr/sbin",
                            \$returnCode);
   }
   if (not $returnCode) { # returnCode is 0 on success
      Utils::ExecuteCommand("$restoreCon $RESOLVFILE");
   } else {
      INFO("Could not locate restorecon! Skipping restorecon operation!");
   }
}


#...............................................................................
#
# CustomizeDNSFromDHCP
#
#     Sets whether dhcp should overwrite resolv.conf and thus supply the dns servers.
#
#
# Params & Result:
#     None
#
#...............................................................................

sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   # Apply the DNSFromDHCP setting to the dhcp client.
   if ($self->DHClientConfPath() and
      (-e "/sbin/dhclient-script" or -e $self->DHClientConfPath())) {
      my $dnsFromDHCP = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");
      my $dhclientDomains = $self->{_customizationConfig}->GetDNSSuffixes();

      if ($dnsFromDHCP =~ /no/i) {
            # Overwrite the dhcp answer.

            if (@$dhclientDomains) {
               Utils::AddOrReplaceInFile(
                  $self->DHClientConfPath(),
                  "supersede domain-name ",
                  "supersede domain-name \"".join(" " , @$dhclientDomains)."\";",
                  $Utils::SMDONOTSEARCHCOMMENTS);
            }

            my $dhclientServers = $self->{_customizationConfig}->GetNameServers();

            if (@$dhclientServers) {
               Utils::AddOrReplaceInFile(
                  $self->DHClientConfPath(),
                  "supersede domain-name-servers ",
                  "supersede domain-name-servers ".join("," , @$dhclientServers).";",
                  $Utils::SMDONOTSEARCHCOMMENTS);
            }
      } elsif ($dnsFromDHCP =~ /yes/i) {
         Utils::AddOrReplaceInFile(
            $self->DHClientConfPath(),
            "supersede domain-name ",
            "",
            $Utils::SMDONOTSEARCHCOMMENTS);

         Utils::AddOrReplaceInFile(
            $self->DHClientConfPath(),
            "supersede domain-name-servers ",
            "",
            $Utils::SMDONOTSEARCHCOMMENTS);

         if (@$dhclientDomains) {
            Utils::AddOrReplaceInFile(
               $self->DHClientConfPath(),
               "append domain-name ",
               "append domain-name \" ".join(" " , @$dhclientDomains)."\";",
               $Utils::SMDONOTSEARCHCOMMENTS);
         }
      }
   }
}

#...............................................................................
#
# GetResolverFQDN
#
# Params:
#   None
#
# Result:
#  Returns the host Fully Quallified Domain Name as returned by the resolver /etc/hosts).
#  It may be different from the one returned by the hostname command. Technically is: Use
#  /etc/hosts etc to resolve what is returned by the hostname command.
#...............................................................................

sub GetResolverFQDN
{
   # Calling 'hostname -f' to let it parse /etc/hosts according the its rules,
   # since there is no better OS API for the moment. Turns out that in case the
   # entry mapping for current IP is missing, it will resort to querying DNS and
   # LDAP which is not time-bound (user can set arbitrary timeouts and numbers
   # of retry) by design. So, we cap it with the max affordable timeout.
   my $fqdn =
      Utils::ExecuteTimedCommand('hostname -f 2>/dev/null', $MAX_CMD_TIMEOUT);
   chomp($fqdn);
   return Utils::Trim($fqdn);
}

# Properties

#...............................................................................
#
# OldHostName
#
# Params:
#   None
#
# Result:
#   Old host name taken from config file.
#...............................................................................

sub OldHostName
{
   die "OldHostName not implemented";
}

#...............................................................................
#
# OldHostName
#
# Params:
#   None
#
# Result:
#   Old host name taken from hostname command.
#...............................................................................

sub OldHostnameCmd
{
   my ($self) = @_;

   return $self->{_oldHostnameCmd};
}

#...............................................................................
#
# OldFQDN
#
# Params:
#   None
#
# Result:
#   Old FQDN from hostname -f command.
#...............................................................................

sub OldFQDN
{
   my ($self) = @_;

   return $self->{_oldResolverFQDN};
}

#...............................................................................
#
# IFCfgFilePrefix
#
#
# Params:
#   None
#
# Result:
#   Returns a prefix (without the interface)  of the path to a interface config file.
#...............................................................................

sub IFCfgFilePrefix
{
   die "IFCfgFilePrefix not implemented";
}

#...............................................................................
#
# DHClientConfPath
#
#
# Params:
#   None
#
# Result:
#   Returns the path to the dynamic hosts config file.
#...............................................................................

sub DHClientConfPath
{
   die "DHClientConfPath not implemented";
}

#...............................................................................
#
# TZPath
#
# Params:
#   None
#
# Result:
#   Returns the path to the time zone info files on the local system.
#...............................................................................

sub TZPath
{
   return "/usr/share/zoneinfo";
}

#...............................................................................
#
# CustomizeDateTime
#  Customizes date and time settings such as time zone, utc, etc.
#
# Params:
#   None
#
# Result:
#   None
#...............................................................................

sub CustomizeDateTime
{
   my ($self) = @_;

   $self->CustomizeTimeZone($self->{_customizationConfig}->GetTimeZone());
   $self->CustomizeUTC($self->{_customizationConfig}->GetUtc());
}

#...............................................................................
#
# CustomizeTimeZone
#  Customizes the time zone
#
# Params:
#   $tzRegionCity - time zone in Region/City format, case sensitive.
#   Examples:
#     Europe/Sofia
#     America/New_York
#     Etc/GMT+2
#
# Result:
#   None
#...............................................................................

sub CustomizeTimeZone
{
   my ($self, $tzRegionCity) = @_;

   if ($tzRegionCity) {
      my $tz = $tzRegionCity;

      if (my %renamedTZInfo = TimezoneDB::GetRenamedTimezoneInfo($tzRegionCity)) {
         # $tzRegionCity has two names - new and old. The old name is linked to
         # the new one. It doesn't matter which we use for the clock but
         # the Linux GUI can show one of them (has a hardcoded list of timezone names)

         if ($self->TimeZoneExists($renamedTZInfo{_currentName})) {
            # Use the new tzname as it is on the guest
            $tz = $renamedTZInfo{_currentName};
         } elsif ($self->TimeZoneExists($renamedTZInfo{_oldName})) {
            # Use the old name as new is not on the guest
            $tz = $renamedTZInfo{_oldName};
         }
      }

      if (not $self->TimeZoneExists($tz)) {
         WARN("Timezone $tz could not be found.");

         my $tzdbPath = TimezoneDB::GetPath();

         if ($tzdbPath) {
            TimezoneDB::Install($self->TZPath());

            if (! $self->TimeZoneExists($tz)) {
               WARN("Timezone $tz could not be installed from $tzdbPath.");

               WARN("Deducing $tz GMT offset.");
               $tz = TimezoneDB::DeduceGMTTimezone($tz);

               if ($tz) {
                  WARN("Timezone $tz will be used.");
                  WARN("Daylight Saving Time will be unavailable.");

                  if (not $self->TimeZoneExists($tz)) {
                     die "Timezone $tz could not be found.";
                  }
               } else {
                  die "Unable to deduce GMT offset";
               }
            }
         } else {
            die "A timezone database could not be found.";
         }
      }

      $self->SetTimeZone($tz);
   }
}

#..............................................................................
#
# GetSystemUTC
#
#  Get the current hardware clock based on the system setting.
#
# Result:
#  UTC or LOCAl.
#
#..............................................................................

sub GetSystemUTC
{
   die "GetSystemUTC not implemented";
}

#...............................................................................
#
# CustomizeUTC
#  Customizes whether the hardware clock is in UTC or in local time.
#
# Params:
#   $utc - "yes" means hardware clock is in utc, "no" means is in local time.
#
# Result:
#   None
#..............................................................................

sub CustomizeUTC
{
   my ($self, $utc) = @_;

   if ($utc) {
      if ($utc =~ /yes|no/) {
         $self->SetUTC($utc);
      } else {
         die "Unknown value for UTC option, value=$utc";
      }
   }
}

#...............................................................................
#
# TimeZoneExists
#  Checks whether timezone information exists on the customized OS.
#
# Params:
#   $tz - timezone in the Region/City format
#
# Result:
#   true or false
#...............................................................................

sub TimeZoneExists
{
   my ($self, $tz) = @_;

   return -e $self->TZPath() . "/$tz";
}

#...............................................................................
#
# SetTimeZone
#  Sets the time zone.
#
# Params:
#   $tz - timezone in the Region/City format
#
# Result:
#   None
#...............................................................................

sub SetTimeZone
{
   die "SetTimeZone not implemented";
}

#...............................................................................
#
# SetUTC
#  Sets whether the hardware clock is in UTC or local time.
#
# Params:
#   $utc - yes or no
#
# Result:
#   None
#...............................................................................

sub SetUTC
{
   die "SetUTC not implemented";
}

#...............................................................................
#
# RestartNetwork
#
#  Restarts the network. Primarily used by hot-customization.
#
#...............................................................................

sub RestartNetwork
{
   die "RestartNetwork is not implemented";
}

#...............................................................................
#
# InstantCloneNicsUp
#
#     Bring up the customized Nics for the instant clone flavor of
#     guest customization.
#
# Params:
#     $self  this object.
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................

sub InstantCloneNicsUp
{
   my ($self) = @_;

   $self->RestartNetwork();
}

1;
