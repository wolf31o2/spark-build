ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SPARK_DIR := $(ROOT_DIR)/spark
BUILD_DIR := $(ROOT_DIR)/build
DIST_DIR := $(BUILD_DIR)/dist
SHELL := /bin/bash
CLI_VERSION := $(shell jq -r ".cli_version" "$(ROOT_DIR)/manifest.json")
HADOOP_VERSION := $(shell jq ".default_spark_dist.hadoop_version" "$(ROOT_DIR)/manifest.json")
SPARK_DIST := $(shell jq ".default_spark_dist.uri" "$(ROOT_DIR)/manifest.json")
GIT_COMMIT := $(shell git rev-parse HEAD)
DOCKER_IMAGE := mesosphere/spark-dev:$(GIT_COMMIT)

TEMPLATE_CLI_VERSION := $(CLI_VERSION)
TEMPLATE_SPARK_DIST_URI := $(SPARK_DIST)
TEMPLATE_DOCKER_IMAGE := $(DOCKER_IMAGE)

.ONESHELL:
.SHELLFLAGS := -e

$(SPARK_DIR):
	git clone https://github.com/mesosphere/spark $(SPARK_DIR)

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

$(DIST_DIR): manifest-dist

docker: $(DIST_DIR)
	tar xvf $(DIST_DIR)/spark-*.tgz -C $(DIST_DIR)
	rm -rf $(BUILD_DIR)/docker
	mkdir -p $(BUILD_DIR)/docker/dist
	cp -r $(DIST_DIR)/spark-*/. $(BUILD_DIR)/docker/dist
	cp -r conf/* $(BUILD_DIR)/docker/dist/conf
	cp -r docker/* $(BUILD_DIR)/docker
	cd $(BUILD_DIR)/docker && docker build -t $(DOCKER_IMAGE) .
	docker push $(DOCKER_IMAGE)


cli:
	$(MAKE) --directory=cli all

universe: cli docker
	$(ROOT_DIR)/bin/dcos-commons-tools/aws_upload.py \
		spark \
        $(ROOT_DIR)/universe/ \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark-darwin \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark-linux \
        $(ROOT_DIR)/cli/dcos-spark/dcos-spark.exe \
        $(ROOT_DIR)/cli/python/dist/*.whl

test:
	bin/test.sh

.PHONY: clean-dist cli dev-dist prod-dist docker test universe
