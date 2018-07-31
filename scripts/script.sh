#!/bin/bash

echo
echo " ____    _____      _      ____    _____ "
echo "/ ___|  |_   _|    / \    |  _ \  |_   _|"
echo "\___ \    | |     / _ \   | |_) |   | |  "
echo " ___) |   | |    / ___ \  |  _ <    | |  "
echo "|____/    |_|   /_/   \_\ |_| \_\   |_|  "
echo
echo "Build your first network (BYFN) end-to-end test"
echo
CHANNEL_NAME="$1"
DELAY="$2"
LANGUAGE="$3"
TIMEOUT="$4"
VERBOSE="$5"
: ${CHANNEL_NAME:="KukkiwonChannel"}
: ${DELAY:="3"}
: ${LANGUAGE:="golang"}
: ${TIMEOUT:="10"}
: ${VERBOSE:="false"}
LANGUAGE=`echo "$LANGUAGE" | tr [:upper:] [:lower:]`
COUNTER=1
MAX_RETRY=5

CC_SRC_PATH="github.com/chaincode/chaincode_example02/go/" #go언어 chain code 경로
if [ "$LANGUAGE" = "node" ]; then
	CC_SRC_PATH="/opt/gopath/src/github.com/chaincode/chaincode_example02/node/" #node 언어 chain code 경로
fi

echo "Channel name : "$CHANNEL_NAME

# import utils
. scripts/utils.sh

#channel 생성
createChannel() {
	setGlobals 0 1 #utils.sh 파일내 함수

	if [ -z "$CORE_PEER_TLS_ENABLED" -o "$CORE_PEER_TLS_ENABLED" = "false" ]; then # TLS를 사용 유무 / -z 옵션 : 문자열의 길이가 0이면 참, -o 옵션 : XOR 연산
        set -x #화면 출력 시작
		# 채널 생성 -o orderer / -c : 채널 이름 / -f .tx 파일 위치
		# 여기서 Orderer는 peer가 통신하고 있는 orderer여야함.
		peer chanel create -o orderer1.kukkiwon.com:7050 -c $CHANNEL_NAME -f ./channel-artifacts/kukkiwonChannel.tx >&log.txt 
		res=$? # 최근 수행한 명령어 종료 상태 여부 정상(0)
        set +x #화면 출력 끝
	else
		set -x
		# 채널 생성 -o orderer / -c : 채널 이름 / -f .tx 파일 위치.
		# 여기서 Orderer는 peer가 통신하고 있는 orderer여야함.
		# 별도의 tls를 설정하지 않았기에 --tls와 --cafile 옵션을 사용으로 위치를 적용.
		peer channel create -o orderer1.kukkiwon.com:7050 -c $CHANNEL_NAME -f ./channel-artifacts/kukkiwonChannel.tx --tls $CORE_PEER_TLS_ENABLED --cafile $ORDERER1_CA >&log.txt
		res=$?
		set +x
	fi
	cat log.txt 
	verifyResult $res "Channel creation failed"
	echo "===================== Channel '$CHANNEL_NAME' created ===================== "
	echo
}

#channel 조인
joinChannel () {
	for org in 1 2; do #org에 1,2를 순차 대입하여 반복문 실행
	    for peer in 0 1; do #peer에 0,1를 순차 대입하여 반복문 실행
		joinChannelWithRetry $peer $org #peer 채널 join 함수 호출
		echo "===================== peer${peer}.org${org} joined channel '$CHANNEL_NAME' ===================== " #결과 출력
		sleep $DELAY #DELAY 시간만큼 정지
		echo
	    done
	done
}

## 채널생성
echo "Creating channel..."
createChannel

## 채널에 피어 조인
echo "Having all peers join the channel..."
joinChannel

## 각각 채널에 앵커피어 설정
echo "Updating anchor peers for org1..."
updateAnchorPeers 0 1
echo "Updating anchor peers for org2..."
updateAnchorPeers 0 2

## 체인코드 인스톨 peer0.org1 and peer0.org2
echo "Installing chaincode on peer0.org1..."
installChaincode 0 1
echo "Install chaincode on peer0.org2..."
installChaincode 0 2

# Instantiate chaincode on peer0.org2
echo "Instantiating chaincode on peer0.org2..."
instantiateChaincode 0 2

# 체인코드 query peer0.org1
echo "Querying chaincode on peer0.org1..."
chaincodeQuery 0 1 100

# 체인코드 Invoke peer0.org1 and peer0.org2
echo "Sending invoke transaction on peer0.org1 peer0.org2..."
chaincodeInvoke 0 1 7051 0 2 9051

## 체인코드 인스톨 peer1.org2
echo "Installing chaincode on peer1.org2..."
installChaincode 1 2

# Query on chaincode on peer1.org2, check if the result is 90
echo "Querying chaincode on peer1.org2..."
chaincodeQuery 1 2 90

echo
echo "========= All GOOD, BYFN execution completed =========== "
echo

echo
echo " _____   _   _   ____   "
echo "| ____| | \ | | |  _ \  "
echo "|  _|   |  \| | | | | | "
echo "| |___  | |\  | | |_| | "
echo "|_____| |_| \_| |____/  "
echo

exit 0
