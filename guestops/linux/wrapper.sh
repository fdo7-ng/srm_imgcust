#!/bin/sh
########################################################################################
#  Copyright 2016 VMware, Inc.  All rights reserved.
########################################################################################
#
# SRM Guest Command Wrapper Script (for Linux GOS).
#
# This wrapper script is uploaded into the guest using GuestOps FileManager API,
# and executed using GuestOps ProcessManager API.
#
# The runtime environment for the script must include SRM-specific public environment
# variables as per
#
# http://pubs.vmware.com/srm-65/topic/com.vmware.srm.admin.doc/GUID-2D288B46-27D1-41E9-81EE-618F1A6D5F98.html
#
# The following internal environment variables are expected:
#  VMware_GuestOp_OutputFile     - A file where the combined stdout/stderr output of the user's script
#                                     must be redirected. This file is downloaded by SRM server at the end of
#                                     the operation, and its content is presented at the SRM callout VMODL output.
#  VMware_GuestOp_OutputFolder   - A temporary folder created by SRM server for file uploads.
#  VMware_GuestOp_File_N         - If present (N >= 0) then it specifies one of (N+1) additional files uploaded by SRM
#                                     server prior to invoking the operation.
#
# Environment and user-defined callout goes in here
