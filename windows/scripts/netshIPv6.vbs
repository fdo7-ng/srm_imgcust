'/* **********************************************************
' * Copyright 2009-2013 VMware, Inc.  All rights reserved. -- VMware Confidential
' * **********************************************************/

'/**
' * @file
' *
' *    VBscript wrapper around netsh.exe on Windows XP and above. See Usage() function for
' * command-line arguments. Given a MAC address, the script can customize IPv6 addresses
' * along with their subnet prefix and gateways. To customize multiple IPs for the same adapter,
' * simply run the script again and again with the same MAC address but with a different
' * IP address or Gateway.
' */

Option Explicit

'MAC address of adapter to be customized
Dim macAddress
'IPv6 reset level
Dim resetLevel
'IPv6 address of adapter
Dim ipAddress
'Subnet mask (number of bits to mask)
Dim subnetPrefixLength
'Subnet address (network destination address)
Dim subnetAddress
'IPv6 gateway
Dim gateway
'IPv6 gateway metric
Dim gatewayMetric
'IPv6 DNS server
Dim dnsServer6
'IPv4 DNS server
Dim dnsServer4
'IPv4 WINS server
Dim winsServer
'Requested IPv4 DNS suffix
Dim dnsDomainIPv4

'Reset IPv6 settings if TRUE
Dim boolResetIPv6
'Customize IPv6 address if TRUE
Dim boolCustomizeIPv6
'Customize IPv6 Gateway information if TRUE
Dim boolCustomizeIPv6Gateway
'Customize IPv6 DNS server information if TRUE
Dim boolCustomizeIPv6DNS
'Customize IPv4 DNS server information if TRUE
Dim boolCustomizeIPv4DNS
'Customize IPv4 WINS server information if TRUE
Dim boolCustomizeIPv4WINS
'Customize connection-specific DNS suffix
Dim boolCustomizeIPv4DNSDomain

'enumIPV6 file path
Dim enumCmd

Dim args, namedArgs
Dim DONT_IGNORE_ERROR, IGNORE_ERROR
Dim RESETLEVEL_ALLNICS, RESETLEVEL_SINGLENIC

RESETLEVEL_ALLNICS = "ALLNICS"  'Windows XP/2003 only
RESETLEVEL_SINGLENIC = "SINGLENIC" 'Longhorn only

DONT_IGNORE_ERROR = 0 'Return netsh exit code
IGNORE_ERROR = 1 'Ignore netsh error

'Registry key for IP interface configuration (disconnected NIC mode only)
Dim regIPInterfaceConfigKey
regIPInterfaceConfigKey = "HKLM\SYSTEM\CurrentControlSet\services\Tcpip\Parameters\Interfaces\"

Set args = WScript.Arguments
Set namedArgs = args.Named


'Check arguments
If args.Count >= 1 Then
   If namedArgs.Exists("MacAddress") Then
      macAddress = namedArgs.Item("MacAddress")
   Else
      Usage("Error: Missing MAC address")
   End If

   'Check IPv6 reset parameters
   If namedArgs.Exists("Reset") Then
      resetLevel = namedArgs.Item("Reset")
   End If

   boolResetIPv6 = FALSE

   If Not resetLevel = "" Then
      boolResetIPv6 = TRUE

      If resetLevel <> RESETLEVEL_ALLNICS Then
         If resetLevel <> RESETLEVEL_SINGLENIC Then
            Usage("Error: Invalid Reset level")
         End If
      End If
   End If

   'Get IPv6 Enumeration script file path
   If namedArgs.Exists("EnumPath") Then
      enumCmd = namedArgs.Item("EnumPath")
   End If

   If Not enumCmd = "" Then
      'Add quotes here even if input contains quotes (Arguments code removes the quote)
      enumCmd = Chr(34) & enumCmd & Chr(34)
   Else
      If resetLevel = RESETLEVEL_SINGLENIC Then
         Usage("Error: Missing path to IPv6 Enumeration script")
      End If
   End If

   'Check IPv6 address parameters
   If namedArgs.Exists("IPAddress") Then
      ipAddress = namedArgs.Item("IPAddress")
   End If

   If namedArgs.Exists("SubnetPrefixLength") Then
      subnetPrefixLength = namedArgs.Item("SubnetPrefixLength")
   End If

   If namedArgs.Exists("SubnetAddress") Then
      subnetAddress = namedArgs.Item("SubnetAddress")
   End If

   boolCustomizeIPv6 = FALSE

   If ipAddress = "" Then
      If Not subnetPrefixLength = "" Then
         Usage("Error: IP address missing")
      End If
   Else

      'Verify that subnetPrefixLength is provided when subnetAddress is present
      If Not subnetAddress = "" Then
         If subnetPrefixLength = "" Then
            Usage("Error: Subnet prefix length missing")
         End If
      End If

      boolCustomizeIPv6 = TRUE
   End If


   'Check IPv6 Gateway parameters
   If namedArgs.Exists("Gateway") Then
      gateway = namedArgs.Item("Gateway")
   End If

   If namedArgs.Exists("GatewayMetric") Then
      gatewayMetric = namedArgs.Item("GatewayMetric")
   End If

   boolCustomizeIPv6Gateway = FALSE

   If gateway = "" Then
      If Not gatewayMetric = "" Then
         Usage("Error: Gateway missing")
      End If
   Else
      boolCustomizeIPv6Gateway = TRUE
   End If


   'Check IPv6 DNS server parameters
   If namedArgs.Exists("DNSserver") Then
      dnsServer6 = namedArgs.Item("DNSserver")
   End If

   boolCustomizeIPv6DNS = FALSE

   If Not dnsServer6 = "" Then
      boolCustomizeIPv6DNS = TRUE
   End If

   'Check IPv4 DNS server parameters
   If namedArgs.Exists("DNSserver4") Then
      dnsServer4 = namedArgs.Item("DNSserver4")
   End If

   boolCustomizeIPv4DNS = FALSE

   If Not dnsServer4 = "" Then
      boolCustomizeIPv4DNS = TRUE
   End If

   'Check IPv4 WINS server parameters
   If namedArgs.Exists("WINSserver") Then
      winsServer = namedArgs.Item("WINSserver")
   End If

   boolCustomizeIPv4WINS = FALSE

   If Not winsServer = "" Then
      boolCustomizeIPv4WINS = TRUE
   End If

   'Check connection-specific DNS suffix
   If namedArgs.Exists("ForceDNSDomain4") Then
      dnsDomainIPv4 = namedArgs.Item("ForceDNSDomain4")
   End If

   boolCustomizeIPv4DNSDomain = FALSE

   if Not dnsDomainIPv4 = "" Then
       boolCustomizeIPv4DNSDomain = TRUE
   End If

   'Check if at least one of the parameters are provided
    Dim boolParams : boolParams = _
           boolCustomizeIPv6 OR _
           boolCustomizeIPv6Gateway OR _
           boolCustomizeIPv6DNS OR _
           boolCustomizeIPv4DNS OR _
           boolCustomizeIPv4WINS OR _
           boolResetIPv6 OR _
           boolCustomizeIPv4DNSDomain
    If boolParams = FALSE Then
       Usage("Error: At least one of Reset / IP address / Gateway / DNS server" _
                        & " / WINS server / ForceDNSDomain4 domain required")
    End If

   Wscript.Echo "MAC Address: " & macAddress
   Wscript.Echo "Reset level: " & resetLevel
   Wscript.Echo "Enum script: " & enumCmd
   Wscript.Echo "IP Address: " & ipAddress
   Wscript.Echo "Subnet prefix length: " & subnetPrefixLength
   Wscript.Echo "Subnet Address: " & subnetAddress
   Wscript.Echo "Gateway: " & gateway
   Wscript.Echo "Gateway Metric: " & gatewayMetric
   Wscript.Echo "DNS IPv6 server: " & dnsServer6
   Wscript.Echo "DNS IPv4 server: " & dnsServer4
   Wscript.Echo "WINS server: " & winsServer
   Wscript.Echo "DNS domain: " & dnsDomainIPv4
Else
   Usage("No arguments were provided")
End If

'Execute WMI in local computer
Dim strComputer
strComputer = "."

Dim objWMIService
Set objWMIService = GetObject("winmgmts:\\" & strComputer & "\root\cimv2")

Dim colItems, objItem, adapterCount
Dim strNetConnectionID, interfaceIndex, strNetGUID

strNetConnectionID = ""
interfaceIndex = -1

'WMI call to get adapter object for the given MAC address
'(Manufacturer is usually VMware or Intel. Filter 'Microsoft' to discard non-physical
' adapters, like 'Packet Scheduler Miniport' in Windows XP.)
Set colItems = objWMIService.ExecQuery("Select * From Win32_NetworkAdapter" & _
    " where MACAddress ='" & macAddress & "' and " & _
    "NOT PNPDeviceID LIKE 'ROOT\\%' and " & _
    "Manufacturer != 'Microsoft'")

adapterCount = 0

For Each objItem in colItems

   adapterCount = adapterCount + 1

   'case insensitive comparison
   If Not StrComp(objItem.MACAddress, macAddress, 1)  = 0  Then
      Wscript.Echo "Error: WMI returned adapter with Wrong MAC address."
      Wscript.Echo "MAC address: " & objItem.MACAddress
      Wscript.Echo "Network Connection Name: " & objItem.NetConnectionID
      Wscript.Echo "Description: " & objItem.Description
      Wscript.Echo "Manufacturer: " & objItem.Manufacturer
      Wscript.Quit -1
   End If

   strNetConnectionID = objItem.NetConnectionID
   ' The GUID property is not available on Windows 2003 and below
   On Error Resume Next
   strNetGUID = objItem.GUID
   On Error Goto 0

   If strNetConnectionID = "" Then
      Wscript.Echo "Error: Could not find Network connection name."
      Wscript.Echo "MAC address: " & objItem.MACAddress
      Wscript.Echo "Description: " & objItem.Description
      Wscript.Echo "Manufacturer: " & objItem.Manufacturer
      Wscript.Quit -1
   End If

   'InterfaceIndex is not accesible in Windows XP 32-bit.
   'RESETLEVEL_SINGLENIC is only set for Longhorn guest VMs, so look for InterfaceIndex
   'only when necessary
   If resetLevel = RESETLEVEL_SINGLENIC Then
      interfaceIndex = objItem.InterfaceIndex

      If interfaceIndex = -1 Then
         Wscript.Echo "Error: Could not find Network interface index."
         Wscript.Echo "MAC address: " & objItem.MACAddress
         Wscript.Echo "Description: " & objItem.Description
         Wscript.Echo "Manufacturer: " & objItem.Manufacturer
         Wscript.Quit -1
      End If
   End If

   Exit For
Next

If Not adapterCount = 1 Then
   Wscript.Echo "Error: WMI returned " & adapterCount & " adapters for the given MAC address."
   Wscript.Quit -1
End If

Wscript.Echo "Customizing Network connection '" & strNetConnectionID & "' (" _
             & macAddress & ") - Interface Index: " & interfaceIndex & " GUID: " & strNetGUID
Wscript.Echo


'Execute netsh to customize IP/gateway/WINS for the given MAC address

'netsh file path
Dim netshCmd
netshCmd = "%windir%\system32\netsh.EXE"

'arguments to netsh.exe
Dim netshArgs


'Reset IPv6 settings
If boolResetIPv6 = TRUE Then
   If resetLevel = RESETLEVEL_ALLNICS Then
      'Deletes IPv6 settings for all NICs
      'This option should be used for Windows XP/2003 only (Longhorn requires reboot)
      netshArgs = "interface ipv6 reset"

      Wscript.Echo "netsh " & netshArgs
      LaunchCommand(netshCmd), (netshArgs), (IGNORE_ERROR)
   Else
      'Delete IPv6 settings for given NIC
      'This workaround is used for Longhorn only (The 'reset' option above requires a reboot
      'in Longhorn). This method parses netsh output to enumerate IPv6 addresses & gateways.
      ResetNic (strNetConnectionID), (interfaceIndex)
   End If
End If

'customize IP address and subnet mask
If boolCustomizeIPv6 = TRUE Then
   netshArgs = "interface ipv6 add address interface=" & Chr(34) & strNetConnectionID & _
              Chr(34) & " " & ipAddress

   If Not subnetPrefixLength = "" Then
      'Add subnet prefix length to IP address only if Subnet Address is missing (vista+)
      If subnetAddress = "" Then
         netshArgs = netshArgs & "/" & subnetPrefixLength
      End If
   End If

   'Log the netsh command
   Wscript.Echo "netsh " & netshArgs

   LaunchCommand(netshCmd), (netshArgs), (DONT_IGNORE_ERROR)


   'Run additional commands in Windows XP and 2003 where we have to manually modify the
   'route to setup subnet mask
   If Not subnetAddress = "" Then
      'Add ipAddress/128 to the route
      netshArgs = "interface ipv6 add route prefix=" & ipAddress & "/128 " & _
                  "interface=" & Chr(34) & strNetConnectionID & Chr(34)

      'Log the netsh command
      Wscript.Echo "netsh " & netshArgs

      LaunchCommand(netshCmd), (netshArgs), (DONT_IGNORE_ERROR)

      'Add SubnetAddress/SubnetPrefixLength to the route
      netshArgs = "interface ipv6 add route prefix=" & subnetAddress & "/" & subnetPrefixLength &" " & _
                  "interface=" & Chr(34) & strNetConnectionID & Chr(34)

      'Log the netsh command
      Wscript.Echo "netsh " & netshArgs

      LaunchCommand(netshCmd), (netshArgs), (DONT_IGNORE_ERROR)
   End If
End If


'customize gateway and metric
If boolCustomizeIPv6Gateway = TRUE Then
   netshArgs = "interface ipv6 add route prefix=::/0 interface=" & Chr(34) & strNetConnectionID & _
              Chr(34) & " nexthop=" & gateway

   If Not gatewayMetric = "" Then
      netshArgs = netshArgs & " metric=" & gatewayMetric
   End If

   'Log the netsh command
   Wscript.Echo "netsh " & netshArgs

   LaunchCommand(netshCmd), (netshArgs), (DONT_IGNORE_ERROR)
End If

'customize DNS server IPv6
If boolCustomizeIPv6DNS = TRUE Then
   addDnsServer "ipv6", dnsServer6
End If

'customize DNS server IPv4
If boolCustomizeIPv4DNS = TRUE Then
   addDnsServer "ipv4", dnsServer4
End If

'customize WINS server
If boolCustomizeIPv4WINS = TRUE Then
   Dim isIgnoreError

   if winsServer <> "DELETEALL" Then
      ' Configure WINS server
      ' Windows XP/2003 - only allows shortname 'ip'/'wins' instead of ipv4/winsserver
      ' Longhorn accepts both 'ip add wins' and 'ipv4 add winsserver' commands
      netshArgs = "interface ip add wins name=" & Chr(34) & strNetConnectionID & _
                 Chr(34) & " " & winsServer
      isIgnoreError = DONT_IGNORE_ERROR
   Else
      ' Delete all WINS server settings
      netshArgs = "interface ip delete wins name=" & Chr(34) & strNetConnectionID & _
                 Chr(34) & " all"
      isIgnoreError = IGNORE_ERROR
   End If

   'Log the netsh command
   Wscript.Echo "netsh " & netshArgs

   LaunchCommand(netshCmd), (netshArgs), (isIgnoreError)
End If

'customize DNSdomain suffix: disconnected NIC only.
If boolCustomizeIPv4DNSDomain = TRUE Then
    If strNetGUID <> "" Then
        Dim regNicPath
        regNicPath = regIPInterfaceConfigKey & strNetGUID & "\" & "Domain"
        If dnsDomainIPv4 = "NONE" Then
           dnsDomainIPv4 = ""
        End If
        updateRegistryValue regNicPath, dnsDomainIPv4, "REG_SZ"
    Else
        Wscript.Echo "Can't customize IPv4DNSDomain: no GUID for the NIC is available (Windows 2003 or older)"
    End If
End If

' Updates a value in the Registry.
' Returns an error code, 0 on success
Function updateRegistryValue(strRegPath, strNewValue, ValType)
    Dim WshShell, curValue, errcode
    Set WshShell = WScript.CreateObject("WScript.Shell")
    On Error Resume Next

    curValue = WshShell.RegRead(strRegPath)
    errcode = err.number
    If errcode <> 0 Then
        Wscript.Echo "Can't locate a Registry value at " & strRegPath
    Else
        If curValue <> strNewValue Then
            Wscript.Echo "Setting [" & strRegPath & "] to " & strNewValue
            WshShell.RegWrite strRegPath, strNewValue, ValType
            errcode = err.number
            If errcode <> 0 Then
                Wscript.Echo "Can't update a Registry value at " & strRegPath
            End If
        End If
    End If
    WshShell = nothing
    updateRegistryValue = errcode
End Function

'Add DNS strServer for strProtocol "ipv4" or "ipv6"
Function addDnsServer(strProtocol, strServer)
   ' Windows XP/2003 - only allows shortname 'dns' instead of dnsserver
   '                 - expects 'interface=' (or blank)
   ' Longhorn        - accepts both 'add dns' and 'add dnsserver' commands
   '                 - expects 'name=' (or blank)
   netshArgs = "interface " & strProtocol & " add dns " & Chr(34) & strNetConnectionID & _
              Chr(34) & " " & strServer

   'Log the netsh command
   Wscript.Echo "netsh " & netshArgs

   'netsh would return an error on benign cases such as when the DNS server was
   'already added (e.g. it would treat IPv4 and IPv6v4-mapped as one).
   'Ignore these errors.
   'NOTE also that that netsh would actually try to query the DNS server,
   'but won't return an error if it's not found.
   Dim res
   res = LaunchCommand (netshCmd, netshArgs, IGNORE_ERROR)
   If InStr(res, "parameter is incorrect") > 0 Then
    Wscript.Echo "Exiting due to " & res
    Wscript.Quit -1
   End if
End Function

'Function to launch external binaries
Function LaunchCommand(ByVal cmd, ByVal cmdArgs, ByVal ignoreCmdError)
   Dim WshShell
   Set WshShell = WScript.CreateObject("WScript.Shell")

   Dim cmdExec
   Set cmdExec = WshShell.Exec(cmd & " " & cmdArgs)

   Do While cmdExec.Status = 0
        WScript.Sleep 100
   Loop

   'Store stdout contents
   Dim stdOut
   stdOut = cmdExec.StdOut.ReadAll
   Wscript.Echo stdOut

   If not cmdExec.ExitCode = 0 Then
      Wscript.Echo "Error code returned by command : " & cmdExec.ExitCode

      If ignoreCmdError = IGNORE_ERROR Then
         Wscript.Echo "(Ignoring Error)"
      Else
         Wscript.Quit cmdExec.ExitCode
      End If
   End If

   'Return stdout
   LaunchCommand = stdOut
End Function


'Reset IPv6 settings for the given NIC
Function ResetNic(ByVal strNetConnectionID, ByVal interfaceIndex)
   Dim enumCmdArgs, cmdOutput

   'Enumerate IPv6 addresses
   Wscript.Echo ""
   Wscript.Echo "--- Enumerating IPv6 addresses to be removed ---"

   enumCmdArgs = "address " & Chr(34) & strNetConnectionID & Chr(34)
   Wscript.Echo enumCmd & " " & enumCmdArgs
   cmdOutput = LaunchCommand(enumCmd, enumCmdArgs, IGNORE_ERROR)

   Dim ipv6Address, ipv6Addresses
   'Parse CRLF separated IPv6 addresses into an array
   ipv6Addresses = Split(cmdOutput, vbCrLf)

   'Delete IPv6 addresses
   For Each ipv6Address in ipv6Addresses
      If Not Len(ipv6Address) = 0 Then
         ' Remove the interface index if the ipv6 address constains it
         ' addressAndIndex(0) stores the ipv6 address
         ' addressAndIndex(1) stores the interface index if ipv6Address contains it
         ' DO NOT use addressAndIndex(1) because it might cause runtime error
         ' if the original string does not contain "%".
         Dim addressAndIndex
         addressAndIndex = Split(ipv6Address, "%")
         netshArgs = "interface ipv6 delete address interface=" & Chr(34) & _
                     strNetConnectionID & Chr(34) & " " & addressAndIndex(0)

         Wscript.Echo "netsh " & netshArgs
         LaunchCommand(netshCmd), (netshArgs), (IGNORE_ERROR)
      End If
   Next


   'Enumerate IPv6 Gateways
   Wscript.Echo ""
   Wscript.Echo "--- Enumerating IPv6 Gateways to be removed ---"

   enumCmdArgs = "gateway " & interfaceIndex
   Wscript.Echo enumCmd & " " & enumCmdArgs
   cmdOutput = LaunchCommand(enumCmd, enumCmdArgs, IGNORE_ERROR)

   Dim ipv6Gateway, ipv6Gateways
   'Parse CRLF separated IPv6 gateways into an array
   ipv6Gateways = Split(cmdOutput, vbCrLf)

   'Delete IPv6 gateways
   For Each ipv6Gateway in ipv6Gateways
      If Not Len(ipv6Gateway) = 0 Then
         netshArgs = "interface ipv6 delete route ::/0 interface=" & Chr(34) & _
                     strNetConnectionID & Chr(34) & " " & ipv6Gateway

         Wscript.Echo "netsh " & netshArgs
         LaunchCommand(netshCmd), (netshArgs), (IGNORE_ERROR)
      End If
   Next


   'Delete DNS entries
   netshArgs = "interface ipv6 delete dns " & Chr(34) & strNetConnectionID & _
              Chr(34) & " all"

   Wscript.Echo "netsh " & netshArgs
   LaunchCommand(netshCmd), (netshArgs), (IGNORE_ERROR)
End Function

'Print script's usage
Sub Usage(ByVal message)
   Wscript.Echo message
   Wscript.Echo "Usage: netshIPv6.vbs " _
                & "/MacAddress:<MAC address> " _
                & "/Reset:ALLNICS|SINGLENIC " _
                & "/EnumPath:<File path to IPv6 enumeration batch script> " _
                & "/IPAddress:<IPv6 address> " _
                & "/SubnetPrefixLength:<IPv6 subnet prefix length> " _
                & "/SubnetAddress:<IPv6 subnet address for Windows XP/2003> " _
                & "/Gateway:<IPv6 gateway> " _
                & "/GatewayMetric:<IPv6 gateway metric> " _
                & "/DNSserver:<IPv6 DNS server address> " _
                & "/DNSserver4:<IPv4 DNS server address> " _
                & "/WINSserver:<IPv4 WINS server address>|DELETEALL  " _
                & "/ForceDNSDomain4:<IPv4 DomainName|NONE> "

   Wscript.Quit -1
End Sub
