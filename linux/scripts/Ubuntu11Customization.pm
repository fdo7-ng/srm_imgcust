########################################################################################
#  Copyright 2011 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu11Customization;
# Inherit from UbuntuCustomization and not Ubuntu10Customization.
# Ubuntu10Customization has lots of NetworkManager specific handling which is
# no longer necessary for Ubuntu 11.04.
use base qw(UbuntuCustomization);

use strict;
use Debug;

# distro flavour detection constants
my $UBUNTU11_04 = "Ubuntu 11.04";
my $UBUNTU11_10 = "Ubuntu 11.10";

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

      if ($issueContent =~ /Ubuntu\s+11\.10/i) {
         $result = $UBUNTU11_10;
      } elsif ($issueContent =~ /Ubuntu\s+11\.04/i) {
         $result = $UBUNTU11_04;
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }

   return $result;
}

sub CustomizeReslovFile
{
   my ($self) = @_;

   my $resolvFile = $Customization::RESOLVFILE;
   my $bootProto = $self->{_customizationConfig}->Lookup("NIC1|BOOTPROTO");

   # Clear the immutable bit in case it has been set.
   Utils::ClearFileImmutableBit($resolvFile);

   # Do resolv file customization.
   $self->SUPER::CustomizeReslovFile();

   # For Ubuntu 11.10 Desktop, NetworkManager will nullify /etc/resolv.conf
   # on network-manager restart. There are many bugs opened for this.
   # Ref: https://bugs.launchpad.net/ubuntu/+source/network-manager/+bug/875949
   #
   # - Prevent NM from modifying this file if we are on Ubuntu 11.10.
   # - Only do this for static configurations.
   #   - dhclient-script is never called, which means resolv.conf is not updated
   #     with values from dhclient.conf and remains empty.
   # - For DHCP, dhclient-script is always called, which means resolv.conf will be updated.
   #   - If DNSFROMDHCP=no, values are propagated from dhclient.conf to resolv.conf.
   #   - If DNSFROMDHCP=yes, DNS values are propagated from DHCP to resolv.conf.
   #   - Making resolv.conf immutable for DHCP configurations will hang
   #     dhclient-script as it blocks waiting for write access.
   if (($self->DetectDistroFlavour() eq $UBUNTU11_10) &&
       ($bootProto =~ /static/i)) {

      # Re-read in the resolv file.
      my @content = Utils::ReadFileIntoBuffer($resolvFile);

      # Prepend a comment in resolv file stating we are setting the immutable bit.
      # Only do this if the comment header is not already in the file.
      my $commentHeader = "# Changed by VMware Guest OS Customization\n";
      my $commentFlag = "# Immutable flag set to prevent Network Manager from modifying this file.\n";

      if (Utils::FindLineInBuffer($commentHeader, \@content) == -1) {
         unshift(@content, $commentFlag);
         unshift(@content, $commentHeader);
      }

      # Update resolv file.
      Utils::WriteBufferToFile($resolvFile, \@content);

      # Prevent NetworkManager from touching this file.
      Utils::SetFileImmutableBit($resolvFile);
   }
}

# Base properties overrides

sub DHClientConfPath
{
   # Starting with Ubuntu 11.04, the DHCP client package changed from
   # dhcp3-client to isc-dhcp-client. This new package installs and uses conf
   # file from /etc/dhcp/. Prior to this, it was from /etc/dhcp3/
   return "/etc/dhcp/dhclient.conf";
}

1;