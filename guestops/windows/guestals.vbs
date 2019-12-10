'**********************************************************
'* Copyright 2015-2016 VMware, Inc.  All rights reserved. -- VMware Confidential
'**********************************************************
'
' SRM Guest Alias Deployment Script (for Windows GOS).
' The script maps the subject (SRM SU) to VM Tools or built-in local administrator account.
'
Option Explicit

' Non-system error codes
Dim debug : debug = false
Const ERROR_BAD_PARAMS = -10000
Const ERROR_NO_PEMS = -10001
Const ERROR_NOT_SUPPORTED = -10002
Const ERROR_BAD_ENV = -10003
Const ERROR_BAD_USER = -10004

' Guest alias user option.
' Setting it to True maps the VMTools service account (typically, SYSTEM) to the SRM SU principal
' when the script is executed from the deployPkg context. This is the default (recommended) mode.
' Setting it to False maps the built-in local administrator to the SRM SU principal.
Const USE_CURRENT_USER = True

' Log file
Dim LOG_FILE_NAME : LOG_FILE_NAME = "srmDeployGuestAlias.log"
' Guest config save file; created on "add"; used/deleted on "cleanup"
Dim GUESTCONFIG_FILE_NAME : GUESTCONFIG_FILE_NAME = "srmGuestConfig.ini"

' main
Dim LOGFILE : LOGFILE = StartLog()
Dim GUESTCONFIG_FILE

' Set VMware Tools Environment
Dim VMWARE_TOOLSD_FOLDER : VMWARE_TOOLSD_FOLDER = GetToolsDaemonFolder()
Dim VMWARE_TOOLSD_CMD : VMWARE_TOOLSD_CMD = VMWARE_TOOLSD_FOLDER & "vmtoolsd.exe"
Dim VMTOOLBOX_CMD : VMTOOLBOX_CMD = VMWARE_TOOLSD_FOLDER & "VMwareToolboxCmd.exe"
Dim VGAUTH_CMD : VGAUTH_CMD = VMWARE_TOOLSD_FOLDER & "VMware VGAuth\VGAuthCLI.exe"

Dim PathsToCheck : PathsToCheck = Array(VMWARE_TOOLSD_CMD, VMTOOLBOX_CMD, VGAUTH_CMD)
CheckFilePath(PathsToCheck)

Dim VMTOOLS_VERSION : VMTOOLS_VERSION = Trim(SysCommandOutput(InQuotes(VMTOOLBOX_CMD) & " -v"))

' Current account (typically, vmtools service)
Dim CURRENT_ACCOUNT : CURRENT_ACCOUNT = CreateObject("WScript.Network").UserName

Log("Running as " & CURRENT_ACCOUNT & _
    ", vmtools at " & VMWARE_TOOLSD_CMD & ", " & VMTOOLS_VERSION)

' Parse args
Dim objArgs : Set objArgs = Wscript.Arguments
If not objArgs.Count = 2 Then
   UsageExit()
End If

' Account we map the alias to
Dim GUEST_ALIAS_ACCOUNT
If USE_CURRENT_USER Then
   GUEST_ALIAS_ACCOUNT = CURRENT_ACCOUNT
Else
   GUEST_ALIAS_ACCOUNT = GetLocalAdminName()
End If

If GUEST_ALIAS_ACCOUNT = "" Then
   Log("Failed to find an appropriate local account for guest alias")
   NotifyAndExit(ERROR_BAD_USER)
End If

Log("Using local account for alias: " & GUEST_ALIAS_ACCOUNT)

Dim GUEST_ALIAS_ACTION : GUEST_ALIAS_ACTION = objArgs(0)
Dim GUEST_ALIAS_SUBJECT : GUEST_ALIAS_SUBJECT = objArgs(1)
Dim VGAUTH_ADD_ALIAS_CMD : VGAUTH_ADD_ALIAS_CMD = InQuotes(VGAUTH_CMD) & " add --global" & _
                                                " --username " & InQuotes(GUEST_ALIAS_ACCOUNT) & _
                                                " --subject "  & GUEST_ALIAS_SUBJECT & _
                                                " --comment "  & "SRM" & " --file "
Dim VGAUTH_REMOVE_ALIAS_CMD : VGAUTH_REMOVE_ALIAS_CMD = InQuotes(VGAUTH_CMD) & " remove" & _
                                                " --username " & InQuotes(GUEST_ALIAS_ACCOUNT) & _
                                                " --subject "  & GUEST_ALIAS_SUBJECT & _
                                                " --file "
Dim VGAUTH_LIST_ALIAS_CMD : VGAUTH_LIST_ALIAS_CMD =  InQuotes(VGAUTH_CMD) & " list"

' Walk and (re)register all *.pem files found in the current directory
' @note VGauth needs an easier way of removing stale aliases. Currently, removing
' aliases requires one to provide the original .pem file.
Dim pems : pems = GetPemFiles()
Dim result

' Dump current alias list for diags
Log("Current Alias List:" & vbCRLF & SysCommandOutput(VGAUTH_LIST_ALIAS_CMD))

If (GUEST_ALIAS_ACTION = "add") Then
   result = SetupGuest(pems)
ElseIf (GUEST_ALIAS_ACTION = "cleanup") Then
   result = CleanupGuest(pems)
Else
   UsageExit()
End If

' Dump new alias list for diags
Log("New Alias List:" & vbCRLF & SysCommandOutput(VGAUTH_LIST_ALIAS_CMD))

NotifyAndExit(result)

'.............................................................
' Helper Functions
'.............................................................

' Setup aliases and required config items to enable SRM guest operations
Function SetupGuest(pems)
   Log("SetupGuest")

   SaveGuestConfig()

   RemoveAliases(pems)
   result = AddAliases(pems)

   ' Adjust any other guest settings as needed
   If (result = 0) Then
      Log("Enable host timesync")
      SysCommand(InQuotes(VMTOOLBOX_CMD) & " timesync enable")
   End If

   ' Enable VGauth impersonation bypass for the current user
   ' @note This enables the VGauth bypass for VM Tools service account, typically, SYSTEM.
   If (result = 0) and USE_CURRENT_USER Then
      Log("Enable VGauth VMTools service account impersonation bypass")
      SetToolsConfigItem "guestoperations", "allowLocalSystemImpersonationBypass", "true"
   End If
   SetupGuest = result
End Function

' Restore the guest to the original config
Function CleanupGuest(pems)
   Log("CleanupGuest")

   'Remove aliases; pems can be empty here
   RemoveAliases(pems)

   'Get saved guest config
   Dim savedGuestConfig : Set savedGuestConfig = CreateObject("Scripting.Dictionary")
   GetGuestConfig(savedGuestConfig)

   ' Restore host time sync state
   Dim hostTimeSync : hostTimeSync = ""
   If savedGuestConfig.Exists("HostTimeSync") Then
      hostTimeSync = savedGuestConfig.Item("HostTimeSync")
      Log("HostTimeSync was '" & hostTimeSync & "'")
      If (hostTimeSync = "Enabled") Then
         SysCommand(InQuotes(VMTOOLBOX_CMD) & " timesync enable")
      ElseIf (hostTimeSync = "Disabled") Then
         SysCommand(InQuotes(VMTOOLBOX_CMD) & " timesync disable")
      Else
         Log("WARNING: Unexpected HostTimeSync value: " & hostTimeSync)
      End If
   Else
      Log("WARNING: Saved HostTimeSync not found")
   End If

   ' Remove impersonation bypass entry always
   RemoveToolsConfigItem "guestoperations", "allowLocalSystemImpersonationBypass"

   ' Always the best effort
   CleanupGuest = 0
End Function

Function GetToolsDaemonFolder
   ' Default location (best effort)
   GetToolsDaemonFolder = "C:\Program Files\VMware\VMware Tools\"

   ' Get the Registry provider
   Dim vmtoolsdPath
   Const HKEY_LOCAL_MACHINE = &H80000002
   Dim objReg : Set objReg=GetObject("winmgmts:\\.\root\default:StdRegProv")
   Dim regVmtoolsKey : regVmtoolsKey = "SOFTWARE\VMware, Inc.\VMware Tools"
   On Error Resume Next
   Dim result : result = objReg.GetStringValue(HKEY_LOCAL_MACHINE, _
                         regVmtoolsKey, "InstallPath", vmtoolsdPath)
   If (result = 0) And (Err.Number = 0) Then
      Log("Found vmtools install path: " & vmtoolsdPath)
      GetToolsDaemonFolder = vmtoolsdPath
   Else
      Log("Warning: no vmtools installation found at HKLM\" & regVmtoolsKey)
   End If
End Function

Function InQuotes(term)
   InQuotes = chr(34) & term & chr(34)
End Function

Function StartLog
  ' Use the same folder that's used by IMC.
  Dim objFS, objFile
  Dim logdir : logdir = _
      CreateObject("WScript.shell").ExpandEnvironmentStrings("%SystemRoot%") & "\Temp\vmware-imc"
  Set objFS = CreateObject("Scripting.FileSystemObject")
  If not objFS.FolderExists(logdir) Then
    On Error Resume Next
    objFS.CreateFolder(logdir)
  End If
  Dim logfile : logfile = logdir & "\" & LOG_FILE_NAME
  On Error Resume Next
  Set objFile = objFS.CreateTextFile(logfile, True)
  If Err.Number <> 0 Then
      Err.Clear
      StartLog = "" 'Run w/o logs
      Exit Function
  End If
  objFile.WriteLine Now & " Starting"
  objFile.Close
  StartLog = logfile
End Function

Function Log(line)
  Dim objFile
  If debug Then
      Wscript.Echo "LOG: " & line
  End If
  If LOGFILE <> "" Then
     Set objFile = CreateObject("Scripting.FileSystemObject").OpenTextFile(LOGFILE, 8)
     objFile.WriteLine Now & " " & line
     objFile.Close
  End If
End Function

' Exec cmd and return an exit code
' @todo Merge stdout and stderr into LOGFILE
Function SysCommand(cmd)
   Const InheritWindowState = 10
   Dim result : result = ERROR_BAD_ENV
   Log("Running: " & cmd)
   On Error Resume Next
   result = WScript.CreateObject("WScript.Shell").Run (cmd, InheritWindowState, true)
   If Err.Number <> 0 Then
      Log("Command invocation failed with error " & Err.Number & ": " & Err.Description)
      Err.Clear
   End If
   Log("Returned: " & result)
   SysCommand = result
End Function

' Exec cmd and return stdout
Function SysCommandOutput(cmd)
   Dim result : result = ""
   Log("Getting output from: " & cmd)
   On Error Resume Next
   result = WScript.CreateObject("WScript.Shell").Exec(cmd).StdOut.ReadAll()
   SysCommandOutput = result
End Function


' Return a vector of .pem files under the script's directory
Function GetPemFiles
   Dim file, pems()
   Dim i : i = 0
   Dim objFS : Set objFS = CreateObject("Scripting.FileSystemObject")
   For Each file In objFS.GetFolder(".").Files
      If objFS.GetExtensionName(file.Name) = "pem" Then
         ReDim Preserve pems(i)
         pems(i) = file.Path
         i = i + 1
      End If
   Next
   Log("Found " & i & " .pem file(s)")
   GetPemFiles = pems
End Function

' Remove all aliases matching the supplied .PEM files
' @return 0 for success, or first error code encountered.
' @note The function always attempts to remove all matching aliases.
Function RemoveAliases(pems)
   Dim pem
   Dim errors : errors = False
   Dim result : result = ERROR_NO_PEMS
   For Each pem In pems
      Dim err : err = SysCommand(VGAUTH_REMOVE_ALIAS_CMD & InQuotes(pem))
      If err = 0 Then
         If not errors Then
            result = 0
         End If
      Else
         If not errors Then
            result = err
            errors = True
         End If
      End If
   Next
   RemoveAliases = result
End Function

' Add aliases.
' Note all the aliases we add are global (corresponding to the mapCert
' GuestOps API parameter). This would allow the client skip specifying the
' username in the API calls.
' @return The result code, 0 for success.
Function AddAliases(pems)
   Dim pem
   Dim result : result = ERROR_NO_PEMS
   For Each pem In pems
      result = SysCommand(VGAUTH_ADD_ALIAS_CMD & InQuotes(pem))
      If not result = 0 Then
         Exit For
      End If
   Next
   AddAliases = result
End Function

' Check the specified paths. Exit if doesn't exist
Function CheckFilePath(paths)
   Dim objFS, path
   Set objFS = CreateObject("Scripting.FileSystemObject")
   For Each path In paths
      If not objFS.FileExists(path) Then
         Log("Can't find " + path)
         NotifyAndExit(ERROR_BAD_ENV)
      End If
   Next
End Function

'Get Local Admin Account's name
'NOTE: WMI "Select * From Win32_UserAccount" query doesn't work on localized
'       Windows 7 for some reason(?). Use ADSI binary SID query instead.
Function GetLocalAdminName
   Dim sidRe : Set sidRe = new RegExp
   sidRe.Pattern = "^S\-1\-5\-.+\-500$" ' the well-known local admin SID pattern

   Dim adsi : Set adsi = GetObject("WinNT://.")
   adsi.Filter = Array("user")

   Dim u, sid
   For Each u in adsi
      sid = DecodeSID(u.objectSID)
      If sidRe.Test(sid) Then
         GetLocalAdminName = u.name
         Exit Function
      End If
   Next

   GetLocalAdminName = ""
End Function

' Convert binary SID to a SID string
' See http://stackoverflow.com/questions/21081984/how-do-i-get-sid-for-the-group-using-vbscript
Function DecodeSID(binSID)
  Dim i, sid

  ReDim bytes(LenB(binSID))
  For i = 0 To UBound(binSID)
    bytes(i) = AscB(MidB(binSID, i+1, 1))
  Next

  sid = "S-" & CStr(bytes(0)) & "-" & _
        Arr2Str(Array(bytes(2), bytes(3), bytes(4), bytes(5), bytes(6), bytes(7)))
  For i = 8 To (4 * bytes(1) + 4) Step 4
    sid = sid & "-" & Arr2Str(Array(bytes(i+3), bytes(i+2), bytes(i+1), bytes(i)))
  Next

  DecodeSID = sid
End Function

' Convert binary array to string
Function Arr2Str(arr)
  Dim i, v
  v = 0
  For i = 0 To UBound(arr)
    v = v * 256 + arr(i)
  Next
  Arr2Str = CStr(v)
End Function

' Save config item into tools.conf
Function SetToolsConfigItem(section, key, value)
  Dim cmd : cmd = " config set " & section & " " & key & " " & value
  Log("Setting tools.conf item: " & cmd)
  SysCommand(InQuotes(VMTOOLBOX_CMD) & cmd)
End Function

' Remove config item from tools.conf
Function RemoveToolsConfigItem(section, key)
  Dim cmd : cmd = " config remove " & section & " " & key
  Log("Removing tools.conf item: " & cmd)
  SysCommand(InQuotes(VMTOOLBOX_CMD) & cmd)
End Function

' Save guest config into an .ini-style file
Function SaveGuestConfig
   'Using the log folder. If failed to create the log file, don't bother any further
   If LOGFILE = "" Then
      Exit Function
   End If

   Dim objFS : Set objFS = CreateObject("Scripting.FileSystemObject")
   Dim filePath : filePath = objFS.GetParentFolderName(LOGFILE) & "\" & GUESTCONFIG_FILE_NAME

   Log("Saving guest config into " & filePath)

   On Error Resume Next
   Dim objFile : Set objFile = objFS.CreateTextFile(filePath, True)
   If Err.Number <> 0 Then
      Log("WARNING: Can't persist current guest config at " & filePath)
      Err.Clear
      Exit Function
   End If

   ' Persist current host time sync state
   Dim hostTimeSync : hostTimeSync = Trim(_
      SysCommandOutput(InQuotes(VMTOOLBOX_CMD) & " timesync status"))
   hostTimeSync = Replace(hostTimeSync, vbCrLf, "")
   Log("HostTimeSync is currently " & hostTimeSync)
   objFile.WriteLine("HostTimeSync=" & hostTimeSync)

   ' Persist other items if needed
   '
   objFile.Close
End Function

' Get previously saved guest config as a dictionary
' The config file is read just once before it gets deleted.
Function GetGuestConfig(ByRef config)
   'Using the log folder. If failed to create the log file, don't bother any further
   If LOGFILE = "" Then
      Exit Function
   End If

   Const ForReading = 1

   Dim objFS : Set objFS = CreateObject("Scripting.FileSystemObject")
   Dim filePath : filePath = objFS.GetParentFolderName(LOGFILE) & "\" & GUESTCONFIG_FILE_NAME
   On Error Resume Next
   Dim objFile : Set objFile = objFS.OpenTextFile(filePath, ForReading)
   If Err.Number <> 0 Then
      Log("WARNING: Can't open saved guest config at " & filePath)
      Err.Clear
      Exit Function
   End If

   Log("Restoring guest configuration from " & filePath)

   Dim lines : lines = Split(objFile.ReadAll, vbCrLf)
   Dim line, pair

   For Each line In lines
      pair = Split(line, "=")
      If line <> "" Then
         If Ubound(pair) = 1 Then
            config.Add Trim(pair(0)), Trim(pair(1))
         Else
            Log("WARNING: Unexpected saved guest config found: '" & line & "' ;ignoring")
         End If
      End If
   Next

   ' Delete the config file to avoid a replay
   objFile.Close
   objFS.DeleteFile(filePath)
End Function

' Notify the client (best effort) and exit
Function NotifyAndExit(result)
   ' Setting special config.extraConfig.* VMX property for the client.
   Dim cmd : cmd = InQuotes(VMWARE_TOOLSD_CMD) & " --cmd " & _
                   InQuotes("info-set guestinfo.srm.deployPkg.result " & result)

   SysCommand(cmd)

   ' @note
   ' The result of deployPkg shows up in the vSphere VM event UI tab
   ' as "Customization Event". Returning an error shows up as "Customization Error"
   ' with explanations irrelevant to the current script, obviously.
   ' @todo Check if the UI event can be customized (e.g. a special error code?)
   If result = 0 Then
      Log("Completed successfully")
   Else
      Log("Completed with error; reporting exit code: " & result)
   End If
   WScript.Quit result
End Function

Function UsageExit
   Log("Wrong parameter(s). Usage: " & WScript.ScriptName & " [add|cleanup] [subject_name]")
   NotifyAndExit (ERROR_BAD_PARAMS)
End Function
