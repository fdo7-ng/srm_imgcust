# !/bin/sh
# vim:et:ft=sh:sts=2:sw=2

CONFIG_FILE_PATH=$1

DIRNAME=/usr/bin/dirname
GREP=/bin/grep
LOCALCLI=/bin/localcli
PYTHON=/bin/python
UNAME=/bin/uname

PARAMS="-m imc.runner"

DEPLOYPKG_RP_GROUP=host/vim/vimuser/deploypkg
ESXCLI_INT=/usr/lib/vmware/esxcli/int
RESOURCE_POOL_CMD="/bin/sh ++group=$DEPLOYPKG_RP_GROUP -c"
RP_SIZE=64 # Size specified in MB

GOSC_DIR=`${DIRNAME} $0`
OS_KERNEL=`${UNAME} -s`
GOSC_PYTHON_DIR="$GOSC_DIR/imc-python"
echo "GOSC_DIR: $GOSC_DIR"
echo "OS_KERNEL: $OS_KERNEL"

setupResourcePool() {
   ${LOCALCLI} --plugin-dir ${ESXCLI_INT} sched group list | \
   ${GREP} "^$DEPLOYPKG_RP_GROUP$" > /dev/null 2>&1 || \
   ${LOCALCLI} --plugin-dir ${ESXCLI_INT} sched group \
      add -g host/vim/vimuser -n deploypkg || exit 1
   ${LOCALCLI} --plugin-dir ${ESXCLI_INT} sched group \
      setmemconfig -g ${DEPLOYPKG_RP_GROUP} \
      -m ${RP_SIZE} -i ${RP_SIZE} -l ${RP_SIZE} -u mb || exit 1
}

removeResourcePool() {
   ${LOCALCLI} --plugin-dir ${ESXCLI_INT} sched group \
      delete -g ${DEPLOYPKG_RP_GROUP}
}

if [ "$OS_KERNEL" = "VMkernel" ]; then
# TODO: Finalize the directory structure for imc-python and change accordingly
  setupResourcePool
  eval "${RESOURCE_POOL_CMD}" +\
       "'PYTHONPATH=${GOSC_PYTHON_DIR} ${PYTHON} ${PARAMS} ${CONFIG_FILE_PATH}'"
  exitCode=$?
  removeResourcePool
elif [ -e /usr/bin/perl ]; then
  eval "/usr/bin/perl -I${GOSC_DIR} ${GOSC_DIR}/Customize.pl ${CONFIG_FILE_PATH}"
  exitCode=$?
else
  echo "ERROR: Guest Customization is not supported on systems not having Perl installed."
  exit 1
fi

echo "Exiting with code $exitCode"
exit $exitCode
