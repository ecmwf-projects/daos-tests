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

ready=0
#service_ready=
while [ $ready -eq 0 ] ; do
  echo "Waiting for Ceph to be ready..."
  #status=$(sudo timeout 3 ceph -s)
  #echo "${status}" | grep -q -e 'health: HEALTH_OK'
  #service_ready=$?
  #[ $service_ready -eq 0 ] && ready=1 && continue
  res=$(sudo timeout 3 ceph -s)
  [ $? -eq 0 ] && ready=1 && continue
  sleep 5
done

cd $HOME/daos-tests/google/ceph
test_name=patternA
servers="sixteen_server"
osizes=("1MiB")
posix_cont="false"
dummy_daos="false"
ocvecs=( "OC_S1 OC_S1" )
#C=(1 2 4 8 12)
#C=(1 8 16 32)
C=(32 16 8 1)
#C=(48 32 16 8 1)
#C=(32)
REP=3
WR=10000
sleep=0
source pool_helpers.sh
tname=${test_name}
for osize in "${osizes[@]}" ; do
for ocvec in "${ocvecs[@]}" ; do
ocname=$(echo ${ocvec} | tr ' ' '_')
ocvec=($(echo "$ocvec"))
for c in "${C[@]}" ; do
#[ $c -eq 1 ] && N=(20)
#[ $c -eq 1 ] && N=(16)
#[ $c -eq 1 ] && N=(16 32 48 64)
[ $c -eq 1 ] && N=(1 4 8 12 16 24 32)
#[ $c -eq 2 ] && N=(1 8 16 32 48)
[ $c -eq 2 ] && N=(1 4 8 12 16 24 32)
#[ $c -eq 2 ] && N=(32)
[ $c -eq 4 ] && N=(16 32)
#[ $c -eq 4 ] && N=(16)
#[ $c -eq 4 ] && N=(1 8 16 32 48)
#[ $c -eq 4 ] && N=(1 4 8 12 16 24 32)
#[ $c -eq 8 ] && N=(16 32)
#[ $c -eq 8 ] && N=(1 8 16 32 48)
[ $c -eq 8 ] && N=(1 4 8 12 16 24 32)
[ $c -eq 10 ] && N=(16 32 48 64)
#[ $c -eq 12 ] && N=(1 8 16 32 48)
[ $c -eq 12 ] && N=(1 4 8 12 16 24 32)
[ $c -eq 14 ] && N=(16 32 48 64)
[ $c -eq 16 ] && N=(1 4 8 12 16 24 32)
#[ $c -eq 16 ] && N=(16)
#[ $c -eq 16 ] && N=(16 32 48 64)
[ $c -eq 18 ] && N=(16 32 48 64)
[ $c -eq 20 ] && N=(16 32 48 64)
[ $c -eq 24 ] && N=(16 32 48 64)
#[ $c -eq 32 ] && N=(1 4 8 12 16 24 32)
#[ $c -eq 32 ] && N=(16)
[ $c -eq 32 ] && N=(24 16 12 8 4 1)
#[ $c -eq 48 ] && N=(16 32)
[ $c -eq 48 ] && N=(16 12 8 4 1)
for n in "${N[@]}" ; do
for r in `seq 1 $REP` ; do

    echo "### Pattern A, ${ocvec[@]}, ${osize}, C=$c, N=$n, rep=$r ###"

    nnodes=$c
    nodes_ready=0
    while [ $nodes_ready -eq 0 ] ; do
       res=$(srun -N $nnodes hostname | wc -l)
       [ $res -eq $nnodes ] && nodes_ready=1 || sleep 10
    done

    sleep 5

    out=$(create_pool_cont $posix_cont $dummy_daos $servers fdb_hammer)
    code=$?
    [ $code -ne 0 ] && echo "create_pool_cont failed" && echo "${out}" && return
    pool=$(echo "$out" | grep "POOL: " | awk '{print $2}')
    cont_id=$(echo "$out" | grep "CONT: " | awk '{print $2}')
    echo "Pool is: $pool"
    echo "Cont is: $cont_id"

    sleep 5

    out=$(./fdb_hammer/submitter.sh $c test_fdb_hammer -PRV tcp \
        --osize ${osize} \
        --ock ${ocvec[0]} --oca ${ocvec[1]} --rados \
        $n $WR 0 -P $pool -C $cont_id \
	--nsteps 100 --nparams 10)
#        --nmembers= --ndatabases= --nlevels=
    echo "$out"
    jid=$(echo "$out" | grep -e "Submitted batch job" | awk '{print $4}')
    while squeue | grep -q -e "^ *$jid .* ${USER::8} " ; do sleep 5 && echo "Sleeping..."; done

    sleep 5

    ready=0
    service_ready=
    while [ $ready -eq 0 ] ; do
      echo "Waiting for Ceph to be ready..."
      status=$(sudo ceph -s)
      echo "${status}" | tr '\r\n' '_' | grep -q -e 'health: HEALTH_WARN_ *1 pool(s).*_ *1 pool(s).*_ *_  services:' -e 'health: HEALTH_OK'
      service_ready=$?
      [ $service_ready -eq 0 ] && ready=1 && continue
      sleep 5
    done

    nnodes=$c
    nodes_ready=0
    while [ $nodes_ready -eq 0 ] ; do
       res=$(srun -N $nnodes hostname | wc -l)
       [ $res -eq $nnodes ] && nodes_ready=1 || sleep 10
    done

    sleep 5

    out=$(./fdb_hammer/submitter.sh $c test_fdb_hammer -PRV tcp \
        --osize ${osize} \
        --ock ${ocvec[0]} --oca ${ocvec[1]} --rados \
        $n 0 $WR -P $pool -C $cont_id \
	--nsteps 100 --nparams 10)
#        --nmembers= --ndatabases= --nlevels=
    echo "$out"
    jid=$(echo "$out" | grep -e "Submitted batch job" | awk '{print $4}')
    while squeue | grep -q -e "^ *$jid .* ${USER::8} " ; do sleep 5 && echo "Sleeping..."; done

    sleep 5

#    out=$(./fdb_hammer/submitter.sh $c test_fdb_hammer -PRV tcp \
#        --osize ${osize} \
#        --ock ${ocvec[0]} --oca ${ocvec[1]} --rados \
#        $n 0 $WR -P $pool -C $cont_id \
#        --nsteps 100 --nparams 10 -L)
##        --nmembers= --ndatabases= --nlevels=
#    echo "$out"
#    jid=$(echo "$out" | grep -e "Submitted batch job" | awk '{print $4}')
#    while squeue | grep -q -e "^ *$jid .* ${USER::8} " ; do sleep 5 && echo "Sleeping..."; done

    out=$(destroy_pool_cont $dummy_daos $servers fdb_hammer)
    code=$?
    [ $code -ne 0 ] && echo "destroy_pool_cont failed for N=$n" && return

    sleep 10

done
done
done
res_dir=runs/${servers}/fdb_hammer/${tname}/${ocname}/${osize}
mkdir -p $res_dir
mv runs/fdb_hammer_* ${res_dir}/
done
done