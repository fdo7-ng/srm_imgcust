########################################################################################
#  Copyright 2011 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu10Customization;
use base qw(UbuntuCustomization);

use strict;
use Debug;

# distro flavour detection constants
my $UBUNTU10_04 = "Ubuntu 10.04";
my $UBUNTU10_10 = "Ubuntu 10.10";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);

      if ($issueContent =~ /Ubuntu\s+10\.10/i) {
         $result = $UBUNTU10_10;
      } elsif ($issueContent =~ /Ubuntu\s+10\.04/i) {
         $result = $UBUNTU10_04;
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }

   return $result;
}

sub InitGuestCustomization
{
   my ($self) = @_;

   # NetworkManger will overwrite the hosts file during certain triggers.
   # We need to stop NM for customization since it modifies the loopback
   # line in /etc/hosts.
   # We are doing this in init phase because later when writing to
   # /etc/hostname, NM will be triggered to update /etc/hosts.
   # When customizing /etc/hosts in CustomizeHostsFile(), we will set the
   # immutable bit to preserve this file.
   INFO("Stopping NetworkManager ... ");
   Utils::ExecuteCommand("service network-manager stop >/dev/null 2>&1");
   Utils::ExecuteCommand("killall nm-applet >/dev/null 2>&1");

   $self->SUPER::InitGuestCustomization();
}

sub CustomizeHostsFile
{
   my ($self, $hostsFile) = @_;

   # Clear the immutable bit in case it has been set.
   Utils::ClearFileImmutableBit($hostsFile);

   # Do host file customization.
   $self->SUPER::CustomizeHostsFile($hostsFile);

   # Re-read in the hosts file.
   my @content = Utils::ReadFileIntoBuffer($hostsFile);

   # For Ubuntu 10.10 Desktop, "localhost6" needs to be present on the IPV6
   # loopback line, otherwise hostname command will return localhost,
   # irrespective of the contents of /etc/hostname.
   # This becomes apparent post-customization, after reboot.
   # Old-format IPV6 loopback:  ::1 localhost ip6-localhost ip6-loopback

   if ($self->DetectDistroFlavour() eq $UBUNTU10_10) {
      # Find the IPV6 loopback line.
      my $ipv6LoopbackLineIndex =
         Utils::FindLineInBuffer(
            "^\s*::1",
            \@content,
            $Utils::SMDONOTSEARCHCOMMENTS);

      # If found, retrieve the line.
      if ($ipv6LoopbackLineIndex >= 0) {
         my $ipv6LoopbackLine =
            Utils::GetLineWithoutComments($content[$ipv6LoopbackLineIndex]);
         chomp ($ipv6LoopbackLine);

         # If "localhost6" is not present, append it to the ipv6 loopback line.
         if ($ipv6LoopbackLine !~ /\slocalhost6(\s|$)/) {
            $content[$ipv6LoopbackLineIndex] = "$ipv6LoopbackLine localhost6\n";
         }
      } else {
         # ipv6 loopback line should be there, but just in case it's not.
         push(@content, "::1 localhost6\n")
      }
   }

   # Prepend a comment in hosts file stating we are setting the immutable bit.
   # Only do this if the comment header is not already in the file.
   my $commentHeader = "# Changed by VMware Guest OS Customization\n";
   my $commentFlag = "# Immutable flag set to prevent Network Manager from editing the loopback line\n";

   if (Utils::FindLineInBuffer($commentHeader, \@content) == -1) {
      unshift(@content, $commentFlag);
      unshift(@content, $commentHeader);
   }

   # Update hosts files.
   Utils::WriteBufferToFile($hostsFile, \@content);

   # Prevent NetworkManager from touching this file.
   Utils::SetFileImmutableBit($hostsFile);
}

1;