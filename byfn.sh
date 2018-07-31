#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

# This script will orchestrate a sample end-to-end execution of the Hyperledger
# Fabric network.
#
# The end-to-end verification provisions a sample Fabric network consisting of
# two organizations, each maintaining two peers, and a “solo” ordering service.
#
# This verification makes use of two fundamental tools, which are necessary to
# create a functioning transactional network with digital signature validation
# and access control:
#
# * cryptogen - generates the x509 certificates used to identify and
#   authenticate the various components in the network.
# * configtxgen - generates the requisite configuration artifacts for orderer
#   bootstrap and channel creation.
#
# Each tool consumes a configuration yaml file, within which we specify the topology
# of our network (cryptogen) and the location of our certificates for various
# configuration operations (configtxgen).  Once the tools have been successfully run,
# we are able to launch our network.  More detail on the tools and the structure of
# the network will be provided later in this document.  For now, let's get going...

# prepending $PWD/../bin to PATH to ensure we are picking up the correct binaries
# this may be commented out to resolve installed version of tools if desired
export PATH=${PWD}/bin:${PWD}:$PATH
export FABRIC_CFG_PATH=${PWD} #configtx.yaml 파일의 위치
export VERBOSE=false #부팅시 상세한 설명 (?)

: ${ORG1:="org1"} #디폴트로 ORG1 == org1
: ${ORG2:="org2"} #디폴트로 ORG2 == org2

# 사용법 안내
function printHelp() {
  echo "Usage: "
  echo "  byfn.sh <mode> [-c <channel name>] [-t <timeout>] [-d <delay>] [-f <docker-compose-file>] [-s <dbtype>] [-l <language>] [-i <imagetag>] [-v]"
  echo "    <mode> - one of 'up', 'down', 'restart', 'generate' or 'upgrade'"
  echo "      - 'up' - bring up the network with docker-compose up"
  echo "      - 'down' - clear the network with docker-compose down"
  echo "      - 'restart' - restart the network"
  echo "      - 'generate' - generate required certificates and genesis block"
  echo "      - 'upgrade'  - upgrade the network from version 1.1.x to 1.2.x"
  echo "    -c <channel name> - channel name to use (defaults to \"mychannel\")"
  echo "    -t <timeout> - CLI timeout duration in seconds (defaults to 10)"
  echo "    -d <delay> - delay duration in seconds (defaults to 3)"
  echo "    -f <docker-compose-file> - specify which docker-compose file use (defaults to docker-compose-cli.yaml)"
  echo "    -s <dbtype> - the database backend to use: goleveldb (default) or couchdb"
  echo "    -l <language> - the chaincode language: golang (default) or node"
  echo "    -i <imagetag> - the tag to be used to launch the network (defaults to \"latest\")"
  echo "    -v - verbose mode"
  echo "  byfn.sh -h (print this message)"
  echo
  echo "Typically, one would first generate the required certificates and "
  echo "genesis block, then bring up the network. e.g.:"
  echo
  echo "	byfn.sh generate -c mychannel"
  echo "	byfn.sh up -c mychannel -s couchdb"
  echo "        byfn.sh up -c mychannel -s couchdb -i 1.2.x"
  echo "	byfn.sh up -l node"
  echo "	byfn.sh down -c mychannel"
  echo "        byfn.sh upgrade -c mychannel"
  echo
  echo "Taking all defaults:"
  echo "	byfn.sh generate"
  echo "	byfn.sh up"
  echo "	byfn.sh down"
}

# 프로세스를 수행할 것인지 확인
function askProceed() {
  read -p "Continue? [Y/n] " ans #read 명령어 : 한 줄의 내용씩 읽어 들이는 명령어
  case "$ans" in #input 값에 따른 분기 처리
  y | Y | "")
    echo "proceeding ..."
    ;;
  n | N)
    echo "exiting..."
    exit 1
    ;;
  *)
    echo "invalid response"
    askProceed
    ;;
  esac
}

# CONTAINER_ID 구하고 제거하기
# TODO 선택 사항으로 다른 컨테이너를 지울 수 있습니다.
function clearContainers() {
  CONTAINER_IDS=$(docker ps -a | awk '($2 ~ /dev-peer.*.mycc.*/) {print $1}')
  if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" == " " ]; then #-z :문자열이 null인 경우 / -o : XOR 연산
    echo "---- No containers available for deletion ----"
  else
    docker rm -f $CONTAINER_IDS #도커 컨테이너를 제거한다.
  fi
}

# 설정의 일부로 생성 된 이미지 제거하기
# specifically the following images are often left behind:
# TODO list generated image naming patterns
function removeUnwantedImages() {
  DOCKER_IMAGE_IDS=$(docker images | awk '($1 ~ /dev-peer.*.mycc.*/) {print $3}')
  if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" == " " ]; then #-z :문자열이 null인 경우 / -o : XOR 연산
    echo "---- No images available for deletion ----"
  else
    docker rmi -f $DOCKER_IMAGE_IDS #도커 이미지를 제거한다.
  fi
}

#이 첫 번째 네트워크 릴리스에서 작동하지 않는 것으로 알려진 패브릭 버전
BLACKLISTED_VERSIONS="^1\.0\. ^1\.1\.0-preview ^1\.1\.0-alpha"

# 패브릭 바이너리/이미지를 사용할 수 잇는지 확인하기위한 검사 수행.
# 추후에는 Go 버젼이나 기타 항목의 검사가 추가될 수 있습니다.
function checkPrereqs() {
  # Note, we check configtxlator externally because it does not require a config file, and peer in the
  # docker image because of FAB-8551 that makes configtxlator return 'development version' in docker
  LOCAL_VERSION=$(configtxlator version | sed -ne 's/ Version: //p') 
  DOCKER_IMAGE_VERSION=$(docker run --rm hyperledger/fabric-tools:$IMAGETAG peer version | sed -ne 's/ Version: //p' | head -1)

  echo "LOCAL_VERSION=$LOCAL_VERSION"
  echo "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"

  ##로컬버전과 도커 이미지 버전이 일치하지 않을 경우 스크립트를 중지한다.
  if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
    echo "=================== WARNING ==================="
    echo "  Local fabric binaries and docker images are  "
    echo "  out of  sync. This may cause problems.       "
    echo "==============================================="
  fi

  ##블랙리스트에 해당하는 버전을 사용할 경우 스크립트를 중지한다.
  for UNSUPPORTED_VERSION in $BLACKLISTED_VERSIONS; do
    echo "$LOCAL_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      echo "ERROR! Local Fabric binary version of $LOCAL_VERSION does not match this newer version of BYFN and is unsupported. Either move to a later version of Fabric or checkout an earlier version of fabric-samples."
      exit 1
    fi

    echo "$DOCKER_IMAGE_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      echo "ERROR! Fabric Docker image version of $DOCKER_IMAGE_VERSION does not match this newer version of BYFN and is unsupported. Either move to a later version of Fabric or checkout an earlier version of fabric-samples."
      exit 1
    fi
  done
}

## 필요로하는 인증서와 초기 블록을 생성하고, 네트워크를 실행한다.
function networkUp() {
  checkPrereqs
  # 아티팩트가 존재하지 않을 경우 생성한다.
  if [ ! -d "crypto-config" ]; then
    if [ ${ORG} == ${ORG1} ]; then
      generateCerts
      replacePrivateKey
      generateChannelArtifacts
    fi
  fi
  if [ "${IF_COUCHDB}" == "couchdb" ]; then
    IMAGE_TAG=$IMAGETAG docker-compose -f $COMPOSE_FILE -f $COMPOSE_FILE_COUCH up -d 2>&1
  else
    IMAGE_TAG=$IMAGETAG docker-compose -f $COMPOSE_FILE up -d 2>&1
  fi
  ## $? : 직전에 수행한 명령어의 결과 반환 (0 성공 / 나머지 실패)
  if [ $? -ne 0 ]; then
    echo "ERROR !!!! Unable to start network"
    exit 1
  fi

  ##스크립트 실행 문장
  # now run the end to end script
  # docker exec cli scripts/script.sh $CHANNEL_NAME $CLI_DELAY $LANGUAGE $CLI_TIMEOUT $VERBOSE

  # if [ $? -ne 0 ]; then
  #   echo "ERROR !!!! Test failed"
  #   exit 1
  # fi
}

# Upgrade the network components which are at version 1.1.x to 1.2.x
# Stop the orderer and peers, backup the ledger for orderer and peers, cleanup chaincode containers and images
# and relaunch the orderer and peers with latest tag
function upgradeNetwork() {
  docker inspect -f '{{.Config.Volumes}}' orderer.kukkiwon.com | grep -q '/var/hyperledger/production/orderer'
  if [ $? -ne 0 ]; then
    echo "ERROR !!!! This network does not appear to be using volumes for its ledgers, did you start from fabric-samples >= v1.1.x?"
    exit 1
  fi

  LEDGERS_BACKUP=./ledgers-backup

  # create ledger-backup directory
  mkdir -p $LEDGERS_BACKUP

  export IMAGE_TAG=$IMAGETAG
  if [ "${IF_COUCHDB}" == "couchdb" ]; then
    COMPOSE_FILES="-f $COMPOSE_FILE -f $COMPOSE_FILE_COUCH"
  else
    COMPOSE_FILES="-f $COMPOSE_FILE"
  fi

  # removing the cli container
  docker-compose $COMPOSE_FILES stop cli
  docker-compose $COMPOSE_FILES up -d --no-deps cli

  echo "Upgrading orderer"
  docker-compose $COMPOSE_FILES stop orderer.kukkiwon.com
  docker cp -a orderer.kukkiwon.com:/var/hyperledger/production/orderer $LEDGERS_BACKUP/orderer.kukkiwon.com
  docker-compose $COMPOSE_FILES up -d --no-deps orderer.kukkiwon.com

  for PEER in peer0.org1.kukkiwon.com peer1.org1.kukkiwon.com peer0.org2.kukkiwon.com peer1.org2.kukkiwon.com; do
    echo "Upgrading peer $PEER"

    # Stop the peer and backup its ledger
    docker-compose $COMPOSE_FILES stop $PEER
    docker cp -a $PEER:/var/hyperledger/production $LEDGERS_BACKUP/$PEER/

    # Remove any old containers and images for this peer
    CC_CONTAINERS=$(docker ps | grep dev-$PEER | awk '{print $1}')
    if [ -n "$CC_CONTAINERS" ]; then
      docker rm -f $CC_CONTAINERS
    fi
    CC_IMAGES=$(docker images | grep dev-$PEER | awk '{print $1}')
    if [ -n "$CC_IMAGES" ]; then
      docker rmi -f $CC_IMAGES
    fi

    # Start the peer again
    docker-compose $COMPOSE_FILES up -d --no-deps $PEER
  done

  docker exec cli scripts/upgrade_to_v12.sh $CHANNEL_NAME $CLI_DELAY $LANGUAGE $CLI_TIMEOUT $VERBOSE
  if [ $? -ne 0 ]; then
    echo "ERROR !!!! Test failed"
    exit 1
  fi
}

# 네트워크 다운
function networkDown() {
  # org1, org2 컨테이너 정지
  # --remove-orphans : 작성 파일에 정의되지 않은 서비스의 컨테이너를 제거하십시오.
  docker-compose -f $COMPOSE_FILE down --volumes --remove-orphans

  # Don't remove the generated artifacts -- note, the ledgers are always removed
  if [ "$MODE" != "restart" ]; then
    # 네트워크를 가져와서 볼륨 제거.
    # 모든 원장 백업 제거.
    docker run -v $PWD:/tmp/first-network --rm hyperledger/fabric-tools:$IMAGETAG rm -Rf /tmp/first-network/ledgers-backup
    #체인코드 컨테이너 제거
    clearContainers
    #도커 이미지 제거
    removeUnwantedImages
    #Orderer 블록과 기타 채널 구성 트랜잭션 및 인증서 제거
    if [ ${ORG} == ${ORG1} ]; then
      askProceed
      rm -rf channel-artifacts/*.block channel-artifacts/*.tx crypto-config ./org3-artifacts/crypto-config/ channel-artifacts/org3.json
    fi
    # 국기원에 커스터마즈 된 docker-compose-e2e.yaml 파일 제거
    rm -f docker-compose-e2e.yaml
  fi
}

# docker-compose-e2e-template.yaml을 사용하여,cryptogen 도구로 생성 된 개인 키 파일 이름으로 
# 상수를 대체하고,이 구성과 관련된 docker-compose.yaml을 생성하시오.
function replacePrivateKey() {
  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and delete it at the end of the function
  ARCH=$(uname -s | grep Darwin)
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi

  # template 파일을 카피해서 private key 부분을 변경.
  # cp docker-compose-e2e-template.yaml docker-compose-e2e-or1.yaml
  # cp docker-compose-e2e-template.yaml docker-compose-e2e-or2.yaml

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd crypto-config/peerOrganizations/org1.kukkiwon.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA1_PRIVATE_KEY/${PRIV_KEY}/g" docker-compose-e2e-org1.yaml
  cd crypto-config/peerOrganizations/org2.kukkiwon.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA2_PRIVATE_KEY/${PRIV_KEY}/g" docker-compose-e2e-org2.yaml
  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm docker-compose-e2e.yamlt
  fi
}

# crpytogen 도구를 사용하여 다양한 네트워크 엔티티에 대한 암호 자료(x.509 인증서)를 생성합니다.
# 인증서는 공통 PKI 구현을 기반으로하며 여기에서는 공통 트러스트 앵커에 도달하여 유효성을 검사합니다.
#
# Cryptogen은 네트워크 토폴로지를 포함하고있는``crypto-config.yaml`` 파일을 사용하며 조직과 
# 그 조직에 속한 구성 요소 모두에 대한 인증서 라이브러리를 생성 할 수 있습니다.
# 각 조직은 특정 구성 요소 (피어 및 ​​주문자)를 해당 조직에 바인딩하는 고유 한 루트 인증서 ( "ca-cert")를 제공합니다.
# Fabric 내의 트랜잭션과 통신은 엔티티의 개인 키 ( "keystore")에 의해 서명 된 다음 공개 키 ( "signcerts")를 통해 검증됩니다.
# 
# 이 문서내의 'count'라는 변수에 주목합시오. 우리는이를 사용하여 조직 당 피어의 수를 지정합니다. 
# 우리의 경우 Org 당 두 명의 동료가 있습니다. 이 템플릿의 나머지 부분은 매우 자명합니다. 
#
# 이 도구를 실행하면 certs는 "crypto-config"라는 폴더에 보관됩니다.

# cryptogen 도구를 사용하여 ORG 인증서 생성
function generateCerts() {
  which cryptogen #cryptogen 파일의 위치로 이동.
  if [ "$?" -ne 0 ]; then #명령이 실패할 경우 (cryptogen을 찾지 못한 경우)
    echo "cryptogen tool not found. exiting"
    exit 1
  fi
  echo
  echo "##########################################################"
  echo "##### Generate certificates using cryptogen tool #########"
  echo "##########################################################"

  if [ -d "crypto-config" ]; then
    rm -Rf crypto-config ## 이미 폴더가 존재하는 경우 해당 폴더 제거
  fi
  set -x
  cryptogen generate --config=./crypto-config.yaml ## --config : 사용할 구성(config) 템플릿
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate certificates..."
    exit 1
  fi
  echo
}

# The `configtxgen tool is used to create four artifacts: orderer **bootstrap
# block**, fabric **channel configuration transaction**, and two **anchor
# peer transactions** - one for each Peer Org.

# The orderer block is the genesis block for the ordering service, and the
# channel transaction file is broadcast to the orderer at channel creation
# time.  The anchor peer transactions, as the name might suggest, specify each
# Org's anchor peer on this channel.
# # Configtxgen consumes a file - ``configtx.yaml`` - that contains the definitions
# for the sample network. There are three members - one Orderer Org (``OrdererOrg``)
# and two Peer Orgs (``Org1`` & ``Org2``) each managing and maintaining two peer nodes.
# This file also specifies a consortium - ``SampleConsortium`` - consisting of our
# two Peer Orgs.  Pay specific attention to the "Profiles" section at the top of
# this file.  You will notice that we have two unique headers. One for the orderer genesis
# block - ``TwoOrgsOrdererGenesis`` - and one for our channel - ``KukkiwonChannel``.
# These headers are important, as we will pass them in as arguments when we create
# our artifacts.  This file also contains two additional specifications that are worth
# noting.  Firstly, we specify the anchor peers for each Peer Org
# (``peer0.org1.kukkiwon.com`` & ``peer0.org2.kukkiwon.com``).  Secondly, we point to
# the location of the MSP directory for each member, in turn allowing us to store the
# root certificates for each Org in the orderer genesis block.  This is a critical
# concept. Now any network entity communicating with the ordering service can have
# its digital signature verified.

# This function will generate the crypto material and our four configuration
# artifacts, and subsequently output these files into the ``channel-artifacts``
# folder.

# If you receive the following warning, it can be safely ignored:

# [bccsp] GetDefault -> WARN 001 Before using BCCSP, please call InitFactories(). Falling back to bootBCCSP.

# You can ignore the logs regarding intermediate certs, we are not using them in
# this crypto implementation.

# Generate orderer genesis block, channel configuration transaction and
# anchor peer update transactions
function generateChannelArtifacts() {
  which configtxgen #configtxgen 파일이 있는 폴더로 이동.
  if [ "$?" -ne 0 ]; then #폴더가 없을 경우
    echo "configtxgen tool not found. exiting"
    exit 1
  fi
    echo "##########################################################"
    echo "#########  Generating Orderer Genesis block ##############"
    echo "##########################################################"
    # 알수 없는 이유로 (적어도 현재는) 블록 파일의 이름을 orderer.genesis.block으로 지정할 수 없거나
    # orderer가 시작되지 않습니다.
    set -x
    ## -profile : 생성에 사용할 configtx.yaml의 profile.
    ## -outputBlock : genesis 블록 생성 위치
    configtxgen -profile TwoOrgsOrdererGenesis -outputBlock ./channel-artifacts/genesis.block
    res=$?
    set +x
    if [ $res -ne 0 ]; then
      echo "Failed to generate orderer genesis block..."
      exit 1
    fi
    echo
    echo "#########################################################################"
    echo "### Generating channel configuration transaction 'kukkiwonchannel.tx' ###"
    echo "#########################################################################"
    set -x
    configtxgen -profile KukkiwonChannel -outputCreateChannelTx ./channel-artifacts/kukkiwonChannel.tx -channelID $CHANNEL_NAME
    res=$?
    set +x
    if [ $res -ne 0 ]; then
      echo "Failed to generate channel configuration transaction..."
      exit 1
    fi

    echo
    echo "#################################################################"
    echo "#######    Generating anchor peer update for Org1MSP   ##########"
    echo "#################################################################"
    set -x
    configtxgen -profile KukkiwonChannel -outputAnchorPeersUpdate ./channel-artifacts/Org1MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org1MSP
    res=$?
    set +x
    if [ $res -ne 0 ]; then
      echo "Failed to generate anchor peer update for Org1MSP..."
      exit 1
    fi
    echo
    echo "#################################################################"
    echo "#######    Generating anchor peer update for Org2MSP   ##########"
    echo "#################################################################"
    set -x
    configtxgen -profile KukkiwonChannel -outputAnchorPeersUpdate ./channel-artifacts/Org2MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org2MSP
    res=$?
    set +x
    if [ $res -ne 0 ]; then
      echo "Failed to generate anchor peer update for Org2MSP..."
      exit 1
    fi
    echo
}

#플랫폼에 맞는 올바른 바이너리를 선택하는데 사용할 OS 및 아키텍처 문자열을 가져옵니다.
#(예 : darwin-amd64 또는 linux-amd64)
OS_ARCH=$(echo "$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')" | awk '{print tolower($0)}')
# timeout duration - cli가 다른 컨테이너의 응답을 기다려야만 하는 시간.
CLI_TIMEOUT=10
# 명령어간 기본 delay 시간.
CLI_DELAY=3
CHANNEL_NAME="kukkiwonchannel"
# 기본 docker-compose.yaml 정의로 사용.
COMPOSE_FILE=docker-compose-cli.yaml
COMPOSE_FILE_COUCH=docker-compose-couch.yaml
#
# 체인코드 기본 언어
LANGUAGE=golang
# 이미지 태그 기본 값
IMAGETAG="latest"
# Parse commandline args
# 구문 분석 명렬줄 인수
if [ "$1" = "-m" ]; then # supports old usage, muscle memory is powerful!
  shift #  shift는 $1 인자를 없애고 각 인자번호를 1씩 줄인다. 즉 $2는 $1, $3은 $2, $4은 $3과 같은 식으로 된다.
fi
MODE=$1
shift
# MODE 값에 따른 분기 처리.
if [ "$MODE" == "up" ]; then
  EXPMODE="Starting"
elif [ "$MODE" == "down" ]; then
  EXPMODE="Stopping"
elif [ "$MODE" == "restart" ]; then
  EXPMODE="Restarting"
elif [ "$MODE" == "generate" ]; then
  EXPMODE="Generating certs and genesis block"
elif [ "$MODE" == "upgrade" ]; then
  EXPMODE="Upgrading the network"
else
  printHelp
  exit 1
fi

while getopts "h?c:t:d:f:s:l:i:v:o:" opt; do
  case "$opt" in
  h | \?)
    printHelp
    exit 0
    ;;
  c)
    CHANNEL_NAME=$OPTARG
    ;;
  t)
    CLI_TIMEOUT=$OPTARG
    ;;
  d)
    CLI_DELAY=$OPTARG
    ;;
  f)
    COMPOSE_FILE=$OPTARG
    ;;
  s)
    IF_COUCHDB=$OPTARG
    ;;
  l)
    LANGUAGE=$OPTARG
    ;;
  i)
    IMAGETAG=$(go env GOARCH)"-"$OPTARG
    ;;
  v)
    VERBOSE=true
    ;;
  o) #ORG 옵션 추가
    ORG=$OPTARG
    ;;
  esac
done

#ORG1일 경우
if [ ${ORG} == ${ORG1} ]; then
  COMPOSE_FILE=docker-compose-cli-org1.yaml
#ORG2일 경우
elif [ ${ORG} == ${ORG2} ]; then
  COMPOSE_FILE=docker-compose-cli-org2.yaml
fi
if [ "${IF_COUCHDB}" == "couchdb" ]; then
  echo
  echo "${EXPMODE} for channel '${CHANNEL_NAME}' with CLI timeout of '${CLI_TIMEOUT}' seconds and CLI delay of '${CLI_DELAY}' seconds and using database '${IF_COUCHDB}'"
else
  echo "${EXPMODE} for channel '${CHANNEL_NAME}' with CLI timeout of '${CLI_TIMEOUT}' seconds and CLI delay of '${CLI_DELAY}' seconds"
fi
# 프로세스를 시작할 것인지 확인하는 함수.
askProceed

#docker compose를 활용한 네트워크 생성.
if [ "${MODE}" == "up" ]; then
  networkUp
elif [ "${MODE}" == "down" ]; then ## 네트워크 다운
  networkDown
elif [ "${MODE}" == "generate" ]; then ## 아티팩트 생성
  generateCerts
  replacePrivateKey
  generateChannelArtifacts
elif [ "${MODE}" == "restart" ]; then ## 네트워크 재시작
  networkDown
  networkUp
elif [ "${MODE}" == "upgrade" ]; then ##1.1.x 에서 1.2.x로 네트워크 버전 업그레이드
  upgradeNetwork
else
  printHelp
  exit 1
fi
