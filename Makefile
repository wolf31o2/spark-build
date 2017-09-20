ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
TOOLS_DIR := $(ROOT_DIR)/bin/dcos-commons-tools
SPARK_DIR := $(ROOT_DIR)/spark
BUILD_DIR := $(ROOT_DIR)/build
DIST_DIR := $(BUILD_DIR)/dist
SHELL := /bin/bash
SHELLFLAGS := -e
CLI_VERSION := $(shell jq -r ".cli_version" "$(ROOT_DIR)/manifest.json")
HADOOP_VERSION := $(shell jq ".default_spark_dist.hadoop_version" "$(ROOT_DIR)/manifest.json")
SPARK_DIST_URI := $(shell jq ".default_spark_dist.uri" "$(ROOT_DIR)/manifest.json")
GIT_COMMIT := $(shell git rev-parse HEAD)

DOCKER_DIST_IMAGE := mesosphere/spark-dev:$(GIT_COMMIT)
DOCKER_BUILD_IMAGE := mesosphere/spark-build:$(GIT_COMMIT)
S3_BUCKET := infinity-artifacts
S3_PREFIX := autodelete7d

.ONESHELL:

$(SPARK_DIR):
	git clone https://github.com/mesosphere/spark $(SPARK_DIR)

dcoker-build:
	docker build -t $(DOCKER_BUILD_IMAGE) .

clean-dist:
	if [ -d $(DIST_DIR) ]; then \
		rm -rf $(DIST_DIR); \
	fi; \

manifest-dist: clean-dist
	mkdir -p $(DIST_DIR)
	cd $(DIST_DIR)
	wget $(SPARK_DIST_URI)

dev-dist: $(SPARK_DIR) clean-dist
	cd $(SPARK_DIR)
	rm -rf spark-*.tgz
	build/sbt -Xmax-classfile-name -Pmesos "-Phadoop-$(HADOOP_VERSION)" -Phive -Phive-thriftserver package
	rm -rf /tmp/spark-SNAPSHOT*
	mkdir -p /tmp/spark-SNAPSHOT/jars
	cp -r assembly/target/scala*/jars/* /tmp/spark-SNAPSHOT/jars
	mkdir -p /tmp/spark-SNAPSHOT/examples/jars
	cp -r examples/target/scala*/jars/* /tmp/spark-SNAPSHOT/examples/jars
	for f in /tmp/spark-SNAPSHOT/examples/jars/*; do \
		name=$(basename "$f"); \
		if [ -f "/tmp/spark-SNAPSHOT/jars/${name}" ]; then \
			rm "/tmp/spark-SNAPSHOT/examples/jars/${name}"; \
		fi; \
	done; \
	cp -r data /tmp/spark-SNAPSHOT/
	mkdir -p /tmp/spark-SNAPSHOT/conf
	cp conf/* /tmp/spark-SNAPSHOT/conf
	cp -r bin /tmp/spark-SNAPSHOT
	cp -r sbin /tmp/spark-SNAPSHOT
	cp -r python /tmp/spark-SNAPSHOT
	cd /tmp
	tar czf spark-SNAPSHOT.tgz spark-SNAPSHOT
	mkdir -p $(DIST_DIR)
	cp /tmp/spark-SNAPSHOT.tgz $(DIST_DIR)/

prod-dist: $(SPARK_DIR) clean-dist
	cd $(SPARK_DIR)
	rm -rf spark-*.tgz
	if [ -f make-distribution.sh ]; then \
		./make-distribution.sh --tgz "-Phadoop-${HADOOP_VERSION}" -Phive -Phive-thriftserver -DskipTests; \
	else \
		if [ -n `./build/mvn help:all-profiles | grep "mesos"` ]; then \
			MESOS_PROFILE="-Pmesos"; \
		else \
			MESOS_PROFILE=""; \
		fi; \
		./dev/make-distribution.sh --tgz "${MESOS_PROFILE}" "-Phadoop-${HADOOP_VERSION}" -Psparkr -Phive -Phive-thriftserver -DskipTests; \
	fi; \
	mkdir -p $(DIST_DIR)
	cp spark-*.tgz $(DIST_DIR)

# this target serves as default dist type
$(DIST_DIR): manifest-dist

docker-login:
	docker login --email=docker@mesosphere.io --username="${DOCKER_USERNAME}" --password="${DOCKER_PASSWORD}"

docker-dist: $(DIST_DIR)
	tar xvf $(DIST_DIR)/spark-*.tgz -C $(DIST_DIR)
	rm -rf $(BUILD_DIR)/docker
	mkdir -p $(BUILD_DIR)/docker/dist
	cp -r $(DIST_DIR)/spark-*/. $(BUILD_DIR)/docker/dist
	cp -r conf/* $(BUILD_DIR)/docker/dist/conf
	cp -r docker/* $(BUILD_DIR)/docker
	cd $(BUILD_DIR)/docker && docker build -t $(DOCKER_DIST_IMAGE) .
	docker push $(DOCKER_DIST_IMAGE)

cli:
	$(MAKE) --directory=cli all

stub-universe.properties: cli docker-dist
	aws s3 cp --acl public-read "$(DIST_DIR)/$(spark_dist)" "s3://$(S3_BUCKET)/$(S3_PREFIX)/spark/$(GIT_COMMIT)/"
	TEMPLATE_CLI_VERSION=${CLI_VERSION} \
	TEMPLATE_SPARK_DIST_URI="http://$(S3_BUCKET).s3.amazonaws.com/$(S3_PREFIX)/spark/$(GIT_COMMIT)/$(spark_dist)"\
	TEMPLATE_DOCKER_IMAGE=${DOCKER_IMAGE}
	DOCKER_IMAGE=$(DOCKER_DIST_IMAGE)
		$(ROOT_DIR)/bin/dcos-commons-tools/aws_upload.py \
		spark \
        $(ROOT_DIR)/universe/ \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark-darwin \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark-linux \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark.exe \
        $(ROOT_DIR)/cli/python/dist/*.whl

DCOS_TEST_JAR_PATH := $(ROOT_DIR)/dcos-spark-scala-tests-assembly-0.1-SNAPSHOT.jar
$(DCOS_TEST_JAR_PATH):
	cd tests/jobs/scala
	sbt assembly
	cp $(ROOT_DIR)/tests/jobs/scala/target/scala-2.11/dcos-spark-scala-tests-assembly-0.1-SNAPSHOT.jar $(DCOS_TEST_JAR_PATH)

clean-scala-test-jar:
	rm $(SCALA_TEST_JAR)

test-env:
	python3 -m venv $(ROOT_DIR)/test-env
	source $(ROOT_DIR)/test-env/bin/activate
	pip3 install -r $(ROOT_DIR)/tests/requirements.txt

clean-test-env:
	rm -rf test-env

cluster: test-env
	source $(ROOT_DIR)/test-env/bin/activate

mesos-spark-integration-test:
	git clone https://github.com/typesafehub/mesos-spark-integration-tests $(ROOT_DIR)/mesos-spark-integration-tests

SPARK_TEST_JAR_PATH := $(ROOT_DIR)/mesos-spark-integration-tests-assembly-0.1.0.jar
$(SPARK_TEST_JAR_PATH): mesos-spark-integration-test
	cd $(ROOT_DIR)/mesos-spark-integration-tests/test-runner
	sbt assembly
	cd ..
	sbt clean compile test
	cp ls test-runner/target/scala-2.11/mesos-spark-integration-tests-assembly-0.1.0.jar $(SPARK_TEST_JAR_PATH)

test: test-env $(DCOS_TEST_JAR_PATH) $(SPARK_TEST_JAR_PATH) stub-universe.properties
	source $(ROOT_DIR)/test-env/bin/activate
	export `cat stub-universe.properties`
	if [ "$(SECURITY)" = "strict" ]; then \
        $(TOOLS_DIR)/setup_permissions.sh root "*"; \
        $(TOOLS_DIR)/setup_permissions.sh root hdfs-role; \
    fi; \
    SCALA_TEST_JAR=$(DCOS_TEST_JAR_PATH) \
	  TEST_JAR_PATH=$(SPARK_TEST_JAR_PATH) \
	  py.test -vv $(ROOT_DIR)/tests

clean: clean-scala-jar clean-dist clean-test-env

define upload_to_s3
aws s3 cp --acl public-read "$(DIST_DIR)/$(spark_dist)" "${S3_URL}"
endef

define spark_dist
@cd $(DIST_DIR)
@ls spark-*.tgz
endef


.PHONY: build-env clean clean-dist clean-test-env clean-scala-build-jar cli cluster dev-dist prod-dist docker-dist docker-build docker-login test
