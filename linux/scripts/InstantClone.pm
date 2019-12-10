#!/usr/bin/perl

################################################################################
#  Copyright 2017-2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# InstantClone.pm
#
#  This module manages the supported Guest OS for the InstantClone and
#  serves as an adaptor so that the error handling is more streamlined.
#
#  README : ADDING CUSTOMIZATION FOR NEW DISTROs
#     1. Derive the Customization class
#     2. Implement the methods called in this script
#     3. Follow the steps marked with [NewDistroSupport]
#...............................................................................

package InstantClone;

use strict;
use Debug;
use Cwd qw(abs_path);
use File::Spec;
use Utils qw();
use StdDefinitions qw();
use ConfigFile qw();
use InstantCloneConstants qw();

use SLES12Customization qw();
use SLES11Customization qw();
use AmazonLinuxCustomization qw();
use RHEL7Customization qw();
use RHEL6Customization qw();
use RedHatCustomization qw();
use UbuntuNetplanCustomization qw();
use Ubuntu15Customization qw();
use Ubuntu13Customization qw();
use Ubuntu12Customization qw();
use Ubuntu11Customization qw();
use Ubuntu10Customization qw();
use UbuntuCustomization qw();
# [NewDistroSupport] STEP1: Use new customization module here

# Use /var/log/vmware-gosc instead of $self->{_directory}.
#
# Pros: log file won't get lost when the customizer is uninstalled.
#       log file needs to be preserved even when the customization is
#       successful. For example, we need to track what has been done to
#       the guest even if the customization is reported to be successful.
#       It decreases the product usability to ask users to copy out the
#       log file before calling the uninstall customizer API.
#
# Cons: Clean up might be an issue. However, each customization generates
#       very small amount of log output, about 20KB of log data.
#       For QE stress testing, they will need to write code to
#       clean up the log file periodically.

our $LOG_FILEPATH = '/var/log/vmware-gosc/instant_clone_customization.log';

our $MOCKUP_FILENAME = 'InstantClone.Gosc.Mockup';

#...............................................................................
#
# new
#
#   Constructor.
#   In order to better share code between different perl launchers,
#   this constructor takes the command line args and do the common processing.
#
# Params:
#   $prog  The name of the perl script launched.
#   @argv  The command line args.
#
# Result:
#   The constructed object.
#...............................................................................

sub new
{
   my ($class, $prog, @argv) = @_;
   my $self = {};

   # We expect callers to pass an ID as the first argument.
   # The ID is to locate the namespace DB entry and send the status back.
   # If a caller violates the contract, simiply exit with an error code.
   # https://wiki.eng.vmware.com/InstantCloneGuestCustomizationMeeting3Proposal
   if (@argv < 1) {
      exit $StdDefinitions::CUST_ID_NOT_FOUND_ERROR;
   } else {
      $self->{_id} = $argv[0];
   }

   $self->{_configPath} = undef;
   if (@argv >= 2) {
      # Special command line option for testing without the namespace DB set up.
      # perl script <id> [configPath]
      $self->{_configPath} = $argv[1];
   }

   # Compute the perl script directory
   my $directoryName = Utils::DirName(abs_path($prog));
   $self->{_directory} = $directoryName;
   Utils::SetLinuxCustNotifierDir($directoryName);

   # Initialize _statusCode to CUST_GENERIC_ERROR, so that if any lower layer
   # code throws an exception, the status code correctly reflects an error.
   $self->{_statusCode} = $StdDefinitions::CUST_GENERIC_ERROR;

   bless $self, $class;
   return $self;
}

#...............................................................................
#
# Mockup
#
#   The mock up logic helps testing the error/timeout handling on the
#   VC side. It is also possible to test the Terminate API by simulating a guest
#   customization stuck or crash.
#
#   Mockup file contains one line input with the following syntax:
#   1) crash
#   2) hang
#   3) run X, status Y
#         where it run for X seconds, and set the status code to Y.
#         Note that status code 0 means success.
#
# Params:
#   $self  this object.
#   $mockupFile  the mockup input file to use.
#
# Result:
#   None.
#...............................................................................

sub Mockup
{
   my ($self, $mockupFile) = @_;

   DEBUG("Running mockup with input file $mockupFile");

   my $fh;
   my $ok = open($fh, $mockupFile);
   if (not $ok) {
      DEBUG("Unable to open file $mockupFile, $!");
      die "Unable to open file $mockupFile, $!";
   }
   my @lines = <$fh>;
   close($fh);

   my $content = @lines[0];
   if ($content =~ /crash/i) {
      DEBUG("Simulate a crash");
      # $$ is the pid of this process.
      Utils::KillCustomizationProcess($$);
      sleep(3600);
      die "Should not get here";
   } elsif ($content =~ /hang/i) {
      DEBUG("Simulate a hang");
      while(1) {
         sleep(3600);
      }
      die "Should not get here";
   }

   # Run for X seconds, and set the status code to Y
   if ($content =~ /run\s*(\d+)/i) {
      my $runTime = $1;
      DEBUG("Simulating running for $runTime seconds");
      sleep($runTime);
   }

   if ($content =~ /status\s*(\d+)/i) {
      $self->{_statusCode} = $1;
   } else {
      $self->{_statusCode} = $StdDefinitions::CUST_SUCCESS;
   }
   DEBUG("Simulating to set status to $self->{_statusCode}");

   if ($self->{_statusCode} != $StdDefinitions::CUST_SUCCESS) {
      die "Simulating an error";
   }
}

#...............................................................................
#
# RunFunctorOrMockup
#
#   If the mockup file is present, run the mock up logic.
#   Otherwise, run the functor.
#
# Params:
#   $self  this object.
#   $functor  a customization operation functor.
#
# Result:
#   None.
#...............................................................................

sub RunFunctorOrMockup
{
   my ($self, $functor) = @_;

   my $mockupFile = File::Spec->join($self->{_directory}, $MOCKUP_FILENAME);
   if (-e $mockupFile) {
      $self->Mockup($mockupFile);
   } else {
      DEBUG("Running a functor.");
      &$functor($self);
   }
}

#...............................................................................
#
# LockCustomizationSetError
#
#   The wrapper function to invoke Utils::LockCustomization and
#   set the status error code if the lock cannot be acquired indicating
#   another instance of guest customization is already running.
#
# Params:
#   $self  this object.
#
# Result:
#   None.
#...............................................................................

sub LockCustomizationSetError
{
   my ($self) = @_;

   my $ok = Utils::LockCustomization();
   if (not $ok) {
      $self->{_statusCode} = $StdDefinitions::CUST_LOCK_ACQUIRE_ERROR;
      die "Cannot lock, another customization instance might be running.";
   }
}

#...............................................................................
#
# Invoke
#
#   The common invoker of different customization logics.
#   1) Set up logging.
#   2) Acquire the customization file lock.
#   3) Run the functor passed.
#   4) Catch a die exception.
#   5) Notify the customization status.
#   6) Release the customization file lock.
#
# Params:
#   $self  this object.
#   $functor  a customization operation functor.
#
# Result:
#   None.
#...............................................................................

sub Invoke
{
   my ($self, $functor) = @_;

   eval {
      SetupLogging($LOG_FILEPATH);

      $self->LockCustomizationSetError();

      $self->RunFunctorOrMockup($functor);

      Utils::NotifyInstantCloneState($self->{_id},
                                     $InstantCloneConstants::STATE_OK);
   }; if ($@) {
      my $statusCode = $self->GetStatusCode();

      ERROR("Guest customization failed: $statusCode,$@");
      Utils::NotifyInstantCloneState($self->{_id},
                                     $InstantCloneConstants::STATE_ERR,
                                     $statusCode, $@);
      exit $statusCode;
   }
}

#...............................................................................
#
# KillRunning
#
#   Kill a running instance of guest customization and remove the lock.
#   1) Set up logging.
#   2) Kill and unlock.
#   3) Catch a die exception.
#   4) Notify the customization status.
#
# Params:
#   $self  this object.
#
# Result:
#   None.
#...............................................................................

sub KillRunning
{
   my ($self) = @_;

   eval {
      SetupLogging($LOG_FILEPATH);

      Utils::KillUnlockOtherCustomization();

      Utils::NotifyInstantCloneState($self->{_id},
                                     $InstantCloneConstants::STATE_OK);
   }; if ($@) {
      my $statusCode = $self->GetStatusCode();

      ERROR("Guest customization failed: $statusCode,$@");
      Utils::NotifyInstantCloneState($self->{_id},
                                     $InstantCloneConstants::STATE_ERR,
                                     $statusCode, $@);
      exit $statusCode;
   }
}

#...............................................................................
#
# Customize
#
#   Main driver of the instant clone variant of the guest customization.
#   1) Load the distro class
#   2) Read the customization configuration from Namespace DB.
#   3) Invoke the customization using the distro object.
#
# Params:
#   $self  this object.
#
# Result:
#   None.
#...............................................................................

sub Customize
{
   my ($self) = @_;

   INFO("Starting an instant clone guest customization, configuring guest.");

   my $distro = $self->LoadCustomizationInstance();
   if (not defined $distro) {
      die "Unsupported Guest OS distribution.";
   }

   my $customizationConfig = $self->ReadConfig();

   eval {
      $distro->InstantCloneCustomize($customizationConfig, $self->{_directory});
   }; if ($@) {
      my $result = $distro->GetCustomizationResult();
      DEBUG("InstantClone customization result: $result");
      if (defined $result) {
         $self->{_statusCode} = $result;
      }
      die $@;
   }
   $self->{_statusCode} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# NicsUp
#
#   Entry function to bring up the network in the guest VM.
#
#   1) Load the distro class
#   2) Invoke the implementation using the distro object.
#
# Params:
#   $self  this object.
#
# Result:
#   None.
#...............................................................................

sub NicsUp
{
   my ($self) = @_;

   INFO("Continuing the instant clone guest customization, bringing up NICs.");

   my $distro = $self->LoadCustomizationInstance();
   if (not defined $distro) {
      die "Unsupported Guest OS distribution.";
   }

   eval {
      $distro->InstantCloneNicsUp();
   }; if ($@) {
      my $result = $distro->GetCustomizationResult();
      DEBUG("NicsUp customization result: $result");
      if (not defined $result or
          $result == $StdDefinitions::CUST_GENERIC_ERROR) {
         $self->{_statusCode} = $StdDefinitions::CUST_NETWORK_START_ERROR;
      } else {
         $self->{_statusCode} = $result;
      }

      die $@;
   }
   $self->{_statusCode} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# GetStatusCode
#
#   Retrieve the status code of the guest customization, assuming
#   that the Customize() function was invoked.
#   _statusCode is used to track the last error happened to the instant
#   clone variant of the guest customization.
#
# Params:
#   $self  this object.
#
# Result:
#   The status code.
#...............................................................................

sub GetStatusCode
{
   my ($self) = @_;

   # Use the object status code.
   DEBUG("InstantClone customization status code: $self->{_statusCode}");
   return $self->{_statusCode};
}

#...............................................................................
#
# ReadConfig
#
#   Read the guest customization configuration data from the namespace DB
#   and create a the configuration file.
#   Parse the configuration file and return the object for later processing.
#   If the test configuration file is specified, use that directly instead of
#   reading the namespace DB.
#
# Params:
#   $self  this object.
#
# Result:
#   The ConfigFile object
#...............................................................................

sub ReadConfig
{
   my ($self) = @_;

   my $configPath = $self->{_configPath};
   if (not defined $configPath) {
      # Read the config from Namespace DB.
      # Set _statusCode on failure and die.

      my $configText = undef;
      eval {
         # Key is prefixed with the instant clone customization ID and a dot.
         my $key = $self->{_id} . '.' .
            $InstantCloneConstants::NS_DB_KEY_CONFIG;

         $configText = Utils::ReadNsProperty($key);
      }; if ($@) {
         $self->{_statusCode} = $StdDefinitions::CUST_NS_CONFIG_READ_ERROR;
         die $@;
      }

      # Configuration should not be empty.
      if (not $configText) {
         $self->{_statusCode} = $StdDefinitions::CUST_NS_CONFIG_READ_ERROR;
         die "Invalid customization configuration";
      }

      # Create the working config file
      # Intentionally leave it behind for the troubleshooting purpose.
      $configPath = File::Spec->join($self->{_directory},
                                     'cust.cfg' . '.' . $self->{_id});

      Utils::WriteLineToFile($configPath, $configText);
      Utils::SetPermission($configPath, $Utils::RW00);
   }

   my $customizationConfig = new ConfigFile();
   $customizationConfig->LoadConfigFile($configPath);

   return $customizationConfig;
}

#...............................................................................
#
# LoadCustomizationInstance
#
#   Match the guest OS and create the corresponding customization object for
#   the guest.
#
# Params:
#   $self  this object.
#
# Result:
#   Return the proper guest customization object.
#...............................................................................

sub LoadCustomizationInstance
{
   my ($self) = @_;

   # [NewDistroSupport] STEP2:
   # Insert new customization object in the list.
   # The first customization that matches will be used
   # so place the more specific first.
   my @customizations = (
      new SLES12Customization(),
      new SLES11Customization(),
      new AmazonLinuxCustomization(),
      new RHEL7Customization(),
      new RHEL6Customization(),
      new RedHatCustomization(),
      new UbuntuNetplanCustomization(),
      new Ubuntu15Customization(),
      new Ubuntu13Customization(),
      new Ubuntu12Customization(),
      new Ubuntu11Customization(),
      new Ubuntu10Customization(),
      new UbuntuCustomization(),
   );

   return Utils::MatchGuestOS(@customizations);
}

#...............................................................................
# Return value for module as required for perl
#...............................................................................

END {
   Utils::UnlockCustomization();
}

1;
