#!/usr/bin/perl

################################################################################
#  Copyright 2008-2017 VMware, Inc.  All rights reserved.
################################################################################

#...............................................................................
#
# Debug.pm
#
#     Provides functions for logical grouping and filtering of messages for
#     debugging and logging.
#
#...............................................................................

package Debug;

use strict;
use FileHandle;
use File::Basename qw(dirname);
# Do not use make_path yet, as we need to support old distro like SLES11
use File::Path qw(mkpath);
use POSIX qw(strftime);

# Default export symbols.
use Exporter ();
our @ISA = qw(Exporter);
our @EXPORT = qw(SetupLogging WARN INFO DEBUG ERROR);

# Debug level
our $DEBUGLEVEL = 4;

our $logFileHandle = undef;

#...............................................................................
#
# SetupLogging
#
#     Initialize the logging handle if the caller opts to log to a file.
#     Debug/Warn/Info/Error output shall go to both the log file and
#     the stdout.
#
# Params:
#     $logFilePath     The log file path
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub SetupLogging
{
   my ($logFilePath) = @_;
   if (defined $logFileHandle) {
      undef $logFileHandle; # auto closes the previously opened file.
   }

   my $logDir = dirname($logFilePath);
   if (not -e $logDir) {
      DEBUG("Creating directory $logDir");
      mkpath($logDir);
   }

   $logFileHandle = FileHandle->new($logFilePath,
                                    O_CREAT | O_WRONLY | O_APPEND);
   if (not $logFileHandle) {
      die "Unable to open $logFilePath for logging, $!";
   }
}

#...............................................................................
#
# GetTime
#
#     Return the time format string used for logging.
#
# Params:
#     None
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub GetTime
{
   return strftime('%Y/%m/%d UTC %H:%M:%S ', gmtime(time));
}

#...............................................................................
#
# LogMsg
#
#     Log a message using the current log file handle.
#
# Params:
#     None
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub LogMsg
{
   my ($msg) = @_;

   if ($logFileHandle) {
      $logFileHandle->print(GetTime() . $msg);
   }
}

#...............................................................................
#
# WARN
#
#     Classifies the message as a warning. It is printed only if the $DEBUGLEVEL
#     is set above 1
#
# Params:
#     $line     Line to be printed
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub WARN
{
   # map the params
   my ( $line ) = @_;

   if ($DEBUGLEVEL > 1) {
      my $msg = "WARNING: $line \n";
      LogMsg($msg);
      print $msg;
   }
};

#...............................................................................
#
# INFO
#
#     Classifies the message as informational. It is printed only if the $DEBUGLEVEL
#     is set above 2
#
# Params:
#     $line     Line to be printed
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub INFO
{
   # map the params
   my ($line) = @_;

   if ($DEBUGLEVEL > 2) {
      my $msg = "INFO: $line \n";
      LogMsg($msg);
      print $msg;
   }
};

#...............................................................................
#
# ERROR
#
#     Classifies the message as error message. It is printed for all debug
#     levels.
#
# Params:
#     $line   Line to be printed
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub ERROR
{
   # map the params
   my ($line) = @_;

   my $msg = "ERROR: $line \n";
   LogMsg($msg);
   print $msg;
};

#...............................................................................
#
# DEBUG
#
#     Classifies the message as DEBUG. It is printed only if the $DEBUGLEVLE is
#     above 3.
#
# Params:
#     $line     Line to be printed
#
# Result:
#     None
#
# NOTE:
#
#...............................................................................

sub DEBUG
{
   # map the params
   my ($line) = @_;

   if ($DEBUGLEVEL > 3) {
      my $msg = "DEBUG: $line \n";
      LogMsg($msg);
      print $msg;
   }
};

#...............................................................................
# Return value for module as required by Perl
#...............................................................................

1;
