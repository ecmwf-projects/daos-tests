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

function create_pool_cont {

local posix_pool=$1
local on_lustre=$2
local servers=$3
local test_name=${4:-field_io}  # either kronos or fdb_hammer or field_io

local code=0

if [[ "$on_lustre" == "true" ]] ; then

    local pool_param="--pool newlust."
    #local pool_param="--ost "
    [[ "$servers" == "single_server" ]] && pool_param+="1nodes"
    [[ "$servers" == "dual_server" ]] && pool_param+="2nodes"
    [[ "$servers" == "quad_server" ]] && pool_param+="4nodes"
    [[ "$servers" == "hexa_server" ]] && echo "Not implemented" && return 1
    [[ "$servers" == "octa_server" ]] && pool_param+="8nodes"
    #[[ "$servers" == "ten_server" ]] && echo "Not implemented" && return 1
    [[ "$servers" == "ten_server" ]] && pool_param+="10nodes"
    #[[ "$servers" == "twelve_server" ]] && echo "Not implemented" && return 1
    [[ "$servers" == "twelve_server" ]] && pool_param=
    #[[ "$servers" == "fourteen_server" ]] && echo "Not implemented" && return 1
    [[ "$servers" == "fourteen_server" ]] && pool_param+="14nodes"
    #[[ "$servers" == "sixteen_server" ]] && echo "Not implemented" && return 1
    [[ "$servers" == "sixteen_server" ]] && pool_param=

    local test_dir=/newlust/test_${test_name}_tmp

    mkdir -p ${test_dir}
    lfs setstripe -c -1 ${pool_param} ${test_dir}
    code=$?

    # for both dummy daos field I/O and fdb-hammer on posix we create a pool ID
    local rand1=$(od -An -N3 -i /dev/random)
    local rand2=$(od -An -N3 -i /dev/random)
    rand1=$(printf "%08d" $rand1)
    rand2=$(printf "%012d" $rand2)
    local pool_id="${rand1}-0000-0000-0000-${rand2}"

    echo "POOL: $pool_id"

    # for dummy daos field I/O:
    if [[ "$test_name" == "field_io" ]] ; then
        local cont_id="00000000-0000-0000-0000-000000000001"

        mkdir -p ${DUMMY_DAOS_DATA_ROOT}/${pool_id}/${cont_id}
        code=$?

        echo "CONT: $cont_id"

        DUMMY_DAOS_DATA_ROOT=${test_dir}/tmp_dir_fdb5_dummy_daos
    fi

else

cont_create_args=
[[ "$posix_pool" == "true" ]] && cont_create_args="--type=POSIX"

cat > cpool.sh <<EOF

#export LD_LIBRARY_PATH=/home/software/psm2/11.2.228/usr/lib64:/home/software/libfabric/latest/lib:\$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/latest/lib:\$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/opx-beta:\$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/usr/lib:/usr/lib64/:\$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/prereq/release/spdk/lib

#export CRT_PHY_ADDR_STR="ofi+sockets"
#export FI_SOCKETS_MAX_CONN_RETRY=1
#export FI_SOCKETS_CONN_TIMEOUT=2000

#export FI_TCP_IFACE=ib0
export FI_TCP_BIND_BEFORE_CONNECT=1
export CRT_PHY_ADDR_STR="ofi+tcp;ofi_rxm"
export FI_PROVIDER=tcp
export FI_TCP_MAX_CONN_RETRY=1
export FI_TCP_CONN_TIMEOUT=2000

#export CRT_PHY_ADDR_STR="ofi+psm2"
#export FI_PSM_CONN_TIMEOUT=2000

export OFI_INTERFACE=ib0
export D_LOG_MASK=
export DD_SUBSYST=all
export DD_MASK=all
export DAOS_AGENT_DRPC_DIR=/tmp/daos/run/daos_agent/
#export CRT_TIMEOUT=30
export CRT_TIMEOUT=1000
export CRT_CREDIT_EP_CTX=0
#export CRT_CTX_SHARE_ADDR=1

export D_LOG_FILE=/tmp/daos/log/client.log

mkdir -p /tmp/daos/log
mkdir -p /tmp/daos/run/daos_agent
chmod 0755 /tmp/daos/run/daos_agent

daos_agent -o /tmp/daos-tests/ngio/config/daos_agent.yaml -i &

daos_src_dir=/tmp/daos-src

test_src_dir=/tmp/daos-tests

out=\$(dmg pool list -i -o /tmp/daos-tests/ngio/config/daos_control.yaml)

npools=\$(echo "\$out" | tail -n +3 | wc -l)

[ \$npools -ne 0 ] && echo "Unexpectedly found existing pools." && pkill daos_agent && exit 1

group=\$(id -g -n)
user=\$(id -u -n)
out=\$(dmg pool create testpool -s 1350G -g \$group -u \$user -i -o \${test_src_dir}/ngio/config/daos_control.yaml)
code=\$?
[ \$code -ne 0 ] && pkill daos_agent && exit 1
out2=\$(echo "\$out" | grep "UUID")
export pool_id=\$(echo "\$out2" | grep "UUID" | awk '{print \$3}')

out=\$(daos container create testpool testcont $cont_create_args)
code=\$?
[ \$code -ne 0 ] && pkill daos_agent && exit 1
export cont_id=\$(echo "\$out" | grep "UUID" | awk '{print \$4}')

pkill daos_agent

echo "CONT_CREATE_ARGS: $cont_create_args"
echo "POOL: \$pool_id"
echo "CONT: \$cont_id"

EOF

ssh nextgenio-cn01 '/bin/env bash -s' < cpool.sh
code=$?

rm cpool.sh

fi

return $code

}

function destroy_pool_cont {

local on_lustre=$1
local test_name=${2:-field_io}

local code=0

if [[ "$on_lustre" == "true" ]] ; then

    local test_dir=/newlust/test_${test_name}_tmp

    if [[ "$test_name" == "field_io" ]] ; then
        DUMMY_DAOS_DATA_ROOT=${test_dir}/tmp_dir_fdb5_dummy_daos
        find ${DUMMY_DAOS_DATA_ROOT} -maxdepth 2 -mindepth 2 -print0 | xargs -0 -P 48 rm -rf
    fi

    rm -rf ${test_dir}
    code=$?

else

cat > dpool.sh <<'EOF'

#export LD_LIBRARY_PATH=/home/software/psm2/11.2.228/usr/lib64:/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/latest/lib:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/home/software/libfabric/opx-beta:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/usr/lib:/usr/lib64/:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/prereq/release/spdk/lib

#export CRT_PHY_ADDR_STR="ofi+sockets"
#export FI_SOCKETS_MAX_CONN_RETRY=1
#export FI_SOCKETS_CONN_TIMEOUT=2000

#export FI_TCP_IFACE=ib0
export FI_TCP_BIND_BEFORE_CONNECT=1
#export FI_PROGRESS_MANUAL=0
#export FI_OFI_RXM_USE_SRX=0
export CRT_PHY_ADDR_STR="ofi+tcp;ofi_rxm"
export FI_PROVIDER=tcp
#export CRT_PHY_ADDR_STR="ofi+tcp;ofi_rxm"
##export FI_PROVIDER="tcp"
export FI_TCP_MAX_CONN_RETRY=1
export FI_TCP_CONN_TIMEOUT=2000

#export CRT_PHY_ADDR_STR="ofi+psm2"

export OFI_INTERFACE=ib0
export D_LOG_MASK=
export DD_SUBSYST=all
export DD_MASK=all
export DAOS_AGENT_DRPC_DIR=/tmp/daos/run/daos_agent/
#export CRT_TIMEOUT=30
export CRT_TIMEOUT=1000
export CRT_CREDIT_EP_CTX=0
#export CRT_CTX_SHARE_ADDR=1

export D_LOG_FILE=/tmp/daos/log/client.log

mkdir -p /tmp/daos/log
mkdir -p /tmp/daos/run/daos_agent
chmod 0755 /tmp/daos/run/daos_agent

daos_agent -o /tmp/daos-tests/ngio/config/daos_agent.yaml -i &

daos_src_dir=/tmp/daos-src

test_src_dir=/tmp/daos-tests

out=$(dmg pool list -i -o /tmp/daos-tests/ngio/config/daos_control.yaml)

npools=$(echo "$out" | tail -n +3 | wc -l)

[ $npools -ne 1 ] && echo "Unexpectedly found $npools pools." && pkill daos_agent && exit 1

echo "$out" | tail -n +3 | awk '{print $1}' | \
	xargs -I {} dmg pool destroy {} -f -r -i -o /tmp/daos-tests/ngio/config/daos_control.yaml
code=$?

pkill daos_agent

exit $code

EOF

ssh nextgenio-cn01 '/bin/env bash -s' < dpool.sh
code=$?

rm dpool.sh

fi

return $code

}
