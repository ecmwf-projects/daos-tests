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

# USAGE: ./field_io/test_wrapper.sh <FDB_HAMMER_SCRIPT_NAME> [options] <SCRIPT_ARGS>

start=`date +%s`

echo "Script launch time: $(date)"

test_name=$1
shift

num_nodes=$SLURM_JOB_NUM_NODES
fabric_provider=tcp
daos=OFF
toc=ON
dummy_daos=OFF
oc_catalogue_kvs=OC_SX
oc_store_arrays=OC_S1

OTHER=()
while [[ $# -gt 0 ]] ; do
key="$1"
case $key in
    -h|--help)
    echo -e "\
Usage:\n\n\
test_wrapper.sh FDB_HAMMER_SCRIPT_NAME [options] SCRIPT_ARGS\n\n\
FDB_HAMMER_SCRIPT_NAME: filename of the script to be submitted\n\n\
SCRIPT_ARGS: arguments to be forwarded to the FDB Hammer test script in the first positional argument\n\n\
Available options:\n\n\
--num-nodes <n>\n\nNumber of client nodes that are assumed to be running this script in parallel in index calculations.\nSLURM_JOB_NUM_NODES by default.\n\n\
-PRV|--provider <provider>\n\nOFI fabric provider to use.\nofi+tcp;ofi_rxm by default.\n\n\
--ock|--oc-catalogue-kvs <OC_SPEC>\n\nspecify a DAOS object class to be used for the FDB Catalogue KV objects.\n\
SX by default.\n\n\
--oca|--oc-store-arrays <OC_SPEC>\n\nspecify a DAOS object class to be used for the FDB Store array objects.\n\
S1 by default.\n\n\
--daos\n\nFlag to enable use of FDB DAOS back-end.\n\n\
--dummy\n\nFlag to enable use of dummy DAOS.\n\n\
-h|--help\n\nshow this menu\
"
    exit 0
    ;;
    --num-nodes)
    num_nodes="$2"
    shift
    shift
    ;;
    -PRV|--provider)
    fabric_provider="$2"
    shift
    shift
    ;;
    --ock|--oc-catalogue-kvs)
    oc_catalogue_kvs="$2"
    shift
    shift
    ;;
    --oca|--oc-store-arrays)
    oc_store_arrays="$2"
    shift
    shift
    ;;
    --daos)
    daos=ON
    toc=OFF
    shift
    ;;
    --posix)
    daos=OFF
    toc=ON
    shift
    ;;
    --dummy)
    dummy_daos=ON
    shift
    ;;
    *)
    OTHER+=( "$1" )
    shift
    ;;
esac
done
set -- "${OTHER[@]}"

forward_args=("${OTHER[@]}")

test_src_dir=$HOME/daos-tests

fdb_src_dir=$HOME/git/fdb-bundle
fdb_build_dir=$HOME/build/fdb-bundle
uuid_root=/usr
daos_tests_include_root=$HOME/install

#export GMON_OUT_PREFIX=gmon.out-

if [ "$SLURM_NODEID" -eq 0 ] ; then
	
	# Compile fdb5

    status=succeeded

    #export LD_LIBRARY_PATH=/home/software/psm2/11.2.228/usr/lib64:/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH
    #export LD_LIBRARY_PATH=/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH	
    #export LD_LIBRARY_PATH=/home/software/libfabric/opx-beta:$LD_LIBRARY_PATH
    #export LD_LIBRARY_PATH=/usr/lib:/usr/lib64/:$LD_LIBRARY_PATH
	#export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/prereq/release/spdk/lib
	module load ninja
	module load cmake
    module load gnu/10.2.0

	mkdir -p $fdb_build_dir
	cd $fdb_build_dir

	export UUID_ROOT=${uuid_root}
	export DAOS_TESTS_INCLUDE_ROOT="${daos_tests_include_root}"

    if [ ! -d "bin" ] ; then

	    cmake -G Ninja $fdb_src_dir \
	    	-DENABLE_LUSTRE=${toc} \
	    	-DENABLE_DAOSFDB=ON -DENABLE_DAOS_ADMIN=${daos} \
	    	-DENABLE_DUMMY_DAOS=${dummy_daos} \
	    	-DENABLE_MEMFS=ON -DENABLE_AEC=OFF
            # -DCMAKE_CXX_FLAGS="-pg -g"
        #[ $? -ne 0 ] && echo "${out}" >&2 && status=failed
        [ $? -ne 0 ] && status=failed

	    ninja
        #[ $? -ne 0 ] && echo "${out}" >&2 && status=failed
        [ $? -ne 0 ] && status=failed

	    #ctest -j 12 -R daos

	    cmake --install . --prefix .
        #[ $? -ne 0 ] && echo "${out}" >&2 && status=failed
        [ $? -ne 0 ] && status=failed

    fi

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
			echo "fdb5 build on $SLURMD_NODENAME ${status}" | ncat $node 12345
			code=$?
			[ "$code" -ne 0 ] && sleep 2
		done
	done
    [[ "${status}" == "failed" ]] && exit 1

else

	echo "WAITING FOR MESSAGE from $SLURMD_NODENAME"
	m=$(ncat -l -p 12345 | bash -c 'read MESSAGE; echo "${SLURMD_NODENAME}": $MESSAGE')
    [[ "${m}" == *"failed"* ]] && exit 1

fi


if [[ "$dummy_daos" == "ON" ]] ; then

	echo "NOTIMP"
	exit 1

#	export PATH="$field_io_shared_dir/bin:$PATH"
#
#	test_dir=/newlust/test_field_io_tmp
#	export DUMMY_DAOS_DATA_ROOT=${test_dir}/tmp_dir_fdb5_dummy_daos

else

#export LD_LIBRARY_PATH=/home/software/psm2/11.2.228/usr/lib64:/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/opx-beta:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/usr/lib:/usr/lib64/:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/prereq/release/spdk/lib
module load ninja
module load cmake
module load gnu/10.2.0

export PATH="$fdb_build_dir/bin:$PATH"

    if [[ "$daos" == "ON" ]] ; then

rm -rf /tmp/daos/log

mkdir -p /tmp/daos/log
mkdir -p /tmp/daos/run/daos_agent
chmod 0755 /tmp/daos/run/daos_agent

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
	echo "Unsupported fabric provider $fabric_provider (test name $test_name)"
	exit 1
fi

export D_LOG_MASK=
export DD_SUBSYST=all
export DD_MASK=all
export DAOS_AGENT_DRPC_DIR=/tmp/daos/run/daos_agent/
export CRT_TIMEOUT=1000
export CRT_CREDIT_EP_CTX=0

daos_agent -o $test_src_dir/ngio/config/daos_agent.yaml -i &

sleep 5

    fi

fi



cd $test_src_dir/ngio

[[ "$test_name" == "test_fdb_hammer" ]] && forward_args+=( "--num-nodes" "$num_nodes" "--node-id" "$SLURM_NODEID" )
[[ "$daos" == "ON" ]] && forward_args+=( "--daos" ) || forward_args+=( "--posix" )

end=`date +%s`

setup_time=$((end-start))

start=`date +%s`
echo "./fdb_hammer/${test_name}.sh ${forward_args[@]}"
./fdb_hammer/${test_name}.sh "${forward_args[@]}"
end=`date +%s`

test_time=$((end-start))

wc_time=$((setup_time+test_time))



if [[ "$dummy_daos" != "ON" ]] ; then

    if [[ "$daos" == "ON" ]] ; then

pkill daos_agent

    fi

fi



echo "Profiling node $SLURM_NODEID - setup wc time: $setup_time"
echo "Profiling node $SLURM_NODEID - $test_name total wc time: $test_time"
echo "Profiling node $SLURM_NODEID - total wc time: $wc_time"
