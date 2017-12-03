#!/bin/bash -e

/go-cloud-debug -sourcecontext=${CDBG_SOURCECONTEXT} -appmodule=${CDBG_APPNAME} -appversion=${CDBG_APPVERSION} -serviceaccountfile ${CDBG_SERVICEFILE} -- ${CDBG_PROGRAM} $@
