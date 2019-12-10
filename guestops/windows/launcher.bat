:: Copyright 2015 VMware, Inc.  All rights reserved. -- VMware Confidential
::
:: DeployPkg launcher script. It's needed since the deployPkg plugin can invoke
:: from the deploy folder only.
::
@%windir%\system32\%*
@exit /B ERRORLEVEL