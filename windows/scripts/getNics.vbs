'/* **********************************************************
' * Copyright 2014 VMware, Inc.  All rights reserved. -- VMware Confidential
' * **********************************************************/

'/**
' * @file getNics.vbs
' *
' * Retrieve VNIC's static IP address info directly from the Registry.
' * This script is to run for VMs with vSphere VM Tools lower than 9.4.10
' * to fix up the VIM info returned for VNICs in disconnected state.
' *
' * @see http://technet.microsoft.com/en-us/library/cc739819(v=ws.10).aspx
' *
' * Output format:
'  AdapterID(GUID),MAC Address,EnableDHCP(0|1),MediaStatus(0|1),IP Address[,IP Address][,*pValue]
' * E.g.
' {5E400E9E-EC4A-4B0B-9EAA-E14110C228F2},00:50:56:C0:00:01,0,1,192.168.112.5/24,*g192.168.112.1/0
' {1992E59E-05E8-4DA0-912A-A13EC913C5AE},00:50:56:C0:00:08,1,0,192.168.146.5/24,192.168.146.6/24
' where *p designates one of the following additional IP parameters:
'  *g - Default Gateway IPv4 address
'  *n - Name server(s)
'  *w - WINS server(s)
' @note Only IPv4 addresses and gateways are currently returned.
' */

Option Explicit

' Allow debug print
Dim verbose : verbose = 0

' GUID-based Adapter Configuration Key
Dim regIPInterfaceConfigKey : regIPInterfaceConfigKey = _
   "SYSTEM\CurrentControlSet\services\Tcpip\Parameters\Interfaces\"
' LAN Connection Configuration Key
Dim regConnectionsConfigKey : regConnectionsConfigKey = _
   "SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}"

Const HKEY_LOCAL_MACHINE = &H80000002

'Execute WMI in local computer
Dim strComputer : strComputer = "."

' WMI Providers
Dim objWMIService, objReg, adapterFilter
Dim winMgmt : winMgmt = "winmgmts:\\" & strComputer
Set objWMIService = GetObject(winMgmt & "\root\cimv2")
Set objReg=GetObject(winMgmt & "\root\default:StdRegProv")

' WQL filter for "VM NIC" adapters
adapterFilter = "where NOT PNPDeviceID LIKE 'ROOT\\%' and Manufacturer != 'Microsoft' "
'adapterFilter = "where MACAddress <> null "

' Non-IP address field escapes in the output
Dim strGatewayPrefix : strGatewayPrefix = "*g"

' main()
Wscript.Echo getNicInfo(adapterFilter)
Wscript.Quit

' Get NIC IP Address Info from the Registry
' @param filter WQL query filter
' @return CSV formatted string with IPv4 address info
Function getNicInfo(filter)
   Dim result : result = ""
   Dim colItems, objItem

   Set colItems = objWMIService.ExecQuery("Select * From Win32_NetworkAdapter " & filter)

   For Each objItem in colItems

      Dim strNetGUID

      DebugPrint "== Adapter: " & objItem.Name

      ' The GUID property is not available on Windows 2003 and below.
      ' Try to enumerate the Registry to find it
      On Error Resume Next
      strNetGUID = objItem.GUID
      If IsEmpty(strNetGUID) OR Len(strNetGUID) = 0 Then
         strNetGUID = lookupNetGuid(objItem.NetConnectionID)
      End If
      DebugPrint "MAC address: " & objItem.MACAddress
      DebugPrint "DeviceID: " & objItem.DeviceID
      DebugPrint "Description: " & objItem.Description
      DebugPrint "GUID: " & strNetGUID
      DebugPrint "ConnID: " & objItem.NetConnectionID
      ' InterfaceIndex is not available on 5.X
      On Error Resume Next
      DebugPrint "InterfaceIndex: " & objItem.InterfaceIndex
      DebugPrint "NetConnectionStatus: " & objItem.NetConnectionStatus
      ' Get params from the Registry
      Dim enableDhcp : enableDhcp = getdAdapterDwordProperty(strNetGUID, "EnableDHCP")
      DebugPrint "EnableDHCP: " & enableDhcp
      If not IsEmpty(strNetGUID) And Len(strNetGUID) <> 0 Then
         Dim ipAddr : ipAddr = getAdapterMultiProperty(strNetGUID, "IPAddress")
         Dim ipNetmask : ipNetMask = getAdapterMultiProperty(strNetGUID, "SubnetMask")
         Dim ipGateway : ipGateway = getAdapterMultiProperty(strNetGUID, "DefaultGateway")
         If not IsEmpty(ipAddr) Then
            Dim canonizedAddr : canonizedAddr = canonizeIpAddress(ipAddr, ipNetmask)
            Dim canonizedGateway : canonizedGateway = canonizeGateway(ipGateway)
            DebugPrint "IP Address: " & canonizedAddr
            ' Accumulate results
            result = result & _
                     strNetGUID & "," & _
                     objItem.MACAddress & "," & _
                     enableDhcp & "," & _
                     getMediaStatus(objItem) & "," & _
                     canonizedAddr
            If not IsEmpty(canonizedGateway) Then
               result = result & canonizedGateway
            End If
            result = result  & vbCRLF
         Else
            DebugPrint "IP Address: NONE"
         End If
      End If
      strNetGUID = ""
    Next
    getNicInfo = result
End Function

' Get media status: 0 for disconnected, 1 for connected
' @note WMI NetConnectStatus: 0 or 7: disconnected, 2: connected
Function getMediaStatus(adapter)
   If adapter.NetConnectionStatus = 2 Then
     GetMediaStatus = 1
   Else
     GetMediaStatus = 0
   End If
End Function

' Get All IP addresses found in the REG_MULTI_SZ string
' @returns a CSV list of adapter properties with IP addresses in the CIDR format
Function canonizeIpAddress(ipAddrArray, ipNetmaskArray)
'   On error resume next
   Dim res, i, n
   res = ""
   n = UBound(ipAddrArray)
   If n > UBound(ipNetmaskArray) Then
      n = UBound(ipNetmaskArray)
   End If
   For i = 0 To n
      If i > 0 Then
         res = res & ","
      End If
      res = res & ipAddrArray(i) & "/" & GetPrefix(ipNetmaskArray(i))
   Next
   canonizeIpAddress = res
End Function

' Get All IP addresses found in the REG_MULTI_SZ string
' @returns a CSV list of IPv4 gatewas prefixed with the gateway escape string
' @note The gateway(s) are returned in the default gateway CIDR syntax (/0).
Function canonizeGateway(ipAddrArray)
'   On error resume next
   Dim res, i, n
   n = UBound(ipAddrArray)
   For i = 0 To n
      res = res & "," & strGatewayPrefix & ipAddrArray(i) & "/0"
   Next
   canonizeGateway = res
End Function

' Get prefix from dotted IPv4 netmask
Function GetPrefix(netMask)
  Dim b : b = Split(netMask, ".")
  If UBound(b) <> 3 Then
    GetPrefix = netMask ' must be IPv6, just use it verbatim
    Exit Function
 End If
 Dim i, j, prefix : prefix = 0
 For i = 0 To 3
   Dim v : v = CInt(b(i))
   prefix = prefix + 8
   If v < 255 Then
      For j = 0 To 7
         If v Mod 2 = 0 Then
            prefix = prefix - 1
            v = v \ 2
         Else
            Exit For
         End If
      Next
      Exit For
   End If
  Next
  GetPrefix = prefix
End Function

' Read adapter's multistring property from the Registry.
' @returns the value string array or empty object
Function getAdapterMultiProperty(interfaceId, propName)
  Dim Values, regPath, ret, s
  regPath = regIPInterfaceConfigKey & interfaceId
  ret  = objReg.GetMultiStringValue(HKEY_LOCAL_MACHINE,  regPath, propName, Values)
  If (ret = 0) And (Err.Number = 0) Then
      getAdapterMultiProperty = Values
   Else
       DebugPrint "GetMultiStringValue failed. Error = " & Err.Number
   End If
End Function

' Read adapter's DWORD property from the Registry.
' @returns the value string or empty object
Function getdAdapterDwordProperty(interfaceId, propName)
  On error resume next
  Dim regPath, ret, val
  regPath = regIPInterfaceConfigKey & interfaceId
  ret = objReg.GetDWORDValue(HKEY_LOCAL_MACHINE,  regPath, propName, val)
  If (ret = 0) And (Err.Number = 0) Then
   getdAdapterDwordProperty = val
  Else
    DebugPrint "GetDWORDValue failed. Error = " & Err.Number
  End If
End Function

' Lookup Adapter's GUID by its connection name. Required in Windows 5.X only.
'
' @param connectionId Connection ID such as "Local Area Nerwork 2"
' @return matching adapter's GUID
Function lookupNetGuid(connectionId)
   Dim connNodes, node, name, ret
   On error resume next
   objReg.EnumKey HKEY_LOCAL_MACHINE, regConnectionsConfigKey, connNodes
   If IsEmpty(connNodes) Then
      Exit Function
   End If
   For Each node In connNodes
       Dim regPath : regPath = regConnectionsConfigKey & "\" & node & "\Connection"
       DebugPrint "Checking: " & regPath
       If Left(node, 1) = "{" Then 'GUID like
          On error resume next
          ret = objReg.GetStringValue(HKEY_LOCAL_MACHINE, regPath, "Name", name)
          If (ret = 0) And (Err.Number = 0) Then
            If (name = connectionId) Then
               lookupNetGuid = node
               Exit For
            End If
          Else
            DebugPrint "GetStringValue failed for " & regPath & "; Error = " & Err.Number
          End If
       End If
   Next
End Function

Sub DebugPrint(s)
 If verbose <> 0 Then
   Wscript.Echo "# " & s
 End If
End Sub

