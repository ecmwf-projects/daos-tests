#!/bin/env bash

# Copyright 2022 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation nor
# does it submit to any jurisdiction.


# USAGE: ./ior/test_wrapper.sh <N_NODES> <DAOS_TEST_SCRIPT_NAME> <IOR_API> <FABRIC_PROVIDER> <CLIENTS_PER_NODE> <REPS_PER_CLIENT> <WRITE_OR_READ> <REP_MODE> <UNIQUE> <UNIQUE_REP> <KEEP> <SLEEP> <OC> <POOL> <CONT>

n_nodes=$1
test_name=$2
ior_api=$3
fabric_provider=$4
clients_per_node=$5
reps_per_client=$6
write_or_read=$7  # either "write" or "read"
rep_mode="${8:-rep}"  # either "rep" or "segment"
unique=$9
unique_rep=${10}
keep=${11}
sleep=${12}
oc="${13:-SX}"
osize="${14:-1MiB}"
pool=${15}
cont=${16}

ior_src=$HOME/ior
ior_shared_dir=$HOME/local/ior

mpi_params="-envall"
ior_params=
with_mpiio=

if [[ "$ior_api" == "DAOS" ]] || [[ "$ior_api" == "DFS" ]] ; then
	module load mpich
	module load packages-oneapi
	module load compiler
	[[ "$ior_api" == "DAOS" ]] && \
		ior_params="-o file_name --daos.pool $pool --daos.cont $cont --daos.oclass $oc"
	[[ "$ior_api" == "DFS" ]] && \
		ior_params="-o /file_name --dfs.pool $pool --dfs.cont $cont --dfs.oclass $oc --dfs.dir_oclass $oc"
elif [[ "$ior_api" == "MPIIO" ]] ; then
	module load mpich
	module load packages-oneapi
	module load compiler
	ior_params="-o daos://file_name"
	with_mpiio="--with-mpiio=yes"
	export DAOS_POOL=$pool
	export DAOS_CONT=$cont
	export IOR_HINT__MPI__romio_daos_obj_class=$oc
	export DAOS_BYPASS_DUNS=1
	export I_MPI_OFI_LIBRARY_INTERNAL=0
else
	echo "Unsupported IOR API" && exit 1
fi

if [ $SLURM_NODEID -eq 0 ] ; then

	ior_build_dir=$ior_shared_dir/${ior_api}

	if [ ! -d $ior_build_dir ] ; then
		cd $ior_src
	
		# these modifications are intended for IOR 3.3.0rc1 to work with DAOS 1.2
		grep -r -l "daos_pool_connect" * | xargs sed -i -e 's/svcl, //g'
		grep -r -l "daos_pool_connect" * | xargs sed -i -e 's/o.svcl == NULL || //g'
		grep -r -l "daos_pool_connect" * | xargs sed -i -e 's/.*svcl.*//g'

		# these modifications are intended for IOR 3.3.0rc1 and 3.3.0 to work with DAOS 2.0
		grep -r -l "daos_array_generate_id" * | xargs sed -i -e 's/daos_array_generate_id(.*/daos_array_generate_oid(coh, oid, true, objectClass, 0, 0);/g'
	
		make distclean
		./bootstrap
		./configure $with_mpiio --with-cart=/usr --with-daos=/usr --prefix=$ior_build_dir
		make
		make install
	fi

fi

if [ "$fabric_provider" == "sockets" ] ; then
	export CRT_PHY_ADDR_STR="ofi+sockets"
	export FI_SOCKETS_MAX_CONN_RETRY=1
	export FI_SOCKETS_CONN_TIMEOUT=2000
elif [ "$fabric_provider" == "tcp" ] ; then
    #export FI_TCP_IFACE=ib0
    export FI_TCP_BIND_BEFORE_CONNECT=1
    export CRT_PHY_ADDR_STR="ofi+tcp;ofi_rxm"
    export FI_PROVIDER=tcp

    export FI_TCP_MAX_CONN_RETRY=1
    export FI_TCP_CONN_TIMEOUT=2000
elif [ "$fabric_provider" == "psm2" ] ; then
	export CRT_PHY_ADDR_STR="ofi+psm2"
else
	echo "Unsupported fabric provider $fabric_provider"
	exit 1
fi

export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH

module load libfabric/latest
export LD_LIBRARY_PATH=/home/software/psm2/11.2.228/usr/lib64:/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH

export D_LOG_MASK=
export DD_SUBSYST=all
export DD_MASK=all
export DAOS_AGENT_DRPC_DIR=/tmp/daos/run/daos_agent/
export CRT_TIMEOUT=1000
export CRT_CREDIT_EP_CTX=0

test_src_dir=$HOME/daos-tests

rm -rf /tmp/daos/log

mkdir -p /tmp/daos/log
mkdir -p /tmp/daos/run/daos_agent
chmod 0755 /tmp/daos/run/daos_agent

daos_agent -o $test_src_dir/ngio/config/daos_agent.yaml -i &

sleep 5

if [ $SLURM_NODEID -eq 0 ] ; then

	rw_params=
	[[ "$write_or_read" == "write" ]] && rw_params="-w"
	[[ "$write_or_read" == "read" ]] && rw_params="-r"

	unique_rep_param=
	[[ "$unique_rep" == "true" ]] && unique_rep_param="-m"

	rep_params=
	[[ "$rep_mode" == "rep" ]] && rep_params="-s 1 -i $reps_per_client $unique_rep_param"
	[[ "$rep_mode" == "segment" ]] && rep_params="-s $reps_per_client"

	unique_param=
	[[ "$unique" == "true" ]] && unique_param="-F"	

	keep_param=
	[[ "$keep" == "true" ]] && keep_param="-k"

	# if willing to bind clients to a specific socket, e.g. --bind-to ib0
	mpirun --bind-to socket -n $(($clients_per_node * $n_nodes)) $mpi_params \
		$ior_build_dir/bin/ior \
		-a $ior_api $rw_params -t ${osize%MiB*}m -b ${osize%MiB*}m $rep_params \
		$ior_params $unique_param $keep_param -d $sleep \
		-E -C -e -v -v -v

	nodelist=($(python - "$SLURM_NODELIST" <<EOF
import sys
import re

if len(sys.argv) != 2:
  raise Exception("Expected 1 argument.")

s = sys.argv[1]

#s = "compute-b24-[1-3,5-9],compute-b22-1,compute-b23-[3],compute-b25-[1,4,8]"

blocks = re.findall(r'[^,\[]+(?:\[[^\]]*\])?', s)
r = []
for b in blocks:
  if '[' in b:
    parts = b.split('[')
    ranges = parts[1].replace(']', '').split(',')
    for i in ranges:
      if '-' in i:
        limits = i.split('-')
        for j in range(int(limits[0]), int(limits[1]) + 1):
          print(parts[0] + "%02d" % (j,))
      else:
        print(parts[0] + i)
  else:
    print(b)
EOF
))

	for node in "${nodelist[@]}" ; do
		[[ "$node" == "$SLURMD_NODENAME" ]] && continue
		code=1
		while [ "$code" -ne 0 ] ; do
			echo "SENDING MESSAGE from $SLURMD_NODENAME to $node"
			echo "IOR build and launch on $SLURMD_NODENAME ended" | ncat $node 12345
			code=$?
			[ "$code" -ne 0 ] && sleep 2
		done
	done

else

	echo "WAITING FOR MESSAGE from $SLURMD_NODENAME"
	ncat -l -p 12345 | bash -c 'read MESSAGE; echo "${SLURMD_NODENAME}": $MESSAGE'

fi

pkill daos_agent
