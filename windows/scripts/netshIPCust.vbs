'/* **********************************************************
' * Copyright (c) 2017 VMware, Inc.  All rights reserved.
' * -- VMware Confidential
' * **********************************************************/
'/**
' * @file
' *
' *    SRM wrapper around netsh.exe, overhauled and extended with IPv4 support
' *    version of the old netshIP6.vbs script. See PrintUsageAndExit() function
' *    for a description of the CLI interface.
' *
' *    Given a MAC address, the script customizes IPv4/IPv6 Gateway, DNS, DomainName
' *    and WINS configuration.
' *
' *    Notes:
' *      - Designed to customize successfully IP settings on disconnected NICs.
' *      - Doesn't perform any network configuration changes via WMI.
' *      - Doesn't provide support for Windows NT 5.x versions(i.e. XP and 2003)
' */

Option Explicit

' Verbose switch
Dim boolLogOnVerbose

' Common network configuration settings

' Comma-separated list of DNS suffixes to set. Global network configuration.
' Uninitialized value means no changes unless /ResetDNSSuffixList is specified.
Dim dnsSuffixList
' Clear the current DNS suffixes if TRUE
Dim boolResetDNSSuffixList : boolResetDNSSuffixList = FALSE

' Network specific configuration settings

'----- Mandontary NIC specific input parameters ------
' MAC address of adapter to be customized.
Dim macAddress
' IPv4 or IPv6 target configuration
Dim protocol

'----- Optional settings for both IPv4 and IPv6 protocols -----
' Enable DHCP on the target NIC if TRUE
Dim boolEnableDhcp
' Configure static IP settings for the target NIC if TRUE
Dim boolSetStaticIP

' IPv4 or IPv6 address to set to the target adapter.
' Uninitialized value means no changes
Dim ipAddress
' IPv4 subnetMask
' Uninitialized value means no changes
Dim subnetMaskIPv4
' IPv6 Subnet mask (number of bits to mask)
' Uninitialized value means no changes
Dim subnetPrefixLengthIPv6
' Comma-separated list of IPv4 or IPv6 gateway and metric.
' Uninitialized value means no changes
Dim gatewayMetricPairList

' Comma-separated list of NIC specific IPv4 or IPv6 DNS servers
' Uninitialized value means no changes unless /ResetDNSServerList is specified.
Dim dnsServerList
' Clear the current DNS servers if TRUE
Dim boolResetDNSServerList : boolResetDNSServerList = FALSE

' Update Domain name which is global network configuration setting.
' Uninitialized value means no changes unless /ResetDomainName is specified.
Dim domainName
' Clear the current Domain name if TRUE
Dim boolResetDomainName : boolResetDomainName = FALSE

' NetBios mode setting. Expectable values:
' 0 -- Enable Netbios via DHCP. Default.
' 1 -- Enable Netbios
' 2 -- Disable Netbios
'
' Uninitialized value means no changes.
Dim netBiosModeIPv4

' Comma-separated list of IPv4 WINS servers.
' Uninitialized value means no changes unless /ResetWINSServerList is specified.
Dim winsServerList
' Clear the current IPv4 WINS servers if TRUE
Dim boolResetWINSServerList : boolResetWINSServerList = FALSE

' Fail the script on critical error with an error exit code.
Const DONT_IGNORE_ERROR = 0
' Ignore a non-critical error.
Const IGNORE_ERROR = 1
' Retry count to attempt to set static IP address.
Const SET_STATIC_ADDR_RETRY_COUNT = 30
' Constant for 10 seconds retry interval to set static IP address.
' The value is in milliseconds.
Const SET_STATIC_ADDR_RETRY_INTERVAL = 10000
' Retry count to attempt to enable DHCP.
' Note that netsh may return same error codes, e.g 1, for both real error
' situations or just attempt to apply a configuration like enabling DHCP on
' NICs where DHCP is already enabled.  Hence choose values for this retry
' count and the sleep interval below with attention to the impact on RTO for
' the most common scenarios.
Const ENABLE_DHCP_RETRY_COUNT = 1
' Constant for 2 seconds retry interval to retry enabling of DHCP.
' The value is in milliseconds.
Const ENABLE_DHCP_RETRY_INTERVAL = 2000

' Used when the target NIC cannot be determined or a failure occurred while
' reading the current NIC configuration.
Const TARGET_NIC_NOT_FOUND_ERROR_CODE = -1
' Used in case of invalid input parameters
Const INVALID_ARGUMENTS_ERROR_CODE = -2
' Used in case of not supported Windows version detected
Const NOT_SUPPORTED_WINDOWS_VERSION = -3

Const IPV4_PROTOCOL = "ipv4"
Const IPV6_PROTOCOL = "ipv6"

Const ENABLE_DHCP_CMD = "enable_dhcp"
Const SET_STATIC_CMD = "set_static"

' Registry keys for IP interface configuration.
' Used to read/modify network IP configuration directly from the registry
' when netsh doesn't provide needed functionality.
Const REG_KEY_TCPIP = "HKLM\SYSTEM\CurrentControlSet\services\Tcpip\Parameters"
Const REG_KEY_TCPIP_INTERFACE = "HKLM\SYSTEM\CurrentControlSet\services\Tcpip\Parameters\Interfaces"

' Registry keys for NetBIOS interface configuration.
' Needed since Netsh doesn't provide utilities to change 'NetBiosMode' on NICs
Const REG_KEY_NETBT_INTERFACE = "HKLM\SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces"

' Netsh file path. Requires the script to be run with administrative privileges.
Const NETSH_CMD = "%SystemRoot%\system32\netsh.EXE"

'----- Connection parameters determinedby the specified MAC Address on run time -----
' GUID for the NIC being customized.
Dim targeNicGUID
' Connection name for the NIC being customized.
Dim targetNicConnectionName
' Interface index for the NIC being customized.
Dim targetNicInterfaceIndex

'----- Start of script execution ------
Log "Begin customization process"

' Get the CLI input parameters by name
Dim namedArgs
Set namedArgs = WScript.Arguments.Named

ParseAndValidateInputArguments
ApplyGlobalNetworkConfiguration
ApplyNicSpecifciNetworkConfiguration

Log "End customization process"
'----- End of script execution ------
NotifyAndExit 0

' Parse and validate input arguments. In case of invalid data
' print the script usage and exit.
Function ParseAndValidateInputArguments
   If WScript.Arguments.Count = 0 Then
      PrintUsageAndExit("No arguments were provided")
   End If

   boolLogOnVerbose = FALSE
   If namedArgs.Exists("Verbose") Then
      boolLogOnVerbose = TRUE
      Log "Verbose: " & boolLogOnVerbose
   End If

   ' Parse input arguments for non-connection specific configuration
   ParseCommonNetworkSettings()
   ' Parse NIC specific configuration settings common for both IPv4 and IPv6.
   ParseNICSpecificSettings()

   'Validate the set of customization operations
   If (HasGlobalNetworkSettings = FALSE) AND _
      (HasNICSpecificNetworkSettings = FALSE) Then
      PrintUsageAndExit(_
         "Error: No valid configuration settings provided. " & vbCrLf & _
         "At least one of /Command, /Gateway, /DomainName, /DNSServerList, " & _
         "/NetBIOSMode or /WINSServerList configuration settings required." & vbCrLf)
   End If

   If HasNICSpecificNetworkSettings = TRUE Then
      If IsEmpty(macAddress) Then
         PrintUsageAndExit("Error: Missing MAC address")
      End If

      If IsEmpty(protocol) Then
         PrintUsageAndExit("Error: Missing Protocol switch")
      End If

      If (boolSetStaticIP And boolEnableDhcp) Then
         PrintUsageAndExit("Error: Only one of the set_static " &_
                           "and enable_dhcp commands could be specified.")
      End If
   End If
End Function

' Auxiliary function to determine whether global network settings have been provided.
Function HasGlobalNetworkSettings
   HasGlobalNetworkSettings =_
      (Not IsEmpty(dnsSuffixList)) OR boolResetDNSSuffixList
End Function

' Auxiliary function to determine whether NIC specific settings have been provided.
Function HasNICSpecificNetworkSettings
   HasNICSpecificNetworkSettings =_
      boolEnableDhcp OR _
      boolSetStaticIP OR _
      (Not IsEmpty(dnsServerList)) OR boolResetDNSServerList OR _
      (Not IsEmpty(domainName)) OR boolResetDomainName OR _
      (Not IsEmpty(netBiosModeIPv4)) OR _
      (Not IsEmpty(winsServerList)) OR boolResetWINSServerList
End Function

' Parse common input arguments for connection specific configuration. In case of invalid data
' print the script usage and exit.
Function ParseCommonNetworkSettings
   'Get global DNS suffix list setting.
   If namedArgs.Exists("DNSSuffixList") Then
      dnsSuffixList = namedArgs.Item("DNSSuffixList")
      If dnsSuffixList = "" Then
         PrintUsageAndExit("Error: No value specified for /DNSSuffixList parameter.")
      End If
      Log "Global DNS Suffix List: " & dnsSuffixList
   End If

   If namedArgs.Exists("ResetDNSSuffixList") Then
      boolResetDNSSuffixList = TRUE
      If Not IsEmpty(dnsSuffixList) Then
         PrintUsageAndExit("Error: Only one of /DNSSuffixList and " &_
                           "/ResetDNSSuffixList could be specified.")
      End If
      Log "Clear global DNS Suffix List: " & boolResetDNSSuffixList
   End If
End Function

' Parse common NIC specific input arguments for both IPv4 and IPv6. In case of invalid data
' print the script usage and exit.
Function ParseNICSpecificSettings
   ' Get MAC address for the target NIC
   If namedArgs.Exists("MacAddress") Then
      macAddress = namedArgs.Item("MacAddress")
      If macAddress = "" Then
         PrintUsageAndExit("Error: No value specified for /MacAddress parameter.")
      End If
      Log "MAC Address: " & macAddress
   End If

   If namedArgs.Exists("Protocol") Then
      protocol = namedArgs.Item("Protocol")
      If protocol = "" Then
         PrintUsageAndExit("Error: No value specified for /Protocol parameter.")
      End If
      If (protocol <> IPV4_PROTOCOL) And (protocol <> IPV6_PROTOCOL) Then
         PrintUsageAndExit("Error: Invalid Protocol switch value. Expecting /Protocol:<ipv4|ipv6>")
      End If
      Log "Protocol: " & protocol
   End If

   boolEnableDhcp = FALSE
   boolSetStaticIP = FALSE
   If namedArgs.Exists("Command") Then
      Dim command : command = namedArgs.Item("Command")
      If command = ENABLE_DHCP_CMD Then
         boolEnableDhcp = TRUE
         Log "Command: Enable DHCP"
      ElseIf command = SET_STATIC_CMD Then
         boolSetStaticIP = TRUE
         Log "Command: Set static IP settings"
         ParseStaticIPSettings()
      ElseIf command = "" Then
         PrintUsageAndExit("Error: No value specified for /Command.")
      Else
         PrintUsageAndExit("Error: Invalid /Command value. Expecting /Command::<enable_dhcp|set_static>")
      End If
   End If

   'Get Domain name setting
   If namedArgs.Exists("DomainName") Then
      domainName = namedArgs.Item("DomainName")
      If domainName = "" Then
         PrintUsageAndExit("Error: No value specified for /DomainName parameter.")
      End If
      Log "DomainName: " & domainName
   End If

   If namedArgs.Exists("ResetDomainName") Then
      boolResetDomainName = TRUE
      If Not IsEmpty(domainName) Then
         PrintUsageAndExit("Error: Only one of /DomainName and " &_
                           "/ResetDomainName could be specified.")
      End If
      Log "Clear current Domain Name : " & boolResetDomainName
   End If

   'Get IPv4/IPv6 DNS servers list.
   If namedArgs.Exists("DNSServerList") Then
      dnsServerList = namedArgs.Item("DNSServerList")
      If dnsServerList = "" Then
         PrintUsageAndExit("Error: No value specified for /DNSServerList parameter.")
      End If
      Log "DNS Servers Search Order: " & dnsServerList
   End If

   If namedArgs.Exists("ResetDNSServerList") Then
      Log "DNS Servers Search Order: " & dnsServerList
      boolResetDNSServerList = TRUE
      If Not IsEmpty(dnsServerList) Then
         PrintUsageAndExit("Error: Only one of /DNSServerList and " &_
                           "/ResetDNSServerList could be specified.")
      End If
      Log "Clear current DNS Servers Search Order : " & boolResetDNSServerList
   End If

   'Get IPv4 NetBios mode settings
   If namedArgs.Exists("NetBIOSMode") Then
      If protocol <> IPV4_PROTOCOL Then
         Log "WARNING: NetBIOSMode provided but not in IPv4 context. Ignoring the setting"
      Else
         netBiosModeIPv4 = namedArgs.Item("NetBIOSMode")
         Log "NetBIOS Mode: " & netBiosModeIPv4
         If (netBiosModeIPv4 <> "0") And (netBiosModeIPv4 <> "1") And (netBiosModeIPv4 <> "2") Then
            PrintUsageAndExit(_
               "Error: Invalid value for NetBIOSMode. " &_
               "Expecting '0' as via DHCP, '1' as Enabled or '2' as Disabled")
         End If
      End If
   End If

   'Get IPv4 WINSserver settings
   If namedArgs.Exists("WINSServerList") Then
      If protocol <> IPV4_PROTOCOL Then
         PrintUsageAndExit("WINSServerList provided not in the context of IPv4 protocol.")
      End If
      winsServerList = namedArgs.Item("WINSServerList")
      If winsServerList = "" Then
         PrintUsageAndExit("Error: No value specified for /WINSServerList parameter.")
      End If
      Log "WINS Servers List: " & winsServerList
   End If

   If namedArgs.Exists("ResetWINSServerList") Then
      boolResetWINSServerList = TRUE
      If Not IsEmpty(winsServerList) Then
         PrintUsageAndExit("Error: Only one of /WINSServerList and " &_
                           "/ResetWINSServerList could be specified.")
      End If
      If protocol <> IPV4_PROTOCOL Then
         PrintUsageAndExit("ResetWINSServerList used not in IPv4 context.")
      End If
      Log "Clear current WINS Servers List : " & boolResetWINSServerList
   End If

End Function

' Parse static IP input parameters.
Function ParseStaticIPSettings
   'Get IPv4 or IPv6 static address settings if specified.
   If Not namedArgs.Exists("IPAddress") Then
      PrintUsageAndExit("Error: Cannot set static IPv4 configuration. Missing /IPAddress")
   End If

   ipAddress = namedArgs.Item("IPAddress")
   Log "IP Address: " & ipAddress
   If ipAddress = "" Then
      PrintUsageAndExit("Error: No value specified for /IPAddress parameter.")
   End If

   If protocol = IPV4_PROTOCOL Then
      If NOT namedArgs.Exists("SubnetMask") Then
         PrintUsageAndExit("Error: Cannot set static IPv4 configuration. Missing SubnetMask")
      End If
      subnetMaskIPv4 = namedArgs.Item("SubnetMask")
      Log "Subnet Mask: " & subnetMaskIPv4
      If subnetMaskIPv4 = "" Then
         PrintUsageAndExit("Error: Cannot set static IPv4 configuration. Empty SubnetMask specified")
      End If
   End If

   If protocol = IPV6_PROTOCOL Then
      If namedArgs.Exists("SubnetPrefixLength") Then
         subnetPrefixLengthIPv6 = namedArgs.Item("SubnetPrefixLength")
         Log "Subnet Prefix Length: " & subnetMaskIPv4
         If subnetPrefixLengthIPv6 = "" Then
            PrintUsageAndExit("Error: Cannot set static IPv6 configuration. Empty SubnetPrefixLength specified")
         End If
      End If
   End If

   ' Get GatewayMetricList
   If namedArgs.Exists("GatewayMetricList") Then
      gatewayMetricPairList = namedArgs.Item("GatewayMetricList")
      If gatewayMetricPairList = "" Then
         PrintUsageAndExit("Error: No value specified for /GatewayMetricList parameter.")
      End If
      Log "GatewayMetricList: " & gatewayMetricPairList
   End If
End Function

' Apply global network configuration parsed from the CLI parameters set.
Function ApplyGlobalNetworkConfiguration
   If HasGlobalNetworkSettings = FALSE Then
      Exit Function
   End If

   UpdateDNSSuffixSearchList
End Function

' Apply the connection specific configuration parsed from the CLI parameters set.
Function ApplyNicSpecifciNetworkConfiguration
   If HasNICSpecificNetworkSettings = FALSE Then
      Exit Function
   End If

   ExtractNICIdentifiersByMacAddress

   If (protocol = IPV4_PROTOCOL) AND (boolSetStaticIP OR boolEnableDhcp) Then
      ' Always clear WINS servers when setting static IPv4 or enabling DHCPv4.
      ' This is done to keep the behaviour of old style Windows customization.
      ClearWINSServerList
      boolResetWINSServerList = FALSE ' No need of second reset if configured.
   End If

   If boolEnableDhcp = TRUE Then
      EnableDhcp
   ElseIf boolSetStaticIP = TRUE Then
      SetStaticIPSettings
   End If

   UpdateDnsServerList
   UpdateDomainName
   UpdateNetBiosMode
   UpdateWINSServerList
End Function

' Extract all needed NIC identifiers by the specified MAC Address
Function ExtractNICIdentifiersByMacAddress
   If macAddress = "" Then
      PrintUsageAndExit("Error: Empty value specified for /MacAddress.")
   End If

   ' Execute WMI in local computer
   Dim objWMIService
   Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")

   Dim colItems, objItem, adapterCount

   ' Initialize the global NIC identifiers
   targeNicGUID = ""
   targetNicConnectionName = ""
   targetNicInterfaceIndex = -1

   ' WMI call to get adapter object for the given MAC address
   ' (Manufacturer is usually VMware or Intel. Filter 'Microsoft' to discard non-physical
   ' adapters, like 'Packet Scheduler Miniport' in Windows XP.)
   Set colItems = objWMIService.ExecQuery(_
       "Select * From Win32_NetworkAdapter where " & _
          " MACAddress ='" & macAddress & "' and " & _
          " NOT PNPDeviceID LIKE 'ROOT\\%' and " & _
          " Manufacturer != 'Microsoft'")

   adapterCount = 0

   For Each objItem in colItems

      adapterCount = adapterCount + 1

      ' Case insensitive comparison
      If Not StrComp(objItem.MACAddress, macAddress, 1) = 0  Then
         Log "Error: The WMI query returned adapter with Wrong MAC address."
         Log "MAC address: " & objItem.MACAddress
         Log "Network Connection Name: " & objItem.NetConnectionID
         Log "Description: " & objItem.Description
         Log "Manufacturer: " & objItem.Manufacturer
         NotifyAndExit TARGET_NIC_NOT_FOUND_ERROR_CODE
      End If

      targetNicConnectionName = objItem.NetConnectionID
      If targetNicConnectionName = "" Then
         Log "Error: Could not find Network connection name."
         Log "MAC address: " & objItem.MACAddress
         Log "Description: " & objItem.Description
         Log "Manufacturer: " & objItem.Manufacturer
         NotifyAndExit TARGET_NIC_NOT_FOUND_ERROR_CODE
      End If

      ' The GUID property is not available on Windows 2003 and below
      On Error Resume Next
      targeNicGUID = objItem.GUID
      If Err.Number <> 0 Then
         Log "Error: Could not find Network interface GUID. " &_
             "Detected not supported Windows 2003 version or older."
         Log "MAC address: " & objItem.MACAddress
         Log "Description: " & objItem.Description
         Log "Manufacturer: " & objItem.Manufacturer
         NotifyAndExit NOT_SUPPORTED_WINDOWS_VERSION
      End If
      On Error Goto 0

      ' Note: InterfaceIndex is not accesible in Windows XP 32-bit.
      targetNicInterfaceIndex = objItem.InterfaceIndex
      If targetNicInterfaceIndex = -1 Then
         Log "Error: Could not find Network interface index. " &_
             "Detected not supported Windows 2003 version or older."
         Log "MAC address: " & objItem.MACAddress
         Log "Description: " & objItem.Description
         Log "Manufacturer: " & objItem.Manufacturer
         NotifyAndExit NOT_SUPPORTED_WINDOWS_VERSION
      End If

      Exit For
   Next

   If adapterCount = 0 Then
      Log "Error: No network adapter found for MAC address: " & macAddress
      Wscript.Quit -1
   End If

   If adapterCount > 1 Then
      Log "Error: WMI returned " & adapterCount & " adapters for the given MAC address."
      Wscript.Quit -1
   End If

   Log "Customizing Network connection '" & targetNicConnectionName & "' (" _
       & macAddress & ") - Interface Index: " & targetNicInterfaceIndex &_
       " GUID: " & targeNicGUID
End Function

Function ClearTargetNicDnsServerList
   Log "Clearing DNS server list on NIC with GUID: " & targeNicGUID
   Dim netshArgs : netshArgs = "interface " & protocol & " delete dnsserver " _
                               & Chr(34) & targetNicConnectionName & Chr(34) & " all"
   Call LaunchNetshCmd(netshArgs, DONT_IGNORE_ERROR)
End Function

Function EnableDhcp
   Log "Enabling DHCP for " & protocol & " on NIC with GUID: " & targeNicGUID
   If protocol = IPV4_PROTOCOL Then
      EnableDHCPOnIPv4
   Else
      ' DHCPv6 differs a lot compared to DHCPv4. For DHCPv6 on Windows
      ' there are three different modes plus additional configuration settings
      ' that controls the protocol behaviour. The modes are :
      '   - Stateless Address Auto Configuration (SLAAC) - Uses ICMPv6 RA
      '   - Stateless DHCPv6 - SLAAC for IP address + DHCP for DNS, NTP and etc.
      '   - Stateful DCHPv6 - Exactly the same behaviour as IPv4 DHCP
      '
      ' As today, SRM doesn't customize the DHCPv6 mode and just clear all
      ' previously set IPv6 addresses, gateways and DNS servers. In this way, when
      ' the NIC is reconnected, IPv6 stack will be renewed as the DHCP configuration
      ' used on protected site.
      ClearIPv6Settings
   End If
End Function

Function EnableDHCPOnIPv4
   ' The format of the netsh command to enable DHCP on IPv4 is :
   ' netsh interface ipv4 set address "ConnectionName" dhcp
   Dim netshArgs : netshArgs = "interface " & protocol & " set address "_
                               & Chr(34) & targetNicConnectionName & Chr(34) & " dhcp"

  ' Note that netsh may return same error code 1 for both real error situations like
  ' not responding internal RPC service or just attempt to enable DHCP on
  ' NICs where it is already enabled.  The trade-off is to provide retry logic with
  ' a small impact on RTO time and then ignore all the failed attempts in case of
  ' error code 1.
   Dim exitCode : exitCode = _
      LaunchNetshCmdWithRetry( _
         netshArgs, _
         IGNORE_ERROR, _
         ENABLE_DHCP_RETRY_COUNT, _
         ENABLE_DHCP_RETRY_INTERVAL)

   If exitCode = 1 Then
      ' Netsh uses exit code '1' as partial success exit code. For DNS add cmd
      ' this means that DHCP is already enabled on this NIC.
      Log "DHCPv4 already enabled on NIC with GUID: " & targeNicGUID
   ElseIf exitCode <> 0 Then
       Log "ERROR: Error code '" & exitCode & "' returned by command : "
       Log "(Cannot ignore the Error. Stop the customization process)"
       NotifyAndExit exitCode
   End If

   ' Clear DNS search order list explicitly. Similar to WMI enableDhcp routine,
   ' netsh doesn't clear the DNS search order list when enabling DHCP on NICs.
   ClearTargetNicDnsServerList
End Function

' Removing empty elements from string array
Sub RemoveEmptyStrElements(ByRef strArray())
   Dim str
   Dim lastNotEmpty : lastNotEmpty = -1
   For Each str In strArray
      If str <> "" Then
        lastNotEmpty = lastNotEmpty + 1
       strArray(lastNotEmpty) = str
     End If
   Next
   ReDim Preserve strArray(lastNotEmpty)
End Sub

' Enumerate NIC's IPv6 addresses.
' Result : String array with the result IPv6 addresses.
Function EnumNicIPv6Addreses
   Dim netshArgs : netshArgs = "interface ipv6 show addresses " &_
                                Chr(34) & targetNicConnectionName & Chr(34)
   Dim output : output = LaunchNetshCmdGetOutput(netshArgs)
   Dim lines : lines = Split(output, vbCrLf)
   ' Parsing 'netsh interface ipv6 show addresses <Connection_Name>' output.
   ' The expected format for each address is as follows:
   '
   '    Address <IPv6_Address>[%interface_index] Parameters
   '    ---------------------------------------------------------
   '    <Address specific properties>
   '
   ' Rely on '-...-' delimiter line to recognize the lines containing addresses.
   ' Preferred over words markers to avoid localization problems.
   Dim previousLine : previousLine = ""
   Dim marker : marker = "-----"
   Dim markerLen : markerLen = Len(marker)

   Dim resultList()
   Dim idx : idx = 0
   Dim line
   For Each line In lines
      line = Trim(line)
      If (Left(line, markerLen) = marker) And (previousLine <> "") Then
         ' Tokens should be a zero-based string array with three elements
         Dim tokens : tokens = Split(previousLine)
         Call RemoveEmptyStrElements(tokens)
         ' Expecting 3 tokens, so the upper index should be 2
         If Ubound(tokens) = 2 Then
            ' The IPv6 address should be the second token. It could contain
            ' interface index, so remove it.
            Dim addressWithIndex : addressWithIndex = Split(tokens(1), "%")

            ReDim Preserve resultList(idx)
            resultList(idx) = addressWithIndex(0)
            idx = idx + 1

            Log "   IPv6 Address[" & idx & "] : " & addressWithIndex(0)
         Else
            Log "WARNING: Unexpected 'netsh int ipv6 show addresses <ConnectionName>'" &_
                " format found: '" & previousLine & "'. Ignoring"
         End If
      End If
      previousLine = line
   Next

   EnumNicIPv6Addreses = resultList
End Function

' Enumerate NIC's IPv6  gateways.
' Result : String array with the result IPv6 gateways
Function EnumNicIPv6Gateways
   Dim netshArgs : netshArgs = "interface ipv6 show route "
   Dim output : output = LaunchNetshCmdGetOutput(netshArgs)
   Dim lines : lines = Split(output, vbCrLf)
   ' Parsing 'netsh interface ipv6 show route' output.
   ' The expected format for each address is as follows:
   '
   ' Publish  Type      Met  Prefix  Idx  Gateway/Interface Name
   ' -------  --------  ---  ------- ---  ------------------------
   ' No       Manual    256  ::/0      7  fe80::aa0c:dff:fe99:87f
   '
   ' Rely on '::/0' prefix to recognize default gateways and then
   ' check the Idx to recognize the target NIC's entries.
   Dim marker : marker = "::/0"

   Dim resultList()
   Dim idx : idx = 0
   Dim line
   For Each line In lines
      line = Trim(line)
      If (InStr(line, marker) <> 0) Then
         ' Tokens should be a zero-based string array with three elements
         Dim tokens : tokens = Split(line)
         Call RemoveEmptyStrElements(tokens)
         ' Expecting 6 tokens, so the upper index should be 5
         If Ubound(tokens) = 5 Then
            ' Filtering the lines based on the target NIC Index
            If tokens(4) = CStr(targetNicInterfaceIndex) Then
               ReDim Preserve resultList(idx)
               resultList(idx) = tokens(5)
               idx = idx + 1

               Log "   IPv6 gateway[" & idx & "] : " & tokens(5)
            End If
         Else
            Log "WARNING: Unexpected 'netsh int ipv6 show route' format found: '" &_
                line & "'. Ignoring the line"
         End If
      End If
   Next

   EnumNicIPv6Gateways = resultList
End Function

Sub ClearIPv6Addresses
   Dim netshArgs
   Log "Deleting all IPv6 addresses set on NIC with GUID: " & targeNicGUID
   Dim ipv6Address, ipv6Addresses
   ipv6Addresses = EnumNicIPv6Addreses

   ' Note: 'netsh ipv6 delete address' command will fail to delete address
   '        marked as 'Address Type: Other'. The corresponding error
   '       "The parameter is incorrect" is ignored, but left in the output.
   For Each ipv6Address in ipv6Addresses
      If Not Len(ipv6Address) = 0 Then
         netshArgs = "interface ipv6 delete address " & Chr(34) & _
                     targetNicConnectionName & Chr(34) & " " & ipv6Address
         Call LaunchNetshCmd(netshArgs, IGNORE_ERROR)
      End If
   Next
End Sub

Sub ClearIPv6DefaultGateways
   Dim netshArgs
   Log "Deleting all IPv6 gateways set on NIC with GUID: " & targeNicGUID
   Dim ipv6Gateway, ipv6Gateways
   ipv6Gateways = EnumNicIPv6Gateways

   For Each ipv6Gateway in ipv6Gateways
      If Not Len(ipv6Gateway) = 0 Then
         netshArgs = "interface ipv6 delete route ::/0 interface=" & Chr(34) & _
                     targetNicConnectionName & Chr(34) & " " & ipv6Gateway
         Call LaunchNetshCmd(netshArgs, IGNORE_ERROR)
      End If
   Next
End Sub

Function ClearIPv6Settings
   ' Netsh doesn't provide [all] source switch to delete IPv6 addresses and gateways.
   ' Such switch is available only for DNS server entries. IPv6 addresses and gateways
   ' need to be deleted one by one. So, there are two options: 1 Search through
   ' registries, 2 Uses some list commands and parse the output. Working directly
   ' with registry for IPv6 is too error prone because of the binary format used in
   ' registries names/values, various locations and so on. Hence, ended up with parsing
   ' output from standard commands like 'netsh int ip show addresses|route'. See
   ' ClearIPv6Addresses/ipv6Addresses and ClearIPv6DefaultGateways/EnumNicIPv6Gateways.
   ClearIPv6Addresses
   ClearIPv6DefaultGateways
   ClearTargetNicDnsServerList
End Function

Function SetStaticIPSettings
   Log "Setting a static " & protocol & " address on NIC with GUID: " & targeNicGUID
   ' The simplIfied format for Netsh command to set static IP settings is :
   ' netsh interface ipv4 set address <connection_name> static <IPv4> <IPv4 mask>
   ' netsh interface ipv6 set address <connection_name> <IPv6>
   Dim netshArgs : netshArgs = "interface " & protocol & " set address "_
                               & Chr(34) & targetNicConnectionName & Chr(34)
   If protocol = IPV4_PROTOCOL Then
      netshArgs = netshArgs & " static " & ipAddress & " " & subnetMaskIPv4
   Else
      ' Need to clear all existing settings since IPv6 netsh set commands don't do it
      ' on opposite to IPv4 netsh set commands.
      ClearIPv6Settings
      netshArgs = netshArgs & " " & ipAddress
      ' Leave the static IPv6 address with default prefix length if not set.
      If subnetPrefixLengthIPv6 <> "" Then
         netshArgs = netshArgs & "/" & subnetPrefixLengthIPv6
      End If
   End If
   Call LaunchNetshCmdWithRetry( _
      netshArgs, _
      DONT_IGNORE_ERROR, _
      SET_STATIC_ADDR_RETRY_COUNT, _
      SET_STATIC_ADDR_RETRY_INTERVAL)

   ' In theory, gateway configuration could be separate from 'set_static' command, but
   ' in practice SRM(or at least SRM UI) doesn't support such separation.
   If Not IsEmpty(gatewayMetricPairList) Then
      Log "Setting static " & protocol & " gateways on NIC with GUID: " & targeNicGUID
      Dim defaultRoute : defaultRoute = "0.0.0.0/0"
      If protocol = IPV6_PROTOCOL Then
         defaultRoute = "::/0"
      End If

      Dim netshCommonArgs : netshCommonArgs =_
         "interface " & protocol & " add route " & defaultRoute _
         & " " & Chr(34) & targetNicConnectionName & Chr(34)

      Dim tokens : tokens = Split(gatewayMetricPairList, ",")
      ' gatewayMetricPairList is comma-separated list of gateway and metric where
      ' the metric is optional, e.g "<gateway1>,<metric1>,<gateway2>,," where for
      ' gateway2 an automatic metric will be used.
      Dim pairIdx
      Dim metric
      Dim tokensUbound : tokensUbound = UBound(tokens)
      For pairIdx = 0 To tokensUbound Step 2
         netshArgs = netshCommonArgs & " nexthop=" & tokens(pairIdx)
         If ((pairIdx + 1) <= tokensUbound) Then
            metric = tokens(pairIdx + 1)
            If metric <> "" Then
               netshArgs = netshArgs & " metric=" & tokens(pairIdx + 1)
            End If
         End If
         Call LaunchNetshCmd(netshArgs, DONT_IGNORE_ERROR)
      Next
   End If
End Function

Sub UpdateDnsServerList
   If IsEmpty(dnsServerList) AND (boolResetDNSServerList = FALSE) Then
      LogVerbose "No DNS servers settings to apply for NIC with GUID: " & targeNicGUID
      Exit Sub
   End If

   ' First clear all existing DNS servers related to the target NIC
   ClearTargetNicDnsServerList

   If boolResetDNSServerList = TRUE Then
      ' Nothing more to do here
      Exit Sub
   End If

   Log "Setting static " & protocol & " DNS servers on NIC with GUID: " & targeNicGUID
   Dim netshArgs : netshArgs =_
      "interface " & protocol & " add dnsserver " &_
      Chr(34) & targetNicConnectionName & Chr(34)

   Dim dnsServer
   Dim dnsServers : dnsServers = Split(dnsServerList, ",")
   For Each dnsServer in dnsServers
      Dim stdOut, exitCode
      Call LaunchCommand(NETSH_CMD, netshArgs & " " & dnsServer, stdOut, exitCode)
      If exitCode = 1 Then
         ' Netsh uses exit code as partial success exit code. For DNS server add command
         ' this means that such DNS server already exist in the NameServer list
         Log "DNS server " & dnsServer & " already in the list. Ignoring error."
      ElseIf exitCode <> 0 Then
          LogVerbose Trim(stdOut)
          NotifyAndExit exitCode
      End If
   Next
End sub

Sub UpdateDomainName
   If IsEmpty(domainName) AND (boolResetDomainName = FALSE) Then
      LogVerbose "No DomainName settings to apply for NIC with GUID: " & targeNicGUID
      Exit Sub
   End If

   If boolResetDomainName = TRUE Then
      domainName = ""
      Log "Clearing the DomainName for NIC with GUID: " & targeNicGUID
   Else
      Log "Setting a DomainName on NIC with GUID: " & targeNicGUID
   End If

   ' Netsh has no command to set DomainName.
   ' Rely on direct registry modification as an alternative.
   Dim regPath
   regPath = REG_KEY_TCPIP_INTERFACE & "\"  & targeNicGUID & "\" & "Domain"
   UpdateExistingRegistryValue regPath, domainName, "REG_SZ"
End Sub

Sub UpdateNetBiosMode
   If IsEmpty(netBiosModeIPv4) Then
      LogVerbose "No NetBiosMode settings to apply for NIC with GUID: " & targeNicGUID
      Exit Sub
   End If

   Log "Setting NetBiosMode to '" & netBiosModeIPv4 & "' on NIC with GUID: " & targeNicGUID
   ' Netsh has no command to set NetBiosMode.
   ' Rely on direct registry modIfication
   Dim regPath
   regPath = REG_KEY_NETBT_INTERFACE & "\Tcpip_" & targeNicGUID & "\" & "NetbiosOptions"
   UpdateExistingRegistryValue regPath, netBiosModeIPv4, "REG_DWORD"
End Sub

Sub ClearWINSServerList
   Log "Deleting all WINS servers configured on NIC with GUID: " & targeNicGUID
   Dim netshArgs : netshArgs = "interface ipv4 delete winsserver "_
                                & Chr(34) & targetNicConnectionName & Chr(34) & " all"
   Call LaunchNetshCmd(netshArgs, DONT_IGNORE_ERROR)
End Sub

Sub UpdateWINSServerList
   If IsEmpty(winsServerList) AND (boolResetWINSServerList = FALSE) Then
      LogVerbose "No WINS server settings to apply"
      Exit Sub
   End If

   If boolResetWINSServerList = TRUE Then
      ClearWINSServerList
      Exit Sub
   End If

   Log "Setting WINS server list :'" & winsServerList & "' on NIC with GUID: " & targeNicGUID
   Dim netshCommonArgs : netshCommonArgs = "interface ipv4 add winsserver "_
                                           & Chr(34) & targetNicConnectionName & Chr(34)
   Dim winsServer
   Dim winsServers : winsServers = Split(winsServerList, ",")
   For Each winsServer in winsServers
      Dim netshArgs : netshArgs = netshCommonArgs & " " & winsServer
      Call LaunchNetshCmd(netshArgs, IGNORE_ERROR)
   Next
End Sub

Sub UpdateDNSSuffixSearchList
   If IsEmpty(dnsSuffixList) AND (boolResetDNSSuffixList = FALSE) Then
      LogVerbose "No DNS Suffix settings to apply"
      Exit Sub
   End If

   If boolResetDNSSuffixList = TRUE Then
      Log "Reset DNS suffix search order list for all NICs "
      dnsSuffixList = ""
   Else
      Log "Setting DNS suffix search order list '" & dnsSuffixList & "' for all NICs "
   End If

   ' Netsh has no command to set or to change the domain suffix search list.
   ' Rely on direct registry modIfication without checking for reg key existence.
   Dim regPath
   regPath = REG_KEY_TCPIP & "\" & "SearchList"
   WriteRegistryValue regPath, dnsSuffixList, "REG_SZ"
End Sub

' Updates a value in the Registry. Returns an error code, 0 on success
Function UpdateExistingRegistryValue(strRegPath, strNewValue, ValType)
   Dim WshShell, curValue, errcode
   Set WshShell = WScript.CreateObject("WScript.Shell")
   On Error Resume Next

   curValue = WshShell.RegRead(strRegPath)
   errcode = err.number
   If errcode <> 0 Then
      Log "ERROR: Can't locate a Registry value at " & strRegPath
   Else
      If curValue <> strNewValue Then
         errcode = WriteRegistryValue(strRegPath, strNewValue, ValType)
      End If
   End If
   WshShell = nothing
   UpdateExistingRegistryValue = errcode
End Function

' Write a value in the Registry. Returns an error code, 0 on success
Function WriteRegistryValue(strRegPath, strNewValue, ValType)
   Dim WshShell, errcode
   Set WshShell = WScript.CreateObject("WScript.Shell")
   On Error Resume Next

   LogVerbose "Setting [" & strRegPath & "] to " & strNewValue
   WshShell.RegWrite strRegPath, strNewValue, ValType
   errcode = err.number
   If errcode <> 0 Then
      Log "ERROR: Can't set a Registry value at " & strRegPath
   End If

   WshShell = nothing
   WriteRegistryValue = errcode
End Function

' Function helper to launch netsh command and returning the output.
'
' Result: The output of the command
'
' Note: stdOut is not localized and could cause problems if it's parsed
'       with word patterns. Localized output is not needed at moment, but
'       this WshShell.Exec("cmd /C chcp 437 > NUL & <myCommand> <myArgs>")
'       should work.
Function LaunchNetshCmdGetOutput(ByRef netshCmdArgs)
   Dim stdOut, exitCode
   LaunchCommand NETSH_CMD, netshCmdArgs, stdOut, exitCode

   If NOT exitCode = 0 Then
      Log "ERROR: Error code '" & exitCode & "' returned by command : "
      Log NETSH_CMD & " " & netshCmdArgs & vbCrLf & stdOut
   End If

   LaunchNetshCmdGetOutput = stdOut
End Function

' Function helper to launch netsh command.
' If onErrorMode = IGNORE_ERROR any errors are ignored.
' If onErrorMode = DONT_IGNORE_ERROR the script execution is terminated with
' the error code returned by the critical netsh command.
'
' Result: The exitCode of the last attempted command execution.
'
Function LaunchNetshCmd(ByRef netshCmdArgs, onErrorMode)
   LaunchNetshCmd = LaunchNetshCmdWithRetry(netshCmdArgs, onErrorMode, 0, 1)
End Function

' Function helper to launch netsh command with retry logic on error.
' If the retryCount is > 0 then a netsh command that fails with exit code <> 0,
' is retried with a sleep prior to the next attempt.'
' If onErrorMode = IGNORE_ERROR then ignore any errors.
' If onErrorMode = DONT_IGNORE_ERROR and all configured retry attempts fail then the
' script execution is terminated with the last error code returned by the netsh
'
' Note: retryAttemptsInterval is in milliseconds.
'
' Result: The exitCode of the last attempted command execution.
Function LaunchNetshCmdWithRetry(ByRef netshCmdArgs, onErrorMode, retryCount, retryIntervalMs)
   Dim currAttempt, stdOut, exitCode
   Dim atemptsCount : atemptsCount = retryCount + 1

   For currAttempt = 1 to atemptsCount
      LaunchCommand NETSH_CMD, netshCmdArgs, stdOut, exitCode
      If exitCode = 0 Then
         ' Successful command execution.
         LogVerbose Trim(stdOut)
         LaunchNetshCmdWithRetry = exitCode
         Exit Function
      End If

      Log "ERROR: Attempt (" & currAttempt & "/" & atemptsCount & ") has failed."
      Log "ERROR: Error code '" & exitCode & "' returned by command : "
      Log NETSH_CMD & " " & netshCmdArgs & vbCrLf & stdOut

      ' Do not sleep after the last failed attempt.
      If currAttempt < atemptsCount Then
         Log "Schedule next attempt (" & currAttempt + 1 & "/" & atemptsCount & ") after '"_
              & retryIntervalMs & "' milliseconds."
         WScript.Sleep retryIntervalMs
      End If
   Next

   If onErrorMode = DONT_IGNORE_ERROR Then
      Log "All retry attempts have failed. Cannot ignore the errors."
      Log "Terminated the customization process"
      NotifyAndExit exitCode
   Else
      Log "All retry attempts have failed. Ignoring the errors."
   End If

   LaunchNetshCmdWithRetry = exitCode
End Function

' Function to launch external binaries.
'
' Note: stdOut is not localized and could cause problems if it's parsed
'       with word patterns. Localized output is not needed at moment, but
'       this WshShell.Exec("cmd /C chcp 437 > NUL & <myCommand> <myArgs>")
'       should work.
Sub LaunchCommand(cmd, cmdArgs, ByRef stdOut, ByRef exitCode)
   Log "Running: " & cmd & " " & cmdArgs
   Dim WshShell
   Set WshShell = WScript.CreateObject("WScript.Shell")

   Dim cmdExec
   Set cmdExec = WshShell.Exec(cmd & " " & cmdArgs)

   Do While cmdExec.Status = 0
      WScript.Sleep 100
   Loop

   stdOut = cmdExec.StdOut.ReadAll
   exitCode = cmdExec.ExitCode
End Sub

' NotIfy the caller and exit
Sub NotifyAndExit(result)
   If result = 0 Then
      Log "Completed successfully"
   Else
      Log "Completed with error; reporting exit code: " & result
   End If
   WScript.Quit result
End Sub

Sub LogVerbose(ByRef line)
   If boolLogOnVerbose = TRUE Then
      Log line
   End If
End Sub

Sub Log(ByRef line)
  Wscript.Echo Now & " " & line
End Sub

'Print script's PrintUsageAndExit
Sub PrintUsageAndExit(ByRef message)
   Log message
   Log "netshIPCust.vbs CLI :" & vbCrLf  _
       & "/Verbose Optional flag to enable verbose logging." & vbCrLf _
       & vbCrLf _
       & "Global network settings: " & vbCrLf _
       & "   /DNSSuffixList:<Comma-separated list of global DNS suffix to add>" & vbCrLf _
       & "   /ResetDNSSuffixList:<Clear the current Domain Name>" & vbCrLf _
       & vbCrLf _
       & "NICs specific settings: " & vbCrLf _
       & "   Mandatory NIC identifiers: " & vbCrLf _
       & "      /MacAddress:<MAC address> " & vbCrLf _
       & "      /Protocol:<ipv4|ipv6> " & vbCrLf _
       & vbCrLf _
       & "   Configuration settings: " & vbCrLf _
       & "      /Command:<enable_dhcp|set_static>:" & vbCrLf _
       &        vbCrLf _
       & "         'enable_dhcp': Enable DHCP for configuring IP settings for the specified NIC." & vbCrLf _
       &        vbCrLf _
       & "         'set_static' : Set static specific network configuration." & vbCrLf _
       & "            IPv4 protocol parameters: " & vbCrLf _
       & "               /IPAddress:<IPv4 address> " & vbCrLf _
       & "               /SubnetMask:<IPv4 subnet mask> " & vbCrLf _
       & "               /GatewayMetricList:<Comma-separated list of IPv4 gateway and metric pairs>" & vbCrLf _
       &           vbCrLf _
       & "            IPv6 protocol parameters: " & vbCrLf _
       & "               /IPAddress:<IPv6 address> " & vbCrLf _
       & "               /SubnetPrefixLength:<IPv6 subnet prefix length> " & vbCrLf _
       & "               /GatewayMetricList:<Comma-separated list of IPv6 gateway and metric pairs." & vbCrLf _
       & "                                   Example:<gateway1>,<metric1>,<gateway2>,," & vbCrLf _
       &        vbCrLf _
       & "      /DomainName:<Domain name to set for this connection>" & vbCrLf _
       & "      /DNSServerList:<Comma-separated list of DNS servers to be used for IP name resolution>" & vbCrLf _
       & "      /NetBIOSMode:<0 via DHCP>|<1 Enable>|<2 Disable> " & vbCrLf _
       & "      /WINSServerList:<Comma-separated list of WINS servers to be used for NetBios name resolution>" & vbCrLf _
       &        vbCrLf _
       & "      /ResetDomainName:<Clear the current Domain Name>" & vbCrLf _
       & "      /ResetDNSServerList:<Clear the current DNS servers configuration>" & vbCrLf _
       & "      /ResetWINSServerList:<Clear the current WINS servers configuration>" & vbCrLf _
       & "Notes: " & vbCrLf _
       & "   All input parameters names and constants are case sensitive." & vbCrLf _
       & "   At least one Configuration must be provided." _
       & vbCrLf
   NotifyAndExit INVALID_ARGUMENTS_ERROR_CODE
End Sub