#!/usr/bin/perl
########################################################################################
#  Copyright 2015-2018 VMware, Inc.  All rights reserved.
########################################################################################
#
# SRM Guest Alias Deployment Script (for Linux GOS).
#
use strict;
use warnings;
use File::Basename;
use File::Find;
use File::Spec;
use IO::Handle;

# System utils
my $CHMOD = '/bin/chmod';
my $CAT = '/bin/cat';
my $MV = '/bin/mv -f';
my $SH = '/bin/sh';
my $GREP = '/bin/grep';
my $ECHO = '/bin/echo';
my $MKDIR = '/bin/mkdir -p';
my $TR = '/usr/bin/tr';
my $CP = '/bin/cp';
my $RM = '/bin/rm -f';
my $TOUCH = '/bin/touch';
my $AWK = '/usr/bin/awk';
my $TAIL = '/usr/bin/tail';

# Non-system error codes
my $debug = 0;
my $ERROR_BAD_PARAMS = -10000;
my $ERROR_NO_PEMS = -10001;
my $ERROR_NOT_SUPPORTED = -10002;
my $ERROR_BAD_ENV = -10003;
my $ERROR_BAD_USER = -10004;

# main
my $LOGFILE_HANDLE = StartLog();

# Set VMware Tools Environment
my $VMWARE_TOOLSD_CMD = GetToolsDaemonPath();
my $VGAUTH_CMD = GetVGAuthCmdPath();
my $VMTOOLBOX_CMD = GetToolsboxCmdPath($VMWARE_TOOLSD_CMD);

my $VMTOOLS_VERSION = Trim(`$VMWARE_TOOLSD_CMD -v`);

# Use current account as the target guest user
my $GUEST_ALIAS_ACCOUNT = getpwuid($<);

Log("Running as $GUEST_ALIAS_ACCOUNT, vmtools at $VMWARE_TOOLSD_CMD, $VMTOOLS_VERSION");

my $argc = @ARGV;
if ($argc ne 2) {
   UsageExit();
}

if ($GUEST_ALIAS_ACCOUNT eq "") {
   NotifyAndExit($ERROR_BAD_USER);
}

my $GUEST_ALIAS_ACTION = $ARGV[0];
my $GUEST_ALIAS_SUBJECT = $ARGV[1];

my $VGAUTH_ADD_ALIAS_CMD = "$VGAUTH_CMD add --global --username $GUEST_ALIAS_ACCOUNT --subject $GUEST_ALIAS_SUBJECT --comment SRM --file";
my $VGAUTH_REMOVE_ALIAS_CMD = "$VGAUTH_CMD remove --username $GUEST_ALIAS_ACCOUNT --subject $GUEST_ALIAS_SUBJECT --file";
my $VGAUTH_LIST_ALIAS_CMD = "$VGAUTH_CMD list";

if (($GUEST_ALIAS_ACTION ne "add") && ($GUEST_ALIAS_ACTION ne "cleanup")) {
   UsageExit();
}

# Walk and (re)register all *.pem files found in the current directory
# @todo Need a more comprehensive way of removing stale aliases. Currently, removing
# aliases matching the supplied .pem files only.
my @pems = GetPemFiles();
my $result = 0;

# Dump the current alias list before the operation for diags.
#
# VGAuthService is not guaranteed to be fully initialized and ready to work
# in the moment when the depoloyPkg script is being executed. Since this is
# the first call to the VGAuth CLI tool, retry the operation until the
# VGAuthService is up and running. @see bug 1713550
#
# In case of error retry 10 times with 3 seconds sleep interval between the attempts.
#
# @todo This variable could be configurable and set by SRM as input parameter.
SysCommandWithRetry(20, 3, "$VGAUTH_LIST_ALIAS_CMD");

if ($GUEST_ALIAS_ACTION eq "add") {
   $result = SetupGuest(@pems);
} else {
   $result = CleanupGuest(@pems);
}

# Dump the current alias list after the operation for diags
SysCommand("$VGAUTH_LIST_ALIAS_CMD");

NotifyAndExit($result);

#.......................................................................................
# Result:
#    The full path to the temp file used to store the guest config before customization.
#.......................................................................................
sub GetConfigStoreFile
{
   # Use the same folder that's used by IMC for logging. Similar to Windows version of this script
   # @todo Consider better place for this config file. Maybe near to tools and vgauth cfg files
   # or a temporary directory.
   my $storeFile = "/var/log/vmware-imc/srmGuestConfig.cfg";
   return $storeFile;
}

#.......................................................................................
# Write the given hash into a file as key value pairs.
#
# Params:
#  $hashDataRef - Reference to hash with key value data to store into a file.
#  $filePath    - Full path to the target configuration file to write in.
#				  This subroutine raises an exception if the file cannot be opened for write.
#.......................................................................................
sub WriteHashToConfigFile
{
   my ($hashDataRef, $filePath) = @_;

   # Reset the internal iterator so a prior each() doesn't affect the loop
   keys %{$hashDataRef};

   open(my $cfgFile, ">$filePath" ) or die "Cannot open file $filePath for write: $!";

   while(my($key, $value) = each %{$hashDataRef}) {
      print $cfgFile "$key=$value\n"
   }

   close $cfgFile;
}

#.......................................................................................
# Save the current guest configuration into file
#.......................................................................................
sub SaveGuestConfig
{
   my $cfgFilePath = GetConfigStoreFile();
   Log("Saving guest config into $cfgFilePath");

   my %configData;

   # Extend with more configuration to store if needed.
   my $hostTimeSyncStatusCmd = "$VMTOOLBOX_CMD timesync status 2>&1";
   Log("Running: $hostTimeSyncStatusCmd");
   my $output = Trim(qx($hostTimeSyncStatusCmd));

   if ((index(lc($output), "enabled") != -1) || (index(lc($output), "disabled") != -1)) {
      $configData{'HostTimeSync'} = $output;
      Log("HostTimeSync is currently $output");
   } else {
      Log("WARNING: Invalid output from the timesync status command.");
   }

   eval {
      WriteHashToConfigFile(\%configData, $cfgFilePath);
   };
   if ($@) {
      Log("WARNING: Cannot persist current guest config at $cfgFilePath : $@");
   }
}

#.......................................................................................
# Setup aliases and required config items to enable SRM guest operations
#.......................................................................................
sub SetupGuest
{
   Log("SetupGuest");

   SaveGuestConfig();

   # Remove old aliases. Best effort.
   RemoveAliases(@pems);
   my $result = AddAliases(@pems);

   # Adjust any other guest settings as needed
   if ($result == 0) {
      Log("Enable host timesync");
      SysCommand("$VMTOOLBOX_CMD timesync enable");
   }

   return $result;
}

#.......................................................................................
# Load guest config from file. The config file is read just once before it gets deleted.
#
# Result:
#     Ref to a hash with the loaded key value data.
#.......................................................................................
sub LoadAndDeleteGuestConfig
{
   my %resultHash = ();

   my $cfgFilePath = GetConfigStoreFile();
   Log("Loading stored guest config from $cfgFilePath :");

   eval {
      # Open file in read mode
      open(my $cfgFile, "$cfgFilePath" ) or die "Cannot open file $cfgFilePath for read.";
      # Expecting small file so read all lines at once.
      my @lines = <$cfgFile>;
      close $cfgFile;

      foreach my $line (@lines) {
         Log("   -->$line");
         $line =~ s/^\s+|\s+$//g; # Remove leading and trailing whitespace
         next if ($line =~ /^$/); # Empty line.  No need to go further.

		 # This regex assumes that both key and value don't contain spaces.
		 # Update the regex if values with spaces are needed.
         if ($line =~ /^(\w+)\s*=\s*(\w+)$/) {
            my $k = $1;
            my $v = $2;
            $resultHash{$k} = $v;
            Log("    Setting $k => $v");
         } else {
            Log("    WARNING: skipping malformed line");
         }
      }

      #In the end, try to delete the temp config store file.
      Log("Deleting the temp guest config file: $cfgFilePath");
      unlink $cfgFilePath or Log("WARNING: Cannot cleanup the temporary guest config store file $cfgFilePath");
   };
   if ($@) {
      Log("WARNING: Cannot load persisted guest config from $cfgFilePath : $@");
   }

   return \%resultHash;
}

#.......................................................................................
# Restore the guest to the original config
#.......................................................................................
sub CleanupGuest
{
   Log("CleanupGuest");

   #Remove aliases; pems can be empty here
   RemoveAliases(@pems);

   my $storedConfigDataRef = LoadAndDeleteGuestConfig();

   # Revert host time synchronization configuration
   if (exists $storedConfigDataRef->{'HostTimeSync'}) {
      my $oldHostTimeSyncStatus = $storedConfigDataRef->{'HostTimeSync'};
      Log("HostTimeSync was $oldHostTimeSyncStatus");
      if (index(lc($oldHostTimeSyncStatus), "enabled") != -1) {
         SysCommand("$VMTOOLBOX_CMD timesync enable");
      } elsif (index(lc($oldHostTimeSyncStatus), "disabled") != -1) {
         SysCommand("$VMTOOLBOX_CMD timesync disable");
      } else {
         Log("WARNING: Unexpected HostTimeSync value: $oldHostTimeSyncStatus");
      }
   } else {
      Log("WARNING: Saved HostTimeSync not found");
   }

   # Always the best effort
   return 0;
}

#.......................................................................................
# Subroutines adapted from Customization::Utils module
#.......................................................................................
sub Trim
{
   my ($string) = @_;

   $string =~ s/^[\s\t]+//;
   $string =~ s/[\s\t]+$//;

   return $string;
}

#.......................................................................................
# Get Tools Daemon Path.
#
# Params: None.
#
# Result: Detected path to the Tools daemon.
#...............................................................................
sub GetToolsDaemonPath
{
   Log("Getting vmtoolsd path.");

   my $vmToolsdPath;
   eval {
      # Use ps to find Tools daemon process's command path.
      # Get the first non-space string from each line only.
      # For example, in case of tar tools the expected output
      # is as follows:
      #
      #  /usr/sbin/vmtoolsd
      #  /usr/lib/vmware-tools/sbin64/vmtoolsd -n vmusr
      #
      my @filtered_ps_output = `ps -C vmtoolsd --no-headers -o cmd | cut -f 1 -d \" \"`;
      map {$_ = Trim($_);} @filtered_ps_output;

      my $numHits = scalar(@filtered_ps_output);
      if ($numHits > 0) {
         # Get the first non-empty string as Tools daemon execution path.
         # There might be several vmtoolsd processes running for each logged in user.
         # All of them should use the same binary though.
         $vmToolsdPath = $filtered_ps_output[0];
      } else {
         Log("ERROR: Unabled to discern the vmtoolsd process by parsing <ps> output:\n" . join("\n", @filtered_ps_output));
         ExitWithResultCode($ERROR_BAD_ENV);
      }
   };

   if ($@) {
      Log("Unable to detect running vmtoolsd process using <ps> : $@");
      ExitWithResultCode($ERROR_BAD_ENV);
   }

   if (!defined $vmToolsdPath || ! -x $vmToolsdPath) {
      if (defined $vmToolsdPath) {
         Log("ERROR: Could not find vmtoolsd path at : $vmToolsdPath");
      } else {
         Log("ERROR: Unable to find vmtoolsd path");
      }
      ExitWithResultCode($ERROR_BAD_ENV);
   }

   Log("Found vmtoolsd at: $vmToolsdPath");
   return $vmToolsdPath;
}

#.......................................................................................
# Get VGAuth CLI util path.
#.......................................................................................
sub GetVGAuthCmdPath
{
   # There is a discrepancy in the default location of vmware-vgauth utility between
   # OVT(open-vm-tools) and the regular tar tools version. In addition, the users
   # can override these defaults during OVT installation process. Try to locate this tool
   # by searching for an active VGAuthService and get its parent directory. If this
   # fails, as a best effort try to locate the tool among the following 3 locations:
   # usr/lib/vmware-vgauth, /usr/bin/vmware-vgauth, /usr/local/bin/vmware-vgauth

   my $vgauthCmdPath;
   eval {
      # Search for an active VGAuthService and get its parent directory.
      # Use ps to find VGAuthService process's command path.
      my @ps_output = `ps -C VGAuthService --no-headers -o cmd | cut -f 1 -d \" \"`;
      map {$_ = Trim($_);} @ps_output;

      my @filtered_ps_output = grep {basename($_) eq "VGAuthService"} @ps_output;

      my $numHits = scalar(@filtered_ps_output);
      if ($numHits == 1) {
         my $vgauth_service_folder = dirname($filtered_ps_output[0]);

         Log("VGAuthService root folder located at: $vgauth_service_folder");
         $vgauthCmdPath = $vgauth_service_folder . '/vmware-vgauth-cmd';
      } else {
         Log("WARNING: Unabled to discern the VGAuthService service process by parsing <ps> output");
         Log("WARNING: Matched ($numHits) processes from:\n" . join("\n", @filtered_ps_output));
      }
   };

   if ($@) {
      Log("Unable to determine the VGAuthService process path using <ps> and <dirname> : $@");
      Log("Checking the well-known default locations as best effort...");
   }

   if (!defined $vgauthCmdPath || ! -x $vgauthCmdPath) {
      if (defined $vgauthCmdPath) {
         Log("Could not find vmware-vgauth-cmd in $vgauthCmdPath");
      }

      Log("Checking the default VGAuthService service locations... ");

      # Check the default path in case of tar Tools.
      $vgauthCmdPath = '/usr/lib/vmware-vgauth/vmware-vgauth-cmd';
      if (! -x $vgauthCmdPath) {
         Log("Could not find vmware-vgauth-cmd in $vgauthCmdPath");
         # Check the default path in case of OVT.
         $vgauthCmdPath = '/usr/bin/vmware-vgauth/vmware-vgauth-cmd';
         if (! -x $vgauthCmdPath) {
            Log("Could not find vmware-vgauth-cmd in $vgauthCmdPath");
            $vgauthCmdPath = '/usr/local/bin/vmware-vgauth/vmware-vgauth-cmd';
            if (! -x $vgauthCmdPath) {
               Log("Could not find vmware-vgauth-cmd in $vgauthCmdPath");
               Log("Cannot find vmware-vgauth-cmd util.");
               NotifyAndExit($ERROR_BAD_ENV);
            }
         }
      }
   }

   Log("Found vmware-vgauth-cmd at: $vgauthCmdPath");
   return $vgauthCmdPath;
}

#.......................................................................................
# Get vmware-toolbox-cmd path
#
# Params:
#  $vmtooldPath - Path to the vmtools daemon to use to identify the util location if we
#                 cannot find it at the expected default location.
#.......................................................................................
sub GetToolsboxCmdPath
{
   my ($vmtoolsdPath) = @_;

   # First check the default location for both OVT and tar Tools.
   my $toolsBoxCmdPath = '/usr/bin/vmware-toolbox-cmd';
   if (! -x $toolsBoxCmdPath) {
      # In case of OVT, the user has control where to put these utils.
      # The assumption is that vmware-toolbox-cmd is placed in the same location
      # as vmtoolsd daemon. Note that in case of tar tools, by default vmtoolsd
      # and vmware-toolbox-cmd are placed in different locations so this approach
      # won't work for the tar version.

      $toolsBoxCmdPath = dirname($vmtoolsdPath) . '/vmware-toolbox-cmd';
      if (! -x $toolsBoxCmdPath) {

         # @todo Try to extract the utility path from /etc/vmware-tools/location
         # similar to GetToolsDaemonPath

         Log("Cannot find vmware-toolbox-cmd util.");
         NotifyAndExit($ERROR_BAD_ENV);
      }
   }

   Log("Found vmware-toolbox-cmd at: $toolsBoxCmdPath");
   return $toolsBoxCmdPath;
}

#.............................................................
# Start the log process. Creates a new directory and open the log for writing.
# Result: File handle for the log file. Undef if the log file cannot be created/opened.
# The user of this function is responsible for closing the result file handle.
#.............................................................
sub StartLog
{
   # Use the same folder that's used by IMC
   my $logdir = "/var/log/vmware-imc";
   my $logfile = "$logdir/srmDeployGuestAlias.log";
   system("$MKDIR $logdir");

   # Open the log file in write mode
   if (open(my $resultHandle, ">$logfile")) {
      my $date = scalar localtime;

      $resultHandle->autoflush;
      print $resultHandle "\n--------------------------------------------------------------------------------------\n";
      print $resultHandle "$date Starting @ARGV\n";
      print $resultHandle "--------------------------------------------------------------------------------------\n\n";

      return $resultHandle;
   } else {
      warn "Fail to initialize the logging. Cannot open $logfile for write: $!";
	  return undef;
   }
}

#.............................................................
# Logging utility
#
# Params:
#  $line - String to write into the log fie.
#.............................................................
sub Log
{
   my ($line) = @_;
   if ($debug) {
       print "LOG: $line\n";
   }

   if (defined $LOGFILE_HANDLE) {
      my $date = scalar localtime;
	  print $LOGFILE_HANDLE "$date $line\n";
   }
};

#.............................................................
# Tiny wrapper around perl's system to run commands. Capture both STDOUT, STDERR
# and writes them into the log file.
#
# Params:
#   $cmd - Command to run.
# Result:
#   The exit code of the invoked process.
#.............................................................
sub SysCommand
{
   my ($cmd) = @_;
   Log("Running: $cmd");
   my $output = qx($cmd 2>&1);
   my $resultCode = $?;
   Log("$output\nResult code: $resultCode");
   return $resultCode;
}

#.............................................................
# Retriable version of SysCommand function. Retry with sleep
# interval in case of received error code from the invoked process.
#
# Params:
#   $maxRetriesCount  - Max retry count after which to give up.
#   $retryIntervalSec - Seconds to sleep before to retry.
#   $cmd              - Command to run.
# Result:
#   The exit code of the invoked process from the last attempt.
#.............................................................
sub SysCommandWithRetry
{
   my ($maxRetriesCount, $retryIntervalSec, $cmd ) = @_;

   my $resultCode;
   my $currAttemptCount = 1;
   my $maxAttemptsCount = $maxRetriesCount + 1;

   attempt : {
      $resultCode = SysCommand($cmd);
      # Finish on success
      last attempt if ($resultCode == 0);

      if ($currAttemptCount >= $maxAttemptsCount) {
         Log("Giving up. All $maxAttemptsCount attempts have failed for cmd: $cmd");
         last attempt;
      }

      Log("Attempt ($currAttemptCount of $maxAttemptsCount) has failed. Will retry after $retryIntervalSec seconds.");
      sleep $retryIntervalSec;
      $currAttemptCount++;
      redo attempt;
   }

   return $resultCode;
}

#.............................................................
# Result: Vector of .pem files under the script's directory
#.............................................................
sub GetPemFiles
{
   my ($v,$dir,$f) = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
   my @pems;
   File::Find::find(sub {
     if (-f and /\.pem$/) {
       push @pems, "$dir$_";
     }
   }, $dir);
   return @pems;
}

#.............................................................
# Remove all aliases with matching subject, user, and PEM file.
# Result: 0 for success, or first error code encountered.
# Note: The function always attempts to remove all matching aliases.
#.............................................................
sub RemoveAliases
{
   my @pems = @_;
   if (!@pems) {
      return $ERROR_NO_PEMS;
   }
   my $result = 0;
   foreach my $pem (@pems) {
      my $error = SysCommand("$VGAUTH_REMOVE_ALIAS_CMD $pem");
      if ($error ne 0 and $result eq 0) {
         $result = $error;
      }
   }
   return $result;
}

#.............................................................
# Add aliases.
# Note all the aliases we add are global (corresponding to the mapCert
# GuestOps API parameter). This would allow the client skip specifying the
# username in the API calls.
#
# Result: The result code, 0 for success.
# Note: The function bails out once it encountered an error with one of the aliases.
#.............................................................
sub AddAliases
{
  my @pems = @_;
  my $result = $ERROR_NO_PEMS;
  foreach my $pem (@pems) {
      $result = SysCommand("$VGAUTH_ADD_ALIAS_CMD $pem");
      if ($result != 0) {
         last;
      }
   }
   return $result
}

#.............................................................
# Notify the client (best effort) and continue with ExitWithResultCode
#
# Params:
#   $result - Exit code to use.
#.............................................................
sub NotifyAndExit
{
   my ($result) = @_;

   # Setting special config.extraConfig.* VMX property for the client.
   my $cmd =
      "$VMWARE_TOOLSD_CMD --cmd \"info-set guestinfo.srm.deployPkg.result $result\"";

   SysCommand($cmd);
   ExitWithResultCode($result);
}

#.............................................................
# Close the log file and exit with the specified exit code.
#
# Params:
#   $result - Exit code to use.
#.............................................................
sub ExitWithResultCode
{
   my ($result) = @_;

   # @note
   #
   # 1) The result of deployPkg shows up in the vSphere VM event UI tab
   # as "Customization Event". Returning an error shows up as "Customization Error"
   # with explanations irrelevant to the current script, obviously.
   # 2) vgauth CLI appears to return positive integer as an error code, which
   #    deployPkg interprets as success
   #
   # @todo 1) Check if the UI event can be customized (e.g. a special error code?)
   #       2) Investigate/file a bug against vgauth CLI
   if ($result == 0) {
      Log("Completed successfully");
   } else {
      Log("Completed with error; reporting exit code: $result");
   }

   # Close the log file if it was initialized.
   if (defined $LOGFILE_HANDLE) {
      close($LOGFILE_HANDLE) or warn "Closing log file failed: $!"
   }

   exit ($result);
}

#.............................................................
# Print the script usage string and exit
#.............................................................
sub UsageExit
{
   Log("Wrong parameter(s). Usage: $0 [add|remove] [subject_name]");
   NotifyAndExit ($ERROR_BAD_PARAMS);
}