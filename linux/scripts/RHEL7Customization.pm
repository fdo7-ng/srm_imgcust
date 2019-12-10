#!/usr/bin/perl

###############################################################################
#  Copyright 2014-2017 VMware, Inc.  All rights reserved.
###############################################################################

package RHEL7Customization;
use base qw(RHEL6Customization);

use strict;
use Debug;

use constant HOSTNAME_FILE => "/etc/hostname";

our $CENTOS = "CentOS";
our $ORA = "Oracle Linux";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   #Pre-enabling 8 and 9 to work same way as 7
   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+([7-9])/i) {
      $result = "Red Hat Enterprise Linux $1";
   } elsif ($content =~ /CentOS.*?release\s+([7-9])/i) {
      $result = $CENTOS . " $1";
   } elsif ($content =~ /Oracle.*?release\s+([7-9])/i) {
      $result = $ORA . " $1";
   }
   return $result;
}

sub InitOldHostname
{
   my ($self) = @_;

   $self->{_oldHostName} = $self->OldHostnameCmd();
   if (!$self->{_oldHostName}) {
      ERROR("OldHostnameCmd() returned empty name");
   }
   INFO("OLD HOST NAME = $self->{_oldHostName}");
}

sub CustomizeNetwork
{
   my ($self) = @_;

   $self->SUPER::CustomizeNetwork();
   $self->CustomizeHostName();
}

sub CustomizeHostName
{
   my ($self) = @_;

   # if /etc/hostname is present in RHEL7, we want to override hostname in this file.
   if (-e HOSTNAME_FILE) {
      my $newHostname = $self->{_customizationConfig}->GetHostName();
      if (ConfigFile::IsKeepCurrentValue($newHostname)) {
         $newHostname = $self->OldHostName();
      }
      # Ensure new hostname is valid before writing to hostname file. PR #2015226.
      if ($newHostname) {
         Utils::WriteBufferToFile(HOSTNAME_FILE, ["$newHostname\n"]);
         Utils::SetPermission(HOSTNAME_FILE, $Utils::RWRR);
      } else {
         ERROR("Invalid hostname '$newHostname' for " . HOSTNAME_FILE);
      }
   }
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self)  = @_;
   my $returnCode;

   Utils::ExecuteCommand('systemctl restart network.service 2>&1',
                         'Restart Network Service',
                         \$returnCode);

   if ($returnCode) {
      die "Failed to restart network, service code: $returnCode";
   }
}

1;
