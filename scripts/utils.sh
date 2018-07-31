#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

# This is a collection of bash functions used by different scripts

ORDERER1_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/kukkiwon.com/orderers/orderer1.kukkiwon.com/msp/tlscacerts/tlsca.kukkiwon.com-cert.pem
ORDERER2_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/kukkiwon.com/orderers/orderer2.kukkiwon.com/msp/tlscacerts/tlsca.kukkiwon.com-cert.pem
PEER0_ORG1_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/org1.kukkiwon.com/peers/peer0.org1.kukkiwon.com/tls/ca.crt
PEER0_ORG2_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/org2.kukkiwon.com/peers/peer0.org2.kukkiwon.com/tls/ca.crt

# verify the result of the end-to-end test
verifyResult() {
  if [ $1 -ne 0 ]; then # 첫번째 Argument 값이 0인지 유무
    echo "!!!!!!!!!!!!!!! "$2" !!!!!!!!!!!!!!!!"
    echo "========= ERROR !!! FAILED to execute End-2-End Scenario ==========="
    echo
    exit 1
  fi
}

# Set OrdererOrg.Admin globals
setOrdererGlobals() {
  CORE_PEER_LOCALMSPID="OrdererMSP"
  CORE_PEER_TLS_ROOTCERT_FILE=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/kukkiwon.com/orderers/orderer1.kukkiwon.com/msp/tlscacerts/tlsca.kukkiwon.com-cert.pem
  CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/kukkiwon.com/users/Admin@kukkiwon.com/msp
}

setGlobals() {
  PEER=$1 #함수에 넘어온 첫번째 Argument.
  ORG=$2 #함수에 넘어온 두번째 Argument.
  if [ $ORG -eq 1 ]; then # $ORG가 1과 같은지 여부.
    CORE_PEER_LOCALMSPID="Org1MSP" #MSP의 공급자 ID는 Org1MSP.
    CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA #TLS에 통신을 위해 ORG1에서 신뢰된 루트 CA의 자체 서명된 X.509 인증서 목록.
    CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/org1.kukkiwon.com/users/Admin@org1.kukkiwon.com/msp #트랜잭션을 서명하기 위해 Peer의 인증서를 찾을 수 있는 경로.
    if [ $PEER -eq 0 ]; then # 0번 PEER인지 유무
      CORE_PEER_ADDRESS=peer0.org1.kukkiwon.com:7051 #contact하고 Transaction을 진행할 Peer의 IP 주소 설정.
    else
      CORE_PEER_ADDRESS=peer1.org1.kukkiwon.com:8051 #contact하고 Transaction을 진행할 Peer의 IP 주소 설정.
    fi
  elif [ $ORG -eq 2 ]; then # $ORG가 2과 같은지 여부
    CORE_PEER_LOCALMSPID="Org2MSP"
    CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG2_CA
    CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/org2.kukkiwon.com/users/Admin@org2.kukkiwon.com/msp
    if [ $PEER -eq 0 ]; then
      CORE_PEER_ADDRESS=peer0.org2.kukkiwon.com:9051
    else
      CORE_PEER_ADDRESS=peer1.org2.kukkiwon.com:10051
    fi
  else
    echo "================== ERROR !!! ORG Unknown =================="
  fi

  if [ "$VERBOSE" == "true" ]; then
    env | grep CORE #CORE로 시작하는 문자열을 포함하는 행을 출력
  fi
}

updateAnchorPeers() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG

  if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then # TLS를 사용 유무 / -z 옵션 : 문자열의 길이가 0이면 참, -o 옵션 : XOR 연산
    set -x
    peer channel update -o orderer1.kukkiwon.com:7050 -c $CHANNEL_NAME -f ./channel-artifacts/${CORE_PEER_LOCALMSPID}anchors.tx >&log.txt #채널 업데이트 -o orderer / -c : 채널 이름 / -f .tx 파일 위치
    res=$?
    set +x
  else
    set -x
    peer channel update -o orderer1.kukkiwon.com:7050 -c $CHANNEL_NAME -f ./channel-artifacts/${CORE_PEER_LOCALMSPID}anchors.tx --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER1_CA >&log.txt
    res=$?
    set +x
  fi
  cat log.txt
  verifyResult $res "Anchor peer update failed" #res의 값이 0이 아닐 경우 해당 문장 출력 
  echo "===================== Anchor peers updated for org '$CORE_PEER_LOCALMSPID' on channel '$CHANNEL_NAME' ===================== "
  sleep $DELAY
  echo
}

## Sometimes Join takes time hence RETRY at least 5 times
joinChannelWithRetry() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG

  set -x #화면 출력
  peer channel join -b $CHANNEL_NAME.block >&log.txt #Peer 채널 Join
  res=$? #결과
  set +x #화면 출력
  cat log.txt 
  if [ $res -ne 0 -a $COUNTER -lt $MAX_RETRY ]; then # 결과값이 0이 아니고 COUNTER가 MAX_RETRY보다 작을 경우 (-a : and , -lt : 값1 < 값2)
    COUNTER=$(expr $COUNTER + 1) #COUNTER의 값을 1 증가
    echo "peer${PEER}.org${ORG} failed to join the channel, Retry after $DELAY seconds" 
    sleep $DELAY #DELAY 시간만큼 정지
    joinChannelWithRetry $PEER $ORG #함수 재호출
  else
    COUNTER=1 #조인 성공시 COUNTER값을 기본 값인 1로 변경
  fi
  verifyResult $res "After $MAX_RETRY attempts, peer${PEER}.org${ORG} has failed to join channel '$CHANNEL_NAME' " #res의 값이 0이 아닐 경우 해당 문장 출력 
}

installChaincode() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG
  VERSION=${3:-1.0}
  set -x
  peer chaincode install -n mycc -v ${VERSION} -l ${LANGUAGE} -p ${CC_SRC_PATH} >&log.txt #체인코드 설치/ <이름, 버젼, 언어, 위치>
  res=$?
  set +x
  cat log.txt
  verifyResult $res "Chaincode installation on peer${PEER}.org${ORG} has failed" #res의 값이 0이 아닐 경우 해당 문장 출력 
  echo "===================== Chaincode is installed on peer${PEER}.org${ORG} ===================== "
  echo
}

instantiateChaincode() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG
  VERSION=${3:-1.0}

  # while 'peer chaincode' command can get the orderer endpoint from the peer
  # (if join was successful), let's supply it directly as we know it using
  # the "-o" option
  if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
    set -x
    peer chaincode instantiate -o orderer1.kukkiwon.com:7050 -C $CHANNEL_NAME -n mycc -l ${LANGUAGE} -v ${VERSION} -c '{"Args":["init","a","100","b","200"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer')" >&log.txt #Peer가 구성원인 채널에서 체인코드를 인스턴스화.
    peer chaincode instantiate -o orderer2.kukkiwon.com:7050 -C $CHANNEL_NAME -n mycc -l ${LANGUAGE} -v ${VERSION} -c '{"Args":["init","a","100","b","200"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer')" >&log.txt #Peer가 구성원인 채널에서 체인코드를 인스턴스화.
    res=$?
    set +x
  else
    set -x
    peer chaincode instantiate -o orderer1.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER1_CA -C $CHANNEL_NAME -n mycc -l ${LANGUAGE} -v 1.0 -c '{"Args":["init","a","100","b","200"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer')" >&log.txt
    peer chaincode instantiate -o orderer2.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER2_CA -C $CHANNEL_NAME -n mycc -l ${LANGUAGE} -v 1.0 -c '{"Args":["init","a","100","b","200"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer')" >&log.txt
    res=$?
    set +x
  fi
  cat log.txt
  verifyResult $res "Chaincode instantiation on peer${PEER}.org${ORG} on channel '$CHANNEL_NAME' failed" #res의 값이 0이 아닐 경우 해당 문장 출력 
  echo "===================== Chaincode is instantiated on peer${PEER}.org${ORG} on channel '$CHANNEL_NAME' ===================== "
  echo
}

upgradeChaincode() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG

  set -x
  peer chaincode upgrade -o orderer.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER1_CA -C $CHANNEL_NAME -n mycc -v 2.0 -c '{"Args":["init","a","90","b","210"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer','Org3MSP.peer')" #채널에서 인스턴스화 된 체인코드를 최신 버전으로 업그레이드.
  peer chaincode upgrade -o orderer.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER2_CA -C $CHANNEL_NAME -n mycc -v 2.0 -c '{"Args":["init","a","90","b","210"]}' -P "AND ('Org1MSP.peer','Org2MSP.peer','Org3MSP.peer')" #채널에서 인스턴스화 된 체인코드를 최신 버전으로 업그레이드.
  res=$?
  set +x
  cat log.txt
  verifyResult $res "Chaincode upgrade on peer${PEER}.org${ORG} has failed" #res의 값이 0이 아닐 경우 해당 문장 출력 
  echo "===================== Chaincode is upgraded on peer${PEER}.org${ORG} on channel '$CHANNEL_NAME' ===================== "
  echo
}

chaincodeQuery() {
  PEER=$1
  ORG=$2
  setGlobals $PEER $ORG
  EXPECTED_RESULT=$3
  echo "===================== Querying on peer${PEER}.org${ORG} on channel '$CHANNEL_NAME'... ===================== "
  local rc=1
  local starttime=$(date +%s)

  # continue to poll
  # we either get a successful response, or reach TIMEOUT
  while
    test "$(($(date +%s) - starttime))" -lt "$TIMEOUT" -a $rc -ne 0  #정해진 TIMEOUT 시간을 초과하거나 rc값이 0일 경우 반복문 종료
  do
    sleep $DELAY
    echo "Attempting to Query peer${PEER}.org${ORG} ...$(($(date +%s) - starttime)) secs"
    set -x
    peer chaincode query -C $CHANNEL_NAME -n mycc -c '{"Args":["query","a"]}' >&log.txt #체인코드 쿼리 호출 / -c : JSON 형식의 체인코드 생성자 메시지
    res=$?
    set +x
    #test == [ ]
    test $res -eq 0 && VALUE=$(cat log.txt | awk '/Query Result/ {print $NF}') # &&를 기준으로 앞 문장이 참이면 뒷 문장 실행
    test "$VALUE" = "$EXPECTED_RESULT" && let rc=0 # &&를 기준으로 앞 문장이 참이면 뒷 문장 실행
    # removed the string "Query Result" from peer chaincode query command
    # result. as a result, have to support both options until the change
    # is merged.
    test $rc -ne 0 && VALUE=$(cat log.txt | egrep '^[0-9]+$') # &&를 기준으로 앞 문장이 참이면 뒷 문장 실행
    test "$VALUE" = "$EXPECTED_RESULT" && let rc=0 # &&를 기준으로 앞 문장이 참이면 뒷 문장 실행
  done
  echo
  cat log.txt
  if test $rc -eq 0; then
    echo "===================== Query successful on peer${PEER}.org${ORG} on channel '$CHANNEL_NAME' ===================== "
  else
    echo "!!!!!!!!!!!!!!! Query result on peer${PEER}.org${ORG} is INVALID !!!!!!!!!!!!!!!!"
    echo "================== ERROR !!! FAILED to execute End-2-End Scenario =================="
    echo
    exit 1
  fi
}

# fetchChannelConfig <channel_id> <output_json>
# Writes the current channel config for a given channel to a JSON file
fetchChannelConfig() {
  CHANNEL=$1
  OUTPUT=$2

  setOrdererGlobals

  echo "Fetching the most recent configuration block for the channel"
  if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
    set -x
    peer channel fetch config config_block.pb -o orderer1.kukkiwon.com:7050 -c $CHANNEL --cafile $ORDERER1_CA
    peer channel fetch config config_block.pb -o orderer2.kukkiwon.com:7050 -c $CHANNEL --cafile $ORDERER2_CA
    set +x
  else
    set -x
    peer channel fetch config config_block.pb -o orderer1.kukkiwon.com:7050 -c $CHANNEL --tls --cafile $ORDERER1_CA
    peer channel fetch config config_block.pb -o orderer2.kukkiwon.com:7050 -c $CHANNEL --tls --cafile $ORDERER2_CA
    set +x
  fi

  echo "Decoding config block to JSON and isolating config to ${OUTPUT}"
  set -x
  configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config >"${OUTPUT}"
  set +x
}

# signConfigtxAsPeerOrg <org> <configtx.pb>
# Set the peerOrg admin of an org and signing the config update
signConfigtxAsPeerOrg() {
  PEERORG=$1
  TX=$2
  setGlobals 0 $PEERORG
  set -x
  peer channel signconfigtx -f "${TX}"
  set +x
}

# createConfigUpdate <channel_id> <original_config.json> <modified_config.json> <output.pb>
# Takes an original and modified config, and produces the config update tx
# which transitions between the two
createConfigUpdate() {
  CHANNEL=$1
  ORIGINAL=$2
  MODIFIED=$3
  OUTPUT=$4

  set -x
  configtxlator proto_encode --input "${ORIGINAL}" --type common.Config >original_config.pb
  configtxlator proto_encode --input "${MODIFIED}" --type common.Config >modified_config.pb
  configtxlator compute_update --channel_id "${CHANNEL}" --original original_config.pb --updated modified_config.pb >config_update.pb
  configtxlator proto_decode --input config_update.pb --type common.ConfigUpdate >config_update.json
  echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL'", "type":2}},"data":{"config_update":'$(cat config_update.json)'}}}' | jq . >config_update_in_envelope.json
  configtxlator proto_encode --input config_update_in_envelope.json --type common.Envelope >"${OUTPUT}"
  set +x
}

# parsePeerConnectionParameters $@
# Helper function that takes the parameters from a chaincode operation
# (e.g. invoke, query, instantiate) and checks for an even number of
# peers and associated org, then sets $PEER_CONN_PARMS and $PEERS
parsePeerConnectionParameters() {
  # check for uneven number of peer and org parameters
  if [ $(($# % 2)) -ne 0 ]; then
    exit 1
  fi

  PEER_CONN_PARMS=""
  PEERS=""
  while [ "$#" -gt 0 ]; do
    PEER="peer$1.org$2"
    PEERS="$PEERS $PEER"
    PEER_CONN_PARMS="$PEER_CONN_PARMS --peerAddresses $PEER.kukkiwon.com:$3"
    if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "true" ]; then
      TLSINFO=$(eval echo "--tlsRootCertFiles \$PEER$1_ORG$2_CA")
      PEER_CONN_PARMS="$PEER_CONN_PARMS $TLSINFO"
    fi
    # shift by two to get the next pair of peer/org parameters
    shift
    shift
    shift
  done
  # remove leading space for output
  PEERS="$(echo -e "$PEERS" | sed -e 's/^[[:space:]]*//')"
}

# chaincodeInvoke <peer> <org> ...
# Accepts as many peer/org pairs as desired and requests endorsement from each
chaincodeInvoke() {
  parsePeerConnectionParameters $@
  res=$?
  verifyResult $res "Invoke transaction failed on channel '$CHANNEL_NAME' due to uneven number of peer and org parameters " #res의 값이 0이 아닐 경우 해당 문장 출력 

  # while 'peer chaincode' command can get the orderer endpoint from the
  # peer (if join was successful), let's supply it directly as we know
  # it using the "-o" option
  if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then
    #TLS 사용 할 경우
    set -x
    peer chaincode invoke -o orderer1.kukkiwon.com:7050 -C $CHANNEL_NAME -n mycc $PEER_CONN_PARMS -c '{"Args":["invoke","a","b","10"]}' >&log.txt # 체인코드 Invoke
    peer chaincode invoke -o orderer2.kukkiwon.com:7050 -C $CHANNEL_NAME -n mycc $PEER_CONN_PARMS -c '{"Args":["invoke","a","b","10"]}' >&log.txt # 체인코드 Invoke
    res=$?
    set +x
  else
    set -x
    #TLS 사용 안 하고 직접 지정해주는 경우
    peer chaincode invoke -o orderer1.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER1_CA -C $CHANNEL_NAME -n mycc $PEER_CONN_PARMS -c '{"Args":["invoke","a","b","10"]}' >&log.txt #체인코드 Invoke
    peer chaincode invoke -o orderer2.kukkiwon.com:7050 --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER2_CA -C $CHANNEL_NAME -n mycc $PEER_CONN_PARMS -c '{"Args":["invoke","a","b","10"]}' >&log.txt #체인코드 Invoke
    res=$?
    set +x
  fi
  cat log.txt
  verifyResult $res "Invoke execution on $PEERS failed "
  echo "===================== Invoke transaction successful on $PEERS on channel '$CHANNEL_NAME' ===================== "
  echo
}
