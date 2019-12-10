#!/usr/bin/perl

################################################################################
#  Copyright 2014-2018 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# Utils.pm
#
#   This script contains a collection of utility functions related to:
#     - text and text file manipulation.
#     - other
#
#...............................................................................

package Utils;

use strict;
use Debug;
use Cwd qw(abs_path);
use Fcntl; # for file open flags, O_CREAT etc.
# Do not use make_path yet, as we need to support old distro like SLES11
use File::Path qw(mkpath);
use File::Spec;
use File::stat qw(stat);
use Scalar::Util qw(blessed);
use InstantCloneConstants qw();

# System utilities
our $AWK = '';
our $CAT = '/bin/cat';
our $CHMOD = '/bin/chmod';
our $CP = '/bin/cp';
our $ECHO = '/bin/echo';
our $GREP = '/bin/grep';
our $MKDIR = '/bin/mkdir';
our $MV = '/bin/mv -f';
our $RM = '/bin/rm -f';
our $SH = '/bin/sh';
our $SYNC = '/bin/sync';
our $KILL = '/bin/kill';
our $TAIL = '/usr/bin/tail';
our $TOUCH = '/bin/touch';
our $TR = '/usr/bin/tr';
# Solaris needs the xpg4 awk
if (-e '/usr/xpg4/bin/awk') {
   $AWK = '/usr/xpg4/bin/awk';
} elsif (-e '/usr/bin/awk') {
   $AWK='/usr/bin/awk';
}
our $READLINK = '/usr/bin/readlink';
our $RPC_LOG_FILE = '/var/log/vmware-imc/rpc.log';
our $LINUX_CUST_NOTIFIER_FILENAME = 'linuxcustnotifier';
our $LINUX_CUST_NOTIFIER_PATH = '';
our $CUSTOMIZATION_LOCK_DIR = '/var/lock/vmware';
our $CUSTOMIZATION_LOCK_FILE = '/var/lock/vmware/gosc';
our $CUSTOMIZATION_LOCK_THRESH_HOLD = 3600; # one hour
our $CUSTOMIZATION_LOCKED = 0;
our $USE_NAMESPACE_CMD = 0; # disable using the namespace cmd, bug 2080768
our $NOTIFIER_DEBUG = 'LINUX_CUST_NOTIFIER_DEBUG=1';

#...............................................................................
#
# LockCustomization
#
#   Lock the customization if there is no other guest customization process
#   running.
#
# Params:
#   None.
#
# Result:
#   1 if successfully locked customization, otherwise - 0.
#
# Throws:
#   None.
#...............................................................................

sub LockCustomization
{
   if (not -e $CUSTOMIZATION_LOCK_DIR) {
      DEBUG("Creating directory $CUSTOMIZATION_LOCK_DIR");
      mkpath($CUSTOMIZATION_LOCK_DIR);
   }

   if (not -d $CUSTOMIZATION_LOCK_DIR) {
      die "Require $CUSTOMIZATION_LOCK_DIR to be a directory.";
   }

   # The lock file might be stale due to an earlier unexpected system crash.
   # Check and handle this situation.
   # Cannot use monotonic time for this, so there might still be an issue.
   # If the system time was moved back, customers can be advised to manually
   # remove the lock file if we are sure there is no real race condition.
   # Conversely, if the system time was moved ahead, there might be premature
   # auto removal of the lock file causing possible race conditions.
   if (-f $CUSTOMIZATION_LOCK_FILE) {
      my $stat = stat($CUSTOMIZATION_LOCK_FILE);
      my $mtime = $stat->mtime;
      my $now = time();
      my $mtimeLocal = localtime($mtime);
      my $nowLocal = localtime($now);
      DEBUG("Current time is $nowLocal");
      DEBUG("$CUSTOMIZATION_LOCK_FILE last modified at $mtimeLocal");
      if ($now > $mtime + $CUSTOMIZATION_LOCK_THRESH_HOLD) {
         WARN("$CUSTOMIZATION_LOCK_FILE is stale, removing...");
         unlink($CUSTOMIZATION_LOCK_FILE);
      }
   }

   DEBUG("Opening $CUSTOMIZATION_LOCK_FILE in O_CREAT|O_EXCL|O_WRONLY mode");
   my $fh;
   my $ok = sysopen($fh, $CUSTOMIZATION_LOCK_FILE,
                    O_CREAT | O_EXCL | O_WRONLY);
   if (not $ok) {
      WARN("Cannot create the lock file $CUSTOMIZATION_LOCK_FILE, $!");
      return 0;
   }

   # $$ is the PID of this process.
   print $fh "$$";

   close($fh);
   $CUSTOMIZATION_LOCKED = 1;

   return 1;
}

#...............................................................................
#
# UnlockCustomization
#
#   Unlock the customization if we are holding the customization file lock.
#
# Params:
#   None.
#
# Result:
#   None.
#
# Throws:
#   None.
#...............................................................................

sub UnlockCustomization
{
   if (not $CUSTOMIZATION_LOCKED) {
      DEBUG("Customization lock not owned, returning.");
      return;
   }

   DEBUG("Removing lock file $CUSTOMIZATION_LOCK_FILE.");
   unlink($CUSTOMIZATION_LOCK_FILE);
}

#...............................................................................
#
# KillCustomizationProcess
#
#   Kill the running customization process identified by the pid.
#   If the process is not a customization process, this is a no-op
#
# Params:
#   $pid   The process id.
#
# Result:
#   None.
#
# Throws:
#   None.
#...............................................................................

sub KillCustomizationProcess
{
   my ($pid) = @_;
   my $fh;

   my $ok = open($fh, "/proc/$pid/cmdline");
   if (not $ok) {
      DEBUG("Unable to open file /proc/$pid/cmdline, $!");
      return;
   }
   my @lines = <$fh>;
   close($fh);

   my $cmdline = @lines[0];
   if ($cmdline =~ /perl.*InstantClone/) {
      ExecuteCommand("$KILL -SIGTERM $pid", "Terminating process $pid");
   } else {
      DEBUG("Process $pid is not a customization process, skipping");
   }
}

#...............................................................................
#
# KillUnlockOtherCustomization
#
#   Kill the running process that is holding the customization lock
#   and forcefully remove the lock.
#
# Params:
#   None.
#
# Result:
#   None.
#
# Throws:
#   None.
#...............................................................................

sub KillUnlockOtherCustomization
{
   my $fh;

   my $ok = open($fh, $CUSTOMIZATION_LOCK_FILE);
   if (not $ok) {
      DEBUG("Unable to open lock file $CUSTOMIZATION_LOCK_FILE, $!");
      return;
   }
   my @lines = <$fh>;
   close($fh);

   if (@lines) {
      my $pid = $lines[0];
      if ($pid) {
         KillCustomizationProcess($pid);
      } else {
         DEBUG("No pid in lock file $CUSTOMIZATION_LOCK_FILE, skip killing");
      }
   }

   DEBUG("Removing lock file $CUSTOMIZATION_LOCK_FILE.");
   unlink($CUSTOMIZATION_LOCK_FILE);
}

#...............................................................................
#
# SetLinuxCustNotifierDir
#
#   Set the containing directory of the Linux customization notifier.
#
# Params:
#   None.
#
# Result:
#   None.
#
# Throws:
#   None.
#...............................................................................

sub SetLinuxCustNotifierDir
{
   my ($directory) = @_;
   $LINUX_CUST_NOTIFIER_PATH = File::Spec->join($directory,
                                                $LINUX_CUST_NOTIFIER_FILENAME);
}

#...............................................................................
#
# GetLinuxCustNotifierCmd
#
#   Determines the command to launch the Linux customization notifier.
#
# Params:
#   None.
#
# Result:
#   Path to the Linux customization notifier.
#
# Throws:
#   If the Linux customization notifier does not exist.
#...............................................................................

sub GetLinuxCustNotifierCmd
{
   # If it is not set by the application, assume the CLI is in the scripts
   # directory.
   if ($LINUX_CUST_NOTIFIER_PATH eq '') {
      my $dir = Utils::DirName(abs_path(__FILE__));
      $LINUX_CUST_NOTIFIER_PATH = File::Spec->join($dir,
                                                $LINUX_CUST_NOTIFIER_FILENAME);
   }

   if (not -x $LINUX_CUST_NOTIFIER_PATH) {
      die "Require $LINUX_CUST_NOTIFIER_PATH to exist and be an executable.";
   }

   return "$NOTIFIER_DEBUG  $LINUX_CUST_NOTIFIER_PATH";
}

#...............................................................................
#
# AppendBufferToFile
#
#     Append a given buffer to the file.
#
# Params:
#     $filename   The file to append to
#     $buffer     Buffer to add it to -- Pass by reference
#
# Result:
#     None
#
#...............................................................................

sub AppendBufferToFile
{
   my ($filename, $buffer) = @_;

   eval {
      DEBUG("opening file $filename for appending.");
      open(FD, ">>$filename") || die "$!";

      foreach (@{ $buffer }) {
         print FD $_;
      }

      close (FD);
   }; if ($@) {
      die "$!:Error appending data to file ($filename). $@"
   };
};

#...............................................................................
#
# AppendLineToFile
#
#     Append a given line to the file.
#
# Params:
#     $filename   The file to append to
#     $line       Line to add
#
# Result:
#     None
#
#...............................................................................

sub AppendLineToFile
{
   my ($filename,$line) = @_;

   my @lines = ($line);

   AppendBufferToFile($filename, \@lines);
}

#...............................................................................
#
# CreateFileLinesIndex
#
#     Creates an index of the lines in a file
#
# Params:
#     $filename  The name of the file to be indexed.
#
# Return:
#    A hash where each line from the file is inserted as a key.
#
#...............................................................................

sub CreateFileLinesIndex
{
   my ($filename) = @_;

   my %linesInFile = ();

   eval {
      DEBUG("creating index of file lines for file $filename.");
      %linesInFile = map { $_ => 1 } ReadFileIntoBuffer ( $filename );
   }; if ($@) {
      WARN("Error trying to index file $filename ($@). Ignored.");
   }

   return  %linesInFile;
};

#...............................................................................
#
# AppendNotContainedLinesToFile
#
#     Appends given lines to a file that are not contained already in it
#
# Params:
#     $filename            The name of the appended file
#     $linesToAppend    Array of lines (buffer) -- Pass by reference
#
# Return:
#     None
#
#...............................................................................

sub AppendNotContainedLinesToFile
{
   my ($filename, $linesToAppend) = @_;

   # Index the file for faster lookup
   my %linesInFile = CreateFileLinesIndex( $filename );

   # Open file in append mode
   eval {
      DEBUG("opening file $filename for appending not contained file lines.");
      open(FD, ">>$filename") || die "$!";

      # Append only lines that are not already in file
      foreach (@{ $linesToAppend }) {
         if (not exists $linesInFile{$_}) {
            print FD $_;
         }
      }

      close ( FD );
   }; if ($@) {
      die "$!:Error appending not contained lines to file($filename). $@"
   };
};

our $SMDONOTSEARCHCOMMENTS   = 1;

#...............................................................................
#
# ReplaceOrAppendInLines
#
#     Finds and replaces all occurrences text (line) in given buffer (array of lines).
#     The search is done based on the supplied regex. Replace is complete replace of
#     the line.
#
#     If the pattern is not found the given line is appended to the
#     arrany of lines.
#
# Params:
#     $regex         Expression to search for
#     $replaceWith   Replace with this line
#     $lines           Array of lines (buffer) -- Pass by reference
#     $skipComments    If true, will search only in non-comments.
#
# Return:
#     New array with the changed data.
#
# NOTE: Pass by reference
#
#...............................................................................

sub ReplaceOrAppendInLines
{
   my ($regex, $replaceWith, $lines, $skipComments) = @_;

   my $found = 0;

   if ($skipComments) {
      foreach (@{ $lines }) {
         if (GetLineWithoutComments($_) =~ /$regex/i) {
            $_ = $replaceWith;
            $found = 1;
         }
      }
   } else {
      foreach (@{ $lines }) {
         if ($_ =~ /$regex/i) {
            $_ = $replaceWith;
            $found = 1;
         }
      }
   }

   if (not $found) {
      push ( @{ $lines }, $replaceWith );
   }
};

our $SMRETURNFIRSTMATCH   = 1;

#...............................................................................
#
# FindLinesInBuffer
#
#     Search for the specific pattern in buffer of lines and return the indices of
#     all the matched lines.
#
# Param:
#     $regex      Regex expression to search for
#     $lines      Reference to the buffer of lines
#     $skipComments      Whether to search only in non-comments
#     $returnFirstMatch  Whether to stop searching after a first match is found.
#
# Returns:
#     The array with indices of all the matched lines.
#
#...............................................................................

sub FindLinesInBuffer
{
   my ($regex, $lines, $skipComments, $returnFirstMatch) = @_;
   my $currentIndex = -1;
   my @indices = ();

   if ($skipComments) {
      foreach (@{ $lines }) {
         $currentIndex++;

         if (GetLineWithoutComments($_) =~ /$regex/i) {
            push(@indices, $currentIndex);
            if ($returnFirstMatch) {
               return @indices;
            }
         }
      }
   } else {
      foreach (@{ $lines }) {
         $currentIndex++;

         if ($_ =~ /$regex/i) {
            push(@indices, $currentIndex);
            if ($returnFirstMatch) {
               return @indices;
            }
         }
      }
   }
   return @indices;
}

#...............................................................................
#
# FindLineInBuffer
#
#     Search for the specific pattern in buffer of lines and return the index of the
#     first instance of the matched line.
#
# Param:
#     $regex      Regex expression to search for
#     $lines      Reference to the buffer of lines
#     $skipComments    Whether to search only in non-comments
#
# Returns:
#     The index of the line that was found or -1.
#
#...............................................................................

sub FindLineInBuffer
{
   my ($regex, $lines, $skipComments) = @_;

   my @indices = FindLinesInBuffer($regex,
                                   $lines,
                                   $skipComments,
                                   $SMRETURNFIRSTMATCH);

   if (@indices) {
      return $indices[0];
   } else {
      return -1;
   }
}

#...............................................................................
#
# GetLineWithoutComments
#
# Param:
#     $line
#
# Returns:
#     The line up to the first comment or undef if the whole line is commented.
#
#...............................................................................

sub GetLineWithoutComments
{
   my ($line) = @_;
   my @tokens = split "#", $line;
   return $tokens[0];
}

#...............................................................................
#
# ReadFileIntobuffer
#
#     Read the contents of the entire file into buffer.
#
# Params:
#     $filename     File name whose content is to be read
#
# Return:
#     Array of lines read
#
# NOTE:
#
#...............................................................................

sub ReadFileIntoBuffer
{
   my ($filename) = @_;
   my @lines   = [];

   eval {
      DEBUG("opening file $filename.");
      open(FD, $filename) || die "$!";

      @lines = <FD>;

      close ( FD );
   }; if ($@) {
      die "$!:Error reading data from file into memory ($filename). $@"
   };

   return @lines;
};

#...............................................................................
#
# WriteBufferToFile
#
#     Write the buffer to the specified file.
#
# Params:
#     $filename     File name to write to
#     $lines        Buffer (array of lines) to be written -- Pass by reference
#
# Return:
#     None
#
# NOTE:
#
#...............................................................................

sub WriteBufferToFile
{
   my ($filename,$lines) = @_;

   eval {
      DEBUG("opening file for writing ($filename).");

      open(FD, ">$filename" ) || die "$!";
      print FD @{ $lines };
   }; if ($@) {
      if ($@ =~ /Permission denied/i) {
         DEBUG("Permission denied writing data to file $filename.");

         # In few cases (like the file has immutable bit set),
         # writing to the file will fail with 'permission denied' error.
         # In such case, print the output of lsattr and stat so that it will
         # be easy to investigate and debug from the log files.

         ExecuteCommand("lsattr $filename", "File Attributes: $filename");
         ExecuteCommand("stat $filename", "File stat: $filename");
      }
      die "$!:Error writing data to file ($filename). $@";
   };

   close ( FD );
}

#...............................................................................
#
# WriteLineToFile
#
#     Write the buffer to the specified file.
#
# Params:
#     $filename     File name to write to
#     $line         Line to be written
#
# Return:
#     None
#
#...............................................................................

sub WriteLineToFile
{
   my ($filename,$line) = @_;

   my @lines = ($line);

   WriteBufferToFile($filename, \@lines);
}

#...............................................................................
#
# SetFileAttribute
#
#     Set attribute for a given file (chattr).
#
# Params:
#     $filename     File name to set the attribute
#     $attribute    Actual attribute in symbolic mode: +-=[ASacDdIijsTtu]
#     $silent       Optional. Silence any errors.
#
# Returns:
#     None
#
# NOTE: Only generates a warning if the command fails and no silent parameter.
#       Only valid for filesystems >= ext2. Use silent to silence errors.
#
#...............................................................................

sub SetFileAttribute
{
   my ($filename, $attribute, $silent) = @_;

   my $result = 1;
   my $redirect = $silent ? " >/dev/null 2>&1" : "";
   ExecuteCommand("chattr $attribute $filename" . $redirect, "", \$result);

   if ($result != 0) {
      die "SetFileAttribute failed with $result.";
   }
}

#...............................................................................
#
# SetFileImmutableBit
#
#     Explicit and less error-prone way to set the immutable bit on a file.
#
# Params:
#     $filename     File name to make immutable
#
# Returns:
#     None
#
#...............................................................................

sub SetFileImmutableBit
{
   my ($filename) = @_;

   SetFileAttribute($filename, "+i", 1);
}

#...............................................................................
#
# ClearFileImmutableBit
#
#     Explicit and less error-prone way to clear the immutable bit on a file.
#
# Params:
#     $filename     File name to make mutable
#
# Returns:
#     None
#
#...............................................................................

sub ClearFileImmutableBit
{
   my ($filename) = @_;

   SetFileAttribute($filename, "-i", 1);
}

#...............................................................................
#
# SetPermission
#
#     Set permission for a given file (chmod).
#
# Params:
#     $filename     File name to set the permission
#     $permission   Actual permission (unix <owner><Group><Other> style
#
# Returns:
#     None
#
# NOTE: Only generated a warning if the command fails.
#
#...............................................................................

# permissions
our $RWRR = "644";
our $RW00 = "600";

sub SetPermission
{
   my ($filename, $permission) = @_;

   my $result = 1;
   ExecuteCommand("chmod $permission $filename", "", \$result);

   if ($result != 0) {
      WARN("chmod failed.");
   }
}

#...............................................................................
#
# GetValueFromFile
#
#     Search for a specific pattern in a file. The pattern should have exactly
#     only one grouping e.g. /NAME.*\=(.*)/
#
# Params:
#     $filename   File to search for
#     $regex   The regex pattern to search
#
# Result:
#     Returns the string that matched with the grouping basically $1 or
#     undef if no match is found
#
# NOTE: Only the first grouping in the regex will be returned
#
#...............................................................................

sub GetValueFromFile
{
   # map params for the function
   my ($filename, $regex) = @_;

   my @content = ReadFileIntoBuffer($filename);

   foreach (@content) {
      if ($_ =~ /$regex/i) {
         DEBUG("Match found   : Line = $_");
         DEBUG("Actual String : $1");

         return $1;
      }
   }

   return undef;
}

#...............................................................................
#
# AddOrReplaceInFile
#
#     Replaces a line with a new line in a file. File name, old line to replace and
#     and new line is passed in as argument. If the old line is not found in the file
#     new line is appended to the file.
#
#     If the file passed in as argument doesn't exist then it is created.
#
#...............................................................................

sub AddOrReplaceInFile
{
   my ($file, $oldLine, $newLine, $skipComments) = @_;

   my @fileData = ();

   if (-e $file) {
      open(CONF_FILE, $file) or die("Could not open file $file!");
      @fileData = <CONF_FILE>;
      close(CONF_FILE);
  } else {
      open(CONF_FILE, ">$file") or die("Could not create file $file!");
      close(CONF_FILE);
  }

   ReplaceOrAppendInLines($oldLine, $newLine . "\n", \@fileData, $skipComments);

   WriteBufferToFile($file, \@fileData);
   SetPermission($file, $RWRR);
}


#...............................................................................
#
# DeleteInFile
#
#     Replace a line with a null string in a file. File name, old line to replace and
#     and new line is passed in as argument. If the old line is not found in the file
#     null string is appended to the file.
#
# Params:
#     $file   File Path whose content needs to be changed
#     $oldLine Line to be replaced with empty string.
#
# Returns:
#     None
#...............................................................................

sub DeleteInFile
{
   my ($file, $oldLine, $skipComments) = @_;

   my @fileData = ();

   if (-e $file) {
      open(CONF_FILE, $file) or die("Could not open file $file!");
      @fileData = <CONF_FILE>;
      close(CONF_FILE);
      ReplaceOrAppendInLines($oldLine, "", \@fileData, $skipComments);

      WriteBufferToFile($file, \@fileData);
      SetPermission($file, $RWRR);
  }

}

#...............................................................................
#
# IsValidMACAddress
#
#   Tells whether a given mac address is valid.
#
# Params:
#   $macAddress
#
# Result:
#   true if $macAddress is valid, false otherwise.
#
#...............................................................................

sub IsValidMACAddress
{
   my ($macAddress) = @_;

   return ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);
}

#...............................................................................
#
# ParseMACAddress
#
#   Parses a mac address with any kind of byte delimiter into array of integers.
#
# Params:
#   $macAddress
#
# Result:
#   An array of 6 integers corresponding to each byte of the MAC address.
#
#...............................................................................

sub ParseMACAddress
{
   my ($macAddress) = @_;
   my @result = [];

   if (IsValidMACAddress($macAddress)) {
      my @macAddressBytes = split(/$1/, $macAddress);

      @result = map {hex} @macAddressBytes;
   } else {
      die "[$macAddress] is not a valid MAC Address";
   }

   return @result;
}

#...............................................................................
#
# NormalizeMACAddress
#
#   Normalizes  a mac address with any kind of byte delimiter and hex byte format.
#
# Params:
#   $macAddress
#
# Result:
#   A string in the format AA:BB:CC:DD:EE:FF
#
#...............................................................................

sub NormalizeMACAddress
{
   my ($macAddress) = @_;

   return join ":", (map {sprintf "%.2X",$_} ParseMACAddress($macAddress));
}

#...............................................................................
#
# ExecuteCommand
#
#   Executes a command displaying description and debug info.
#
# Params:
#   $command      - command to be executed
#   $commandDescription   - description of the command
#   $commandReturnCode - a ref to a scalar where the command return code may be stored
#
# Result:
#   The result of the command execution.
#
#...............................................................................

sub ExecuteCommand
{
   my ($command, $commandDescription, $commandReturnCode, $secure) = @_;

   if ($commandDescription) {
      INFO($commandDescription);
   }

   if (!$secure) {
      DEBUG("Command: '$command'");
   } else {
      DEBUG("Command: '**************'");
   }
   my $commandOutput = `$command`;
   # The return value of the exit status of the program
   # as returned by the "wait" call. To get the actual
   # exit value divide by 256.
   # signal_num = $? & 127
   # dumped_core = $? & 128
   my $returnCode = $?;
   my $exitCode = $returnCode >> 8;
   DEBUG("Exit Code: $exitCode");

   if (!$secure) {
      DEBUG("Result: $commandOutput");
   }

   if ($commandReturnCode) {
      $$commandReturnCode = $returnCode;
   }

   return $commandOutput;
}

#...............................................................................
#
# ExecuteTimedCommand
#
#   Executes a command with given timeout.
#
# Params:
#   $command  - command to be executed
#   $timeout  - timeout in seconds
#
# Result:
#   Stdout of the command OR "undef" if the command timed out or some execution
#   error has occurred.
#
#...............................................................................

sub ExecuteTimedCommand
{
   my ($command, $timeout) = @_;

   DEBUG("TimedCommand: '$command' with timeout of $timeout sec");

   my $tmpFilePath = "/tmp/timed_out_tmp_file_$$";
   unlink($tmpFilePath);

   my $timedOut = 1;

   my $pid = fork;
   if ($pid > 0){
     eval {
        # redefine local SIGALRM
        # if SIGNAL is negative, it kills process groups instead of processes
        local $SIG{ALRM} = sub {
          ERROR("TimedCommand SIGALRM triggered: killing the command process");
          # -INT is sent to avoid stderr output which causes CustomizationFailed
          # VC event
          ExecuteCommand("pkill -INT -P $pid");
          die "Timed out after $timeout sec!";
        };
        # seconds
        alarm $timeout;
        waitpid($pid, 0);
        # reset alarm, especially if exit early
        alarm 0;
        $timedOut = 0;
     };
   } elsif ($pid == 0){ # child
     setpgrp(0,0);
     exec("$command > $tmpFilePath");
     exit(0);
   }

   my $commandOutput = undef;

   if (!$timedOut and -e $tmpFilePath) {
     DEBUG("Fetching result from $tmpFilePath");
     if (open(FD, $tmpFilePath)) {
        $commandOutput = join("", <FD>);
        close(FD);
     }
   }

   unlink($tmpFilePath);

   DEBUG("TimedResult: $commandOutput");

   return $commandOutput;
}

#...............................................................................
#
# ExecuteCommandLogStderr
#
#   Executes a command and redirect the stderr to log
#   Useful when a caller needs to parse the stdout
#
# Params:
#   $command      - command to be executed
#   $commandDescription   - description of the command
#   $commandReturnCode - a ref to a scalar where the command return code may be stored
#
# Result:
#   The result of the command execution.
#
#...............................................................................

sub ExecuteCommandLogStderr
{
   my ($command, $commandDescription, $commandReturnCode, $secure) = @_;
   my $tmpfile = "/tmp/guest.customization.stderr";
   my $cmd = "$command 2>$tmpfile";
   my $output = ExecuteCommand($cmd, $commandDescription,
                               $commandReturnCode, $secure);
   if (open(my $fh, '<', $tmpfile)) {
      local $/;
      my $content = <$fh>;
      DEBUG("Stderr: $content");
      close($fh);
   }
   # Intentionally leave out the removing of the tmp file for now since we
   # will always reuse the same tmp file and can run faster when
   # running multiple commands in sequence.

   return $output;
}

#...............................................................................
#
# Trim
#
#   Trim the given string of spaces and tabs from left and right.
#
# Params:
#   $string   String to be trimmed
#
# Result:
#   Trimmed string
#
# NOTE:
#
#...............................................................................

sub Trim
{
   my ($string) = @_;

   $string =~ s/^[\s\t]+//;
   $string =~ s/[\s\t]+$//;

   return $string;
}

#...............................................................................
#
# StripTrailingLineBreak
#
#   Clean the given string of the trailing line breaks (\r and/or \n). Line
#   breaks inside multi-line strings will be preserved.
#
# Params:
#   $string   String to be cleaned up
#
# Result:
#   String without trailing line breaks (\r and/or \n)
#
# Throws:
#   None
#...............................................................................

sub StripTrailingLineBreak
{
   my ($string) = @_;

   $string =~ s/\015?\012?$//;

   return $string;
}

#...............................................................................
#
# ExtractDirFromPath
#
#   Extracts the directory from a file path.
#
# Params:
#   $filePath - full or relative path
#
# Result:
#   Extracted directory, or '.' for current directory.
#
#...............................................................................

sub ExtractDirFromPath
{
   my ($filePath) = @_;
   my ($dir) = ($filePath =~ m/^(.*)\/[^\/]+$/);
   return $dir ? $dir : ".";
}

#...............................................................................
#
# ExtractFileFromPath
#
#   Extracts the file from a file path.
#
# Params:
#   $filePath - full or relative file path
#
# Result:
#  Extracted file name.
#
#...............................................................................

sub ExtractFileFromPath
{
   my @tokens = split("/", $_[0]);
   return $tokens[$#tokens];
}

#...............................................................................
#
# DeleteFiles
#
#   Deletes a list of files
#
# Params:
#   List of file paths
#
#...............................................................................

sub DeleteFiles
{
   my $arrSize = @_;
   DEBUG("Deleting $arrSize files...");
   for my $filePath (@_) {
      DEBUG("Deleting $filePath...");
      if (-e $filePath && ! -d $filePath) {
         (unlink($filePath) == 1) || die "File $filePath could not be deleted - $!";
      } else {
         DEBUG("Skipping the delete: file doesn't exist or is a directory");
      }
   }
}

#...............................................................................
#
# GetShortnameFromFQDN
#
#   Gets the hostname from a FQDN hostname.
#
# Params:
#   $fqdn - Fully qualified domain name.
#
# Returns:
#   The hostname up to the first dot or undef if $fqdn is invalid.
#...............................................................................

sub GetShortnameFromFQDN($)
{
   my ($fqdn) = @_;

   my $result = undef;

   if (Trim($fqdn) =~ /^([^.]+)/ ) {
      $result = $1;
   }

   return $result;
}

#...............................................................................
#
# GetDomainnameFromFQDN
#
#   Gets the domainname from a FQDN hostname.
#
# Params:
#   $fqdn - Fully qualified domain name.
#
# Returns:
#   The domainname after the first dot or undef if no dot found.
#...............................................................................

sub GetDomainnameFromFQDN($)
{
   my ($fqdn) = @_;

   my $result = undef;

   if (Trim($fqdn) =~ /^([^.]+)\.(.+)$/) {
      $result = $2;
   }

   return $result;
}

#...............................................................................
#
# SupportsOption
#
#   Determines whether the program support a given comman-line option.
#
# Params:
#   $program    - program to check
#   $option     - option to check
#
# Result:
#   1 if option is supported, otherwise - 0.
#
#...............................................................................

sub SupportsOption
{
   my ($program, $option) = @_;

   ExecuteCommand("$program --help 2>&1 | grep '\\-$option'");
   my $result = ($? >> 8);

   return $result == 0;
};

#...............................................................................
#
# SupportsProgram
#
#   Determines whether the program exists and supports a given list of comman-line options.
#
# Params:
#   $program    - program to check
#   $optionsref - reference to the list of options to check
#
# Result:
#   1 if program is supported, otherwise - 0.
#
#...............................................................................

sub SupportsProgram
{
   my ($program, $optionsref) = @_;
   my @options = @$optionsref;

   if (-e $program) {
      foreach my $option (@options) {
         my $result = SupportsOption($program, $option);
         if ($result == 0) {
            return 0;
         };
      };
      return 1;
   } else {
      return 0;
   };
};

#...............................................................................
#
# DirName
#
#   Determines name of the directory. Impelemntation is based on File::Spec->splitpath.
#
# Params:
#   $path    - full path
#
# Result:
#   name of the directory
#
#...............................................................................

sub DirName
{
   my ($path) = @_;

   my ($volume,$directory,$file) = File::Spec->splitpath($path);

   return $directory;
};

#...............................................................................
#
# FileName
#
#   Determines name of the file. Impelemntation is based on File::Spec->splitpath.
#
# Params:
#   $path    - full path
#
# Result:
#   name of the file
#
#...............................................................................

sub FileName
{
   my ($path) = @_;

   my ($volume,$directory,$file) = File::Spec->splitpath($path);

   return $file;
};

#...............................................................................
#
# GetToolsDaemonPath
#
#   Determines path to the Tools daemon.
#
# Params:
#   None.
#
# Result:
#   Path to the Tools daemon.
#
# Throws:
#   If Tools daemon doesn't exists.
#...............................................................................

sub GetToolsDaemonPath
{
   my $returnCode;
   my $outText = ExecuteCommand('ps -C vmtoolsd -o cmd=',
                                'Get Tools Daemon Command Line',
                                \$returnCode);
   if ($returnCode || $outText eq "") {
      die 'Tools Deamon is not running';
   }

   if ($outText =~ m'^(\S+)') {
      return $1;
   } else {
      die "ASSERT: unexpected 'ps -C vmtoolsd -o cmd=' output: $outText";
   }
}

#...............................................................................
#
# PostGcStatus
#
#   Sets message to the VMX guestinfo.gc.status property.
#
# Params:
#   $msg - message to be set.
#
# Result:
#   None
#
# Throws:
#   If Tools daemon doesn't exists.
#...............................................................................

sub PostGcStatus
{
   my ($msg) = @_;

   my $CMD_VMWARE_GUESTD = GetToolsDaemonPath();
   ExecuteCommand("$CMD_VMWARE_GUESTD --cmd \"info-set guestinfo.gc.status $msg\"");
}

#...............................................................................
#
# GetIpPath
#
#   Gets the location of ip binary from output of whereis
#
# Params:
#   None.
#
# Returns:
#   The location of ip binary.
#...............................................................................

sub GetIpPath
{
   my $result = undef;
   my $ipcmd = Utils::ExecuteCommand('whereis ip');
   if ($ipcmd =~ /^ip:\s+((\/[^\/ ]+)+)\s.*/) {
      $result = $1;
   }
   return $result;
}

#...............................................................................
#
# GetHwclockPath
#
#   Gets the location of hwclock binary from output of whereis.
#
# Returns:
#   The location of hwclock binary.
#
#...............................................................................

sub GetHwclockPath
{
   my $result = undef;
   my $hwclockcmd = Utils::ExecuteCommand('whereis hwclock');
   if ($hwclockcmd =~ /^hwclock:\s+((\/[^\/ ]+)+)\s.*/) {
      $result = $1;
   }
   if (!defined($result) ) {
      die "Path to hwclock not found. $hwclockcmd";
   }
   return $result;
}

#...............................................................................
#
# GetTimedatectlPath
#
#   Gets the location of timedatectl binary from output of whereis.
#
# Returns:
#   The location of timedatectl binary.
#
#...............................................................................

sub GetTimedatectlPath
{
   my $result = undef;
   my $timedatectlcmd = Utils::ExecuteCommand('whereis timedatectl');
   if ($timedatectlcmd =~ /^timedatectl:\s+((\/[^\/ ]+)+)\s.*/) {
      $result = $1;
   }
   if (!defined($result) ) {
      die "Path to timedatectl not found. $timedatectlcmd";
   }
   return $result;
}

#...............................................................................
#
# ReadRpcProperty
#
#     Reads GuestInfo property.
#
# Params:
#     $name  full name of the property including 'guestinfo.'
#
# Result:
#     Value of the property.
#
#...............................................................................

sub ReadRpcProperty
{
   my ($name) = @_;
   #TODO figure out if GuestInfo can be empty and retrieved this way

   return Trim(
      ExecuteCommand("vmware-rpctool \"info-get $name\" 2>>$RPC_LOG_FILE"));
}

#...............................................................................
#
# WriteRpcProperty
#
#     Writes GuestInfo property.
#
# Params:
#     $name  full name of the property including 'guestinfo.'
#     $value  the value
#
#...............................................................................

sub WriteRpcProperty
{
   my ($name, $value) = @_;
   #TODO is there any way to set empty GuestInfo?

   ExecuteCommand("vmware-rpctool \"info-set $name $value\" 2>>$RPC_LOG_FILE");
}

#...............................................................................
#
# GetNamespaceEventCommand
#
#   Determines the command to send a namespace event
#
# Params:
#   $event - event string.
#
# Result:
#   Command to send the namespace event needed.
#
# Throws:
#   If there is an unrecoverable error.
#...............................................................................

sub GetNamespaceEventCommand
{
   my ($event) = @_;

   my $ns = $InstantCloneConstants::NS_DB_NAME;
   my $notifier = GetLinuxCustNotifierCmd();

   return "$notifier namespace-priv-send-event $ns^0^$event^0^";
}

#...............................................................................
#
# GetNamespaceKeyValueSetCommand
#
#   Determines the command to set a key/value pair in a namespace DB.
#
# Params:
#   $key - a key
#   $value - a value
#
# Result:
#   Command to set a key/value pair in a namespace DB.
#
# Throws:
#   If there is an unrecoverable error.
#...............................................................................

sub GetNamespaceKeyValueSetCommand
{
   my ($key, $value) = @_;
   my $ns = $InstantCloneConstants::NS_DB_NAME;

   if ($USE_NAMESPACE_CMD) {
      return "vmware-namespace-cmd set-key $ns -V -k $key -v '$value'";
   }

   my $notifier = GetLinuxCustNotifierCmd();

   # RPC format: see vmx/main/namespaceMgr.c
   # <namespace>NUL<nOps(1)>NUL<SET_ALWAYS(0)>NUL<KEY>NUL<VALUE>NUL<ANY>NUL
   # In addition, spaces leading the number are legal and more readable.

   return "$notifier namespace-priv-set-keys $ns^0^ 1^0^ 0^0^$key^0^$value^0^^0^";
}

#...............................................................................
#
# GetNamespaceValueCommand
#
#   Determines the command to get a value out of namespace DB.
#
# Params:
#   $key - a key to lookup for the value
#
# Result:
#   Command to get a value out of namespace DB.
#
# Throws:
#   If there is an unrecoverable error.
#...............................................................................

sub GetNamespaceValueCommand
{
   my ($key, $value) = @_;
   my $ns = $InstantCloneConstants::NS_DB_NAME;

   if ($USE_NAMESPACE_CMD) {
      return "vmware-namespace-cmd get-value $ns -k $key";
   }

   my $notifier = GetLinuxCustNotifierCmd();

   # RPC format: see vmx/main/namespaceMgr.c
   # <namespace>NUL<KEY>NUL

   return "$notifier namespace-priv-get-values $ns^0^$key^0^";
}

#...............................................................................
#
# ReadNsProperty
#
#     Reads Namespaces property.
#
# Params:
#     $ns  full name of the Namespace
#     $key  full key of the property
#
# Result:
#     Value of the property.
#
#...............................................................................

sub ReadNsProperty
{
   my ($key) = @_;
   my $returnCode;

   my $value = ExecuteCommandLogStderr(GetNamespaceValueCommand($key),
                                       "Query Namespace DB[$key]",
                                       \$returnCode);
   if ($returnCode) {
      die "Namespace DB query failure $key";
   }

   # Currently triming due to PR 1560817. It's a good practice anyway.
   return Trim($value);
}

#...............................................................................
#
# NotifyInstantCloneState
#
#   Update VMX with the instant clone guest customization state
#
# Params:
#   $state - state to be set.
#   $code (optional) - code to be set.
#   $msg (optional) - message to be set.
#
# Result:
#   None
#
# Throws:
#   If Tools daemon doesn't exists.
#...............................................................................

sub NotifyInstantCloneState
{
   my ($id, $state, $code, $msg) = @_;
   chomp $msg;

   # Key is prefixed with the instant clone customization ID and a dot.
   my $key = $id . '.' . $InstantCloneConstants::NS_DB_KEY_STATE;

   my $value;
   if ($state eq $InstantCloneConstants::STATE_ERR) {
      $value = "$state,$code,$msg";
   } else {
      $value = $state;
   }

   # We intentionally leave out the checking of the return code.
   # The caller shall exit with a proper exit code.
   # Check InstantClone::Invoke for details.
   # The Debug log would reveal the error if the namespace command
   # failed.
   # This also allows us to test the code if the namespace DB is not set up.
   ExecuteCommandLogStderr(GetNamespaceKeyValueSetCommand($key, $value));

   # Send a namespace event too so that vSphere doesn't have to poll for
   # the update.
   my $event = 'update.' . $key;
   ExecuteCommandLogStderr(GetNamespaceEventCommand($event));
}

sub MatchGuestOS
{
   my @customizations = @_;

   my $instance = undef;

   # Find customization that supports the distro
   foreach (@customizations) {
      my $distro = $_->DetectDistro();

      if (defined $distro) {
         INFO("Detected distribution: $distro");
         $instance = $_;

         # Flavour is not mandatory for customizing a distro
         my $flavour = $_->DetectDistroFlavour();

         if (defined $flavour) {
            INFO("Detected distribution flavour: $flavour");
         } else {
            WARN("Unknown $distro distribution flavour.");
         }

         last;
      }
   }

   if (defined $instance) {
      my $instanceName = blessed($instance);
      INFO("Customization instance $instanceName loaded.");
   }

   return $instance;
}

#...............................................................................
# Return value for module as required for perl
#...............................................................................

1;
