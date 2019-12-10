#!/usr/bin/perl

###############################################################################
#  Copyright 2018 VMware, Inc.  All rights reserved.
###############################################################################

package AmazonLinuxCustomization;
use base qw(RHEL7Customization);

use strict;
use Debug;

our $AMAZONLINUX_GENERIC = "Amazon Linux";
our $AMAZONLINUX_2  = "$AMAZONLINUX_GENERIC" . " 2";

our $AMAZONLINUXRELEASEFILE = "/etc/os-release";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   # In Amazon Linux VM, /etc/issue file exists but contains the
   # following information.
   # \S
   # Kernel \r on an \m
   #
   # So, no need to check for /etc/issue. We can directly check
   # for /etc/os-release file.
   #
   # An example of the contents of /etc/os-release:
   # NAME="Amazon Linux"
   # VERSION="2.0 (2017.12)"
   # ID="amzn"
   # ID_LIKE="centos rhel fedora"
   # VERSION_ID="2.0"
   # PRETTY_NAME="Amazon Linux 2 (2017.12) LTS Release Candidate"
   # ANSI_COLOR="0;33"
   # CPE_NAME="cpe:2.3:o:amazon:amazon_linux:2.0"
   # HOME_URL="https://amazonlinux.com/"
   #

   if (-e $AMAZONLINUXRELEASEFILE) {
      DEBUG("Reading $AMAZONLINUXRELEASEFILE file ... ");
      my $releaseContent = Utils::GetValueFromFile(
         $AMAZONLINUXRELEASEFILE,
         'PRETTY_NAME[\s\t]*=(.*)');
      DEBUG($releaseContent);
      $result = $self->FindOsId($releaseContent);
   } else {
      WARN("$AMAZONLINUXRELEASEFILE not available. Ignoring it");
   }

   if (defined $result) {
      DEBUG("Detected flavor: '$result'");
   } else {
      WARN("Amazon Linux flavor not detected");
   }

   return $result;
}

sub SetUTC
{
   # hwclock segfaults in Amazon Linux 2 instance.
   # TODO: Skip setUTC for now for Amazon Linux 2
   WARN(" SetUTC is not implemented for Amazon Linux.")
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Amazon\s*Linux\s*2(\.[0-9]+)?/i) {
      $result = $AMAZONLINUX_2;
   } elsif ($content =~ /Amazon\s*Linux/i) {
      $result = $AMAZONLINUX_GENERIC;
   }
   return $result;
}


1;
