#!/usr/bin/perl

########################################################################################
#  Copyright 2008 VMware, Inc.  All rights reserved.
########################################################################################

#.......................................................................................
#
# ConfigFile.pm
#
#     Contains methods for loading a config file and key lookup.
#
#.......................................................................................

package ConfigFile;

use strict;
use Debug;

# The IPv4 configuration mode which directly represents the user's goal.
#
# This mode effectively acts as a contract of the in-guest customization engine. It must
# be set based on what the user has requested via VMODL/generators API and should not be
# changed by those layers. It's up to the in-guest engine to interpret and materialize
# the user's request.
#
# Also defined in linuxconfiggenerator.h.

# The legacy mode which only allows dhcp/static based on whether IPv4 addresses list is empty or not
our $IPV4_MODE_BACKWARDS_COMPATIBLE = 'BACKWARDS_COMPATIBLE';
# IPv4 must use static address. Reserved for future use
our $IPV4_MODE_STATIC = 'STATIC';
# IPv4 must use DHCPv4. Reserved for future use
our $IPV4_MODE_DHCP = 'DHCP';
# IPv4 must be disabled
our $IPV4_MODE_DISABLED = 'DISABLED';
# IPv4 settings should be left untouched. Reserved for future use
our $IPV4_MODE_AS_IS = 'AS_IS';

#.......................................................................................
#
# new
#
#   Constructor.
#
# Params:
#   None.
#
# Result:
#   The constructed object.
#.......................................................................................

sub new
{
   my ($class) = @_;
   my $self = { _configData=> {} };
   bless $self, $class;
   return $self;
}

#.......................................................................................
#
# LoadConfigFile
#
#     Parse the config file and load it into a hash table. The config file is
#     divided into groups eg. [NETWORK]. Each group contains a list of
#     name-value pairs. The key is usually referred as "Group
#     Name|Name"="Value".
#
# Params:
#     $filename     Config filename
#
# Result:
#     None
#
# NOTE:
#
#.......................................................................................

sub LoadConfigFile
{
   # map params
   my ($self, $filename) = @_;

   INFO("Opening file name $filename.");

   open(FD, $filename) || die "$!";

   # read all lines
   my @lines = <FD>;
   close(FD);

   # set category e.g. [NETWORK] as empty
   my $category = "";
   $self->{_configData} = {};

   foreach my $line (@lines) {

      # remove end char \n
      chomp $line;

      # "sensitive" settings shall not be logged
      if (index($line, '-') != 0) {
         DEBUG("Processing line: '$line'");
      } else {
         DEBUG("Processing line: '***********************'");
      }

      # trim it off
      $line = Utils::Trim($line);

      if (length $line == 0) { # empty line
         DEBUG("Empty line. Ignored.");
         next;
      }

      if ($line =~ /(^#)(\s)(.*)/) { # comment
         DEBUG ( "Comment found. Line ignored." );
         next;
      }

      if ( $line =~ /\[(.+)\]/ ) { # category
         DEBUG ( "FOUND CATEGORY = $1" );
         $category = $1;
      } elsif ($line =~ /(.+?)=(.*)/) { # key value pair (non-eager '=' for base64)
         my $key = Utils::Trim($1);
         my $val = Utils::Trim($2);

         # my $keyprefix = $category . "|";
         my $canLog = (index($key, '-') != 0);

         $key = $category . "|" . $key;
         $self->{_configData}->{$key} = $val;

         # "sensitive" settings shall not be logged
         if ($canLog) {
            DEBUG("ADDED KEY-VAL :: '$key' = '$val'");
         } else {
            DEBUG("ADDED KEY-VAL :: '$key' = '*****************'");
         }
      } else {
         die "Config file line unrecognizable. Line : $line \n";
      }
   }
};

#...............................................................................
#
# InsertKey
#
#     Inserts a key.
#
# Params:
#     $key The key is usually "Group Name|Name".
#     $val The value.
#
#...............................................................................

sub InsertKey
{
   my ($self, $key, $val) = @_;

   $self->{_configData}->{$key} = $val;
};

#...............................................................................
#
# RetrieveCategory
#
#     Retrieves all the entries in a given category.
#
# Params:
#     $category The category name (e.g. before the first "|").
#     $categoriesRef Reference to a hashmap containing all categories.
#
# Result:
#     Array of all category entries as strings. Category name is included as a
#     section and filtered out from individual entries.
#
#...............................................................................

sub RetrieveCategory
{
   my ($self, $category, $categoriesRef) = @_;

   my %categories = %{$categoriesRef};
   my @result = ();

   if (exists $categories{$category}) {
      my @lines = $self->Query("^($category\\|)");

      my $sz = @lines;
      if ($sz gt 0) {
         push(@result, "[$category]\n");

         foreach my $line (@lines) {
            my $entry = substr($line, index($line, '|') + 1);

            push(@result, "$entry\n");
         }
      }
   }

   return @result;
}

#...............................................................................
#
# SaveConfigFile
#
#     Saves configuration into a file.
#
# Params:
#     $filename to save config to. If exists, will be overriden.
#
#...............................................................................

sub SaveConfigFile
{
   my ($self, $filename) = @_;

   my %categories=();

   foreach my $key (keys(%{$self->{_configData}})) {
      my $category = substr($key, 0, index($key, '|'));
      $categories{$category} = 1;
   }

   my @content;

   foreach my $category (keys(%categories)) {
      push (@content, $self->RetrieveCategory($category, \%categories));
   }

   Utils::WriteBufferToFile($filename, \@content);
};

#.......................................................................................
#
# PrintConfig
#
#     Print out the hash table that represents the config file.
#
# Params & Result: None
#
# NOTE:
#
#.......................................................................................

sub PrintConfig
{
   my ($self) = @_;
   INFO("Config Data ");
   INFO("----------- ");

   foreach my $key (keys(%{$self->{_configData}})) {
      INFO ( "$key = $self->{_configData}->{$key}" );
   }
};

#.......................................................................................
#
# Lookup
#
#     Lookup for a value in the hash table (that represents the config file)
#     based on the key.
#
# Params:
#     $key      Key to look up on
#
# Result:
#     Value stored in the hash table for the given key
#
# NOTE: The key has to be unique
#       $key is the complete and exact key as in the hash map.
#
#.......................................................................................

sub Lookup
{
   # map the params
   my ($self, $key) = @_;

   return $self->{_configData}->{$key};
};

#.......................................................................................
#
# Query
#
#     Make a query to the configData based on a regex key pattern. This can be
#     used to get an array of matches.
#
# Params:
#     $regex    Regular expression on the key pattern
#
# Result:
#     Array of string (key=value) for which the key pattern matched the key.
#
# NOTE: It is not case-sensitive
#.......................................................................................

sub Query
{
   # map params
   my ($self, $regexQuery) = @_;

   INFO("Query config for $regexQuery");

   my @cfgLines;

   foreach my $key (keys(%{$self->{_configData}})) {
      if ($key =~ /$regexQuery/i) {
         DEBUG("Match Found : $key");
         push(@cfgLines, $key . "=" . $self->{_configData}->{$key});
         DEBUG($#cfgLines);
      }
   }

   return @cfgLines;
}

# Utility methods

#.......................................................................................
#
# ConvertToIndexedArray
#
#  Converts the value returned from Query method to an array where
#  the elements reside at the right index.
#
# Params:
#  $cfgLines   Array of elements with order attached by using the KEY|Index syntax.
#
# Result:
#   Array filled at the right indexes. Not filled indexex have undefined value.
#
#.......................................................................................

sub ConvertToIndexedArray
{
   my (@cfgLines) = @_;

   my @array = ();

   foreach (@cfgLines) {
      if ($_ =~ /(.+)=(.*)/) {
         my $key = $1;
         my $value = $2;

         my @keyTokens = split "\\|", $key;

         if (scalar(@keyTokens) >= 1) {
            $array[pop(@keyTokens) - 1] = $value;
         }
      }
   }

   return @array;
}

#.......................................................................................
#
# ConvertToArray
#
#  Converts the value returned from Query method to an array with the elements
#  order preserved.
#
# Params:
#   $cfgLines   Array of elements with order attached by using the KEY|Index syntax.
#
# Result:
#   Array filled with elements with the order preserved but with no empty elements.
#
#.......................................................................................

sub ConvertToArray
{
   my @compressedArray = ();

   foreach (ConvertToIndexedArray(@_)) {
      if ($_) {
         push(@compressedArray, $_);
      }
   }

   return @compressedArray;
}

#.......................................................................................
#
# Transpose
#
#  Transposes a matrix.
# Params:
#   $matrix
#
# Result:
#   Transposed matrix.
#
#.......................................................................................

sub Transpose
{
   my @resultTable = ();

   for (my $rowIdx = 0; $rowIdx <= $#_; $rowIdx++) {
      for (my $colIdx = 0; $colIdx <= $#{$_[$rowIdx]}; $colIdx++) {
         $resultTable[$colIdx]->[$rowIdx] = $_[$rowIdx]->[$colIdx];
      }
   }

   return @resultTable;
}

#.......................................................................................
# GETTER METHODS
#
# These methods return configuration values and do some validation.
#
# NOTE:
# It is assumed that the validation is common to all supported distros.
# If this stops to be the case these methods should be moved the
# the Customization class.
#.......................................................................................

#.......................................................................................
#
# GetHostName
#
#  Gets the hostname.
#
# Params:
#   None
#
# Result:
#  The hostname if present, or undef otherwise.
#
# Throws:
#  If the hostname is invalid.
#.......................................................................................

sub GetHostName
{
   my ($self) = @_;

   my $result = undef;
   my $hostKey = 'NETWORK|HOSTNAME';
   my $hostName = $self->Lookup($hostKey);

   if (defined $hostName) {
      # Have hostname, check whether it is valid

      $result = Utils::Trim($hostName);

      if (!$result || length($result) > 64) {
         die "The value [$hostName] for [$hostKey] is invalid."
      }
   }

   return $result;
}

#.......................................................................................
#
# GetCustomScriptName
#
#  Gets pre-/post-customization script's path relative to the root of the package.
#
# Params:
#   None
#
# Result:
#  The relative script path if present, or undef otherwise.
#
# Throws:
#  None
#.......................................................................................

sub GetCustomScriptName
{
   my ($self) = @_;

   my $result = undef;
   my $key = 'CUSTOM-SCRIPT|SCRIPT-NAME';
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if (!$result) {
         die "Empty value for custom script name is in invalid."
      }
   }

   return $result;
}

#.......................................................................................
#
# GetResetPassword
#
#  Gets reset password setting.
#
# Params:
#   None
#
# Result:
#  1 if reset is set to "yes", otherwise - 0.
#
# Throws:
#  If the value is invalid.
#.......................................................................................

sub GetResetPassword
{
   my ($self) = @_;

   my $result = 0;
   my $key = 'PASSWORD|RESET';
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(yes|no)$/i) {
         die "The value [$value] for [$key] is invalid."
      }

      $result = ($result =~ /^yes$/i);
   }

   return $result;
}

#...............................................................................
#
# GetUtc
#
#  Gets hadrware clock UTC setting.
#
# Result:
#  UTC value as "yes" or "no".
#
# Throws:
#  If the value is invalid.
#
#...............................................................................

sub GetUtc
{
   my ($self) = @_;

   my $result = undef;
   my $key = 'DATETIME|UTC';
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(yes|no)$/i) {
         die "The value [$value] for [$key] is invalid."
      }
   }

   return $result;
}

#.......................................................................................
#
# GetAdminPassword
#
#  Gets admin password setting.
#
# Params:
#   None
#
# Result:
#  The admin password if present, or undef otherwise.
#
# Throws:
#  None
#.......................................................................................

sub GetAdminPassword
{
   my ($self) = @_;

   return $self->GetNonEmptyStringValue('PASSWORD|-PASS');
}

#.......................................................................................
#
# GetMarkerId
#
#  Gets maker id setting.
#
# Params:
#   None
#
# Result:
#  The marker id if present, or undef otherwise.
#
# Throws:
#  If the value is empty.
#.......................................................................................

sub GetMarkerId
{
   my ($self) = @_;

   return $self->GetNonEmptyStringValue('MISC|MARKER-ID');
}

#.......................................................................................
#
# GetPostGcStatus
#
#  Gets MISC|POST-GC-STATUS setting.
#
# Params:
#   None
#
# Result:
#  Whether to post guestinfo.gc.status VMX property.
#
# Throws:
#  If the value is not 'yes' or 'no' (case-insensitive).
#.......................................................................................

sub GetPostGcStatus
{
   my ($self) = @_;

   return $self->GetBooleanValue('MISC|POST-GC-STATUS', 0);
}

#.......................................................................................
#
# GetBooleanValue
#
#  Gets boolean setting for a given key. Accepts only 'yes' and 'no' case-insensitive.
#
# Params:
#   $key - key to be used for lookup.
#   $default - boolean value to be used if defined and the key is not found.
#
# Result:
#  Setting for a given key if present, or $default (if not defined - 0) otherwise.
#
# Throws:
#  If the value is not 'yes' or 'no' (case-insensitive).
#.......................................................................................

sub GetBooleanValue
{
   my ($self, $key, $default) = @_;

   my $result = 0;

   if($default) {
      $result = $default;
   }

   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(yes|no)$/i) {
         die "The value [$value] for [$key] is invalid."
      }

      $result = ($result =~ /^yes$/i);
   }

   return $result;
}

#.......................................................................................
#
# GetStringValue
#
#  Gets string setting for a given key.
#
# Params:
#   $key - key to be used for lookup.
#
# Result:
#  Trimmed setting for a given key if present, or undef otherwise.
#
# Throws:
#  None
#.......................................................................................

sub GetStringValue
{
   my ($self, $key) = @_;

   my $result = undef;
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);
   }

   return $result;
}

#.......................................................................................
#
# GetNonEmptyStringValue
#
#  Gets string setting for a given key.
#
# Params:
#   $key - key to be used for lookup.
#
# Result:
#  Trimmed setting for a given key if present, or undef otherwise.
#
# Throws:
#  If the value is empty.
#.......................................................................................

sub GetNonEmptyStringValue
{
   my ($self, $key) = @_;

   my $result = undef;
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if (!$result) {
         die "The empty value for [$key] is invalid."
      }
   }

   return $result;
}

#.......................................................................................
#
# GetDomainName
#
#  Gets the domainname.
#
# Params:
#   None
#
# Result:
#  The domainname. Check with IsKeepCurrentValue and IsRemoveCurrentValue
#  before using it.
#
# Throws:
#  If the domainname is invalid.
#.......................................................................................

sub GetDomainName
{
   my ($self) = @_;

   my $result = undef;
   my $domainKey = 'NETWORK|DOMAINNAME';
   my $domainName = $self->Lookup($domainKey);

   if (defined $domainName) {
      $result = Utils::Trim($domainName);
   }

   return $result;
}

#.......................................................................................
#
# GetTimeZone
#
#  Gets the timezone.
#
# Params:
#   None
#
# Result:
#  The timezone if present, or undef otherwise.
#
# Throws:
#  If the timezone is invalid.
#.......................................................................................

sub GetTimeZone
{
   my ($self) = @_;

   my $result = undef;
   my $tzKey = 'DATETIME|TIMEZONE';
   my $tzValue = $self->Lookup($tzKey);

   if (defined $tzValue) {
      # Have hostname, check whether it is valid

      $result = Utils::Trim($tzValue);

      if (!$result) {
         die "The value [$tzValue] for [$tzKey] is invalid."
      }
   }

   return $result;
}

#.......................................................................................
#
# GetDNSFromDHCP
#
#  Gets dns from dhcp setting.
#
# Params:
#   None
#
# Result:
#  true  - if present and set to true
#  false - if present and set to false
#  undef - if not present
#
# Throws:
#  If the setting is invalid.
#.......................................................................................

sub GetDNSFromDHCP
{
   my ($self) = @_;

   my $result = undef;
   my $key = 'DNS|DNSFROMDHCP';
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(yes|no)$/i) {
         die "The value [$value] for [$key] is invalid."
      }

      $result = ($result =~ /^yes$/i);
   }

   return $result;
}

#.......................................................................................
#
# GetDNSSuffixes
#
#  Gets the list of dns suffixes.
#
# Params:
#   None
#
# Result:
#  ref to list
#.......................................................................................

sub GetDNSSuffixes
{
   my ($self) = @_;

   return [ ConvertToArray($self->Query("^(DNS\\|SUFFIX\\|)")) ];
}

#.......................................................................................
#
# GetNameServers
#
#  Gets the list of dns name servers.
#
# Params:
#   None
#
# Result:
#  ref to list
#.......................................................................................

sub GetNameServers
{
   my ($self) = @_;

   return [ ConvertToArray($self->Query("^(DNS\\|NAMESERVER\\|)")) ];
}

#.......................................................................................
#
# GetMACAddress
#
#  Gets the MAC address for the specified nic.
#
# Params:
#   $nic - nic whose MAC address to get
#
# Result:
#  The MAC address
#.......................................................................................

sub GetMACAddress
{
   my ($self, $nic) = @_;

   my $key   = $nic . "|MACADDR";
   my $value = Utils::Trim($self->Lookup($key));

   if (! Utils::IsValidMACAddress($value)) {
      die "Invalid MAC address [$value] for nic [$nic]";
   }

   return $value;
}

#.......................................................................................
#
# GetPrimary
#
#  Gets the 'PRIMARY' attribute for the specified NIC.
#  Possible values are 'yes' and 'no'. It's optional.
#  If not provided, assumed to be 'no'.
#
# Params:
#   $nic - NIC whose 'PRIMARY' attribute to get
#
# Result:
#  'PRIMARY' attribute (true/false)
#
# Throws:
#  If 'PRIMARY' attribute is invalid.
#.......................................................................................

sub GetPrimary
{
   my ($self, $nic) = @_;

   my $result = 0;
   my $key = $nic . "|PRIMARY";
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(yes|no)$/i) {
         die "The value [$value] for [$key] is invalid."
      }

      $result = ($result =~ /^yes$/i);
   }

   return $result;
}

#.......................................................................................
#
# GetBootProto
#
#  Gets the 'BOOTPROTO' attribute for the specified NIC.
#  Possible values are 'STATIC' and 'DHCP'.
#
# Params:
#   $nic - NIC whose 'BOOTPROTO' attribute to get
#
# Result:
#  'BOOTPROTO' attribute
#
# Throws:
#  If 'BOOTPROTO' attribute is invalid or not provided.
#.......................................................................................

sub GetBootProto
{
   my ($self, $nic) = @_;

   my $result = undef;
   my $key = $nic . "|BOOTPROTO";
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result !~ /^(static|dhcp)$/i) {
         die "The value [$value] for [$key] is invalid. Must be STATIC or DHCP."
      }

      return $result
   } else {
      die "BOOTPROTO must be defined."
   }

   return $result;
}

#.......................................................................................
#
# GetIpV4Mode
#
#  Gets the 'IPv4_MODE' attribute for the specified NIC.
#  Possible values are BACKWARDS_COMPATIBLE, STATIC, DHCP, DISABLED, AS_IS (see IPV4_MODE_* constants).
#
# Params:
#   $nic - NIC whose 'IPv4_MODE' attribute to get
#
# Result:
#  'IPv4_MODE' attribute or $IPV4_MODE_BACKWARDS_COMPATIBLE if not set
#
# Throws:
#  If 'IPv4_MODE' attribute is invalid
#.......................................................................................

sub GetIpV4Mode
{
   my ($self, $nic) = @_;

   my $result = undef;
   my $key = $nic . "|IPv4_MODE";
   my $value = $self->Lookup($key);

   if (defined $value) {
      $result = Utils::Trim($value);

      if ($result ne $IPV4_MODE_BACKWARDS_COMPATIBLE
            && $result ne $IPV4_MODE_STATIC
            && $result ne $IPV4_MODE_DHCP
            && $result ne $IPV4_MODE_DISABLED
            && $result ne $IPV4_MODE_AS_IS) {
         die "The value [$value] for [$key] is invalid (see GuestCust::IpV4Mode)."
      }

      return $result
   } else {
      # make sure the older clients still work
      return $IPV4_MODE_BACKWARDS_COMPATIBLE;
   }

   return $result;
}

#.......................................................................................
#
# GetPrimaryNic
#
#  Determines NIC (if any) marked as 'PRIMARY'.
#
# Result:
#  NIC's ID or undef
#
# Throws:
#  If more than one NIC is marked as 'PRIMARY'.
#.......................................................................................

sub GetPrimaryNic
{
   my ($self) = @_;

   my $result = undef;

   foreach my $nic ($self->GetNICs()) {
      if ($self->GetPrimary($nic)) {
        if ($result) {
            die "There can be only one primary NIC defined."
        }
        $result = $nic;
      }
   }

   return $result;
}

#.......................................................................................
#
# GetNICs
#
#  Gets the list of nics.
#
# Params:
#  None
#
# Result:
#  List with nic names. Empty list if no nics specified in customization spec.
#.......................................................................................

sub GetNICs
{
   my ($self) = @_;

   my $key   = 'NIC-CONFIG|NICS';
   my $value = $self->Lookup($key);

   return map {Utils::Trim($_)} split(/,/, $value);
}

#.......................................................................................
#
# GetGateways
#
#  Gets the list of gateways for a nic
#
# Params:
#  $nic - nic whose gateways to get
#
# Result:
#  List with gateways. Empty list if no gateways specified for the nic
#  in customization spec.
#.......................................................................................

sub GetGateways($)
{
   my ($self, $nic) = @_;

   my $key   = $nic . "|GATEWAY";
   my $value = Utils::Trim($self->Lookup($key));

   return (defined $value) ? (map {Utils::Trim($_)} split(/,/, $value)) : ();
}

#.......................................................................................
#
# IsKeepCurrentValue
#
#  Tells whether the current OS setting of the config value should be left as is.
#
# Params:
#  $configValue
#
# Result:
#  True when the current setting should not be changed, false otherwise.
#.......................................................................................

sub IsKeepCurrentValue($)
{
   my ($configValue) = @_;

   return (! defined $configValue);
}

#.......................................................................................
#
# IsRemoveCurrentValue
#
#  Tells whether the current OS setting of the config value should be removed.
#
# Params:
#  $configValue
#
# Result:
#  True when the current setting should be removed, false otherwise.
#.......................................................................................

sub IsRemoveCurrentValue($)
{
   my ($configValue) = @_;

   return (!IsKeepCurrentValue($configValue) && !$configValue);
}

#.......................................................................................
# Return value for module as required by the perl
#.......................................................................................

1;
