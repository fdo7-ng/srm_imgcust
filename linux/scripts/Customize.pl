#!/usr/bin/perl

################################################################################
#  Copyright 2008-2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# Customize.pl
#
#  The main script which starts the customization process.
#
#  README : ADDING CUSTOMIZATION FOR NEW DISTROs
#     1. Derive the Customization class
#     2. Implement the methods called in this script
#     3. Follow the steps marked with [NewDistroSupport]
#...............................................................................

use strict;

use Debug;
use StdDefinitions qw();
use ConfigFile qw();
use Utils qw();

use RedHatCustomization qw();
use SuSECustomization qw();
use DebianCustomization qw();
use Debian8Customization qw();
use UbuntuCustomization qw();
use SunOSCustomization qw();
use SLES11Customization qw();
use RHEL7Customization qw();
use SLES12Customization qw();
use RHEL6Customization qw();
use Ubuntu10Customization qw();
use Ubuntu11Customization qw();
use Ubuntu12Customization qw();
use Ubuntu13Customization qw();
use Ubuntu15Customization qw();
use AmazonLinuxCustomization qw();
use UbuntuNetplanCustomization qw();

# [NewDistroSupport] STEP1: Use new customization module here

my $distroCustomization = undef;
my $customizationResult = $StdDefinitions::CUST_GENERIC_ERROR;

# Get the command line argument count
my $argc = @ARGV;

if ($argc < 1) {
   print "Usage: perl Customize.pl <configfile> \n";
   exit ( -1 );
}

eval
{
   my $ok = Utils::LockCustomization();
   if (not $ok) {
      $customizationResult = $StdDefinitions::CUST_LOCK_ACQUIRE_ERROR;
      die "Cannot lock, another customization instance might be running.";
   }

   # Parse the config file
   my $customizationConfig = new ConfigFile();
   $customizationConfig->LoadConfigFile($ARGV[0]);
   my $directoryName = Utils::DirName($ARGV[0]);

   # [NewDistroSupport] STEP2:
   # Insert new customization object in the list
   # The first customization that matches will be used so place the more specific first
   my @customizations = (
      new SLES12Customization(),
      new SLES11Customization(),
      new AmazonLinuxCustomization(),
      new RHEL7Customization(),
      new RHEL6Customization(),
      new RedHatCustomization(),
      new SuSECustomization(),
      new Debian8Customization(),
      new DebianCustomization(),
      new UbuntuNetplanCustomization(),
      new Ubuntu15Customization(),
      new Ubuntu13Customization(),
      new Ubuntu12Customization(),
      new Ubuntu11Customization(),
      new Ubuntu10Customization(),
      new UbuntuCustomization(),
      new SunOSCustomization()
   );

   $distroCustomization = Utils::MatchGuestOS(@customizations);

   # Do Customization
   if ($customizationConfig->GetPostGcStatus()) {
      # must be before everything, since resets Alert in VCD
      Utils::PostGcStatus('Started');
   }
   if (defined $distroCustomization) {
      INFO("Customization started");
      $distroCustomization->Customize($customizationConfig, $directoryName);
      $customizationResult = $distroCustomization->GetCustomizationResult();
   } else {
      if ($customizationConfig->GetPostGcStatus()) {
         # post here or it will be missed due to 'defined $distroCustomization' check below
         Utils::PostGcStatus('Unknown distribution.');
      }
      die "Customization Failure !! Unknown distribution.";
   }
}; if (not $@) {
   if (defined $distroCustomization) {
      if ($distroCustomization->{_customizationConfig}->GetPostGcStatus()) {
         Utils::PostGcStatus('Successful');
      }
   }
   INFO("Customization completed.");
} else {
   ERROR("Fatal error occurred during customization !! Customization halted.");
   ERROR("Error : $@");

   if (defined $distroCustomization) {
      if ($distroCustomization->{_customizationConfig}->GetPostGcStatus()) {
         Utils::PostGcStatus($@);
      }

      if ($customizationResult == $StdDefinitions::CUST_GENERIC_ERROR) {
         $customizationResult = $distroCustomization->GetCustomizationResult();
      }
   }

   INFO("Return code is $customizationResult.");
}

exit $customizationResult;

END {
   Utils::UnlockCustomization();
}
