::/* **********************************************************
:: * Copyright 2009-2011 VMware, Inc.  All rights reserved. -- VMware Confidential
:: * **********************************************************/
:: *
:: * @file
:: *
:: * Batch script to enumerate IPv6 addresses and gateways for a given NIC.
:: */
::
:: Usage
::  enumIPv6.bat [address "<Connection Id>"] | [gateway <Interface Index>]
::
:: Example input
::  enumIPv6.bat address "Local Area Connection"
::  enumIPv6.bat gateway 11

@echo off

chcp 437 > NUL

::Enumerate IPv6 addresses for given Network connection Id
if "%1" == "address" for /F "usebackq tokens=2" %%i in (`"%windir%\system32\netsh.exe int ipv6 show addresses %2 | %windir%\system32\find.exe "Parameters""`) do echo %%i

::Enumerate IPv6 gateways for given Network interface index
if "%1" == "gateway" for /F "usebackq tokens=5,6" %%i in (`"%windir%\system32\netsh.exe int ipv6 show route | %windir%\system32\find.exe "::/0""`) do if %%i == %2 echo %%j

::Ignore any errors and set exit code = 0
exit /B 0
