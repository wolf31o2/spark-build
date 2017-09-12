#!/bin/bash

set -e -x
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# rename build/dist/spark-*.tgz to build/dist/spark-<TAG>.tgz
# globals: $SPARK_VERSION
function rename_dist {
    SPARK_DIST_DIR="spark-${SPARK_VERSION}-bin-${HADOOP_VERSION}"
    SPARK_DIST="${SPARK_DIST_DIR}.tgz"

    pushd "${DIST_DIR}"
    tar xvf spark-*.tgz
    rm spark-*.tgz
    mv spark-* "${SPARK_DIST_DIR}"
    tar czf "${SPARK_DIST}" "${SPARK_DIST_DIR}"
    rm -rf "${SPARK_DIST_DIR}"
    popd
}

# uploads build/spark/spark-*.tgz to S3
function upload_to_s3 {
    aws s3 cp --acl public-read "${DIST_DIR}/${SPARK_DIST}" "${S3_URL}"
}

# $1: hadoop version (e.g. "2.6")
function docker_version() {
    echo "${SPARK_BUILD_VERSION}-hadoop-$1"
}

function docker_login {
    docker login --email=docker@mesosphere.io --username="${DOCKER_USERNAME}" --password="${DOCKER_PASSWORD}"
}

function set_hadoop_versions {
    HADOOP_VERSIONS=( "2.4" "2.6" "2.7" )
}

function build_and_test() {
    DIST=prod make dist
    SPARK_DIST=$(cd ${SPARK_DIR} && ls spark-*.tgz)
    S3_URL="s3://${S3_BUCKET}/${S3_PREFIX}/spark/${GIT_COMMIT}/" upload_to_s3

    SPARK_DIST_URI="http://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}/spark/${GIT_COMMIT}/${SPARK_DIST}" make universe

    export $(cat "${WORKSPACE}/stub-universe.properties")
    make test
}

# $1: profile (e.g. "hadoop-2.6")
function does_profile_exist() {
    (cd "${SPARK_DIR}" && ./build/mvn help:all-profiles | grep "$1")
}
