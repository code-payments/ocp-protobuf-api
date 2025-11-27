USER_ID := $(shell id -u)
GROUP_ID := $(shell id -g)

.NOTPARALLEL:

DOCKER_BUILD_BASE_DIR = ./build
DOCKER_BUILD_GO_DIR = $(DOCKER_BUILD_BASE_DIR)/go
DOCKER_BUILD_PROTOBUF_ES_DIR = $(DOCKER_BUILD_BASE_DIR)/protobuf-es
DOCKER_IMAGE_NAME_PREFIX = ocp-protobuf-api-builder
DOCKER_GO_BUILDER_IMAGE = $(DOCKER_IMAGE_NAME_PREFIX)-go
DOCKER_PROTOBUF_ES_BUILDER_IMAGE = $(DOCKER_IMAGE_NAME_PREFIX)-protobuf-es
PROTO_DIR = ./proto
PROTO_OUT_BASE_DIR = ./generated
PROTO_OUT_GO_DIR = $(PROTO_OUT_BASE_DIR)/go
PROTO_OUT_PROTOBUF_ES_DIR = $(PROTO_OUT_BASE_DIR)/protobuf-es

all: clean docker-build generate

clean:
	@rm -rf $(PROTO_OUT_BASE_DIR)

go: docker-build-go generate-go

protobuf-es: docker-build-protobuf-es generate-protobuf-es

docker-build: docker-build-go docker-build-protobuf-es

docker-build-go:
	@docker build $(DOCKER_BUILD_GO_DIR) -t $(DOCKER_GO_BUILDER_IMAGE)

docker-build-protobuf-es:
	@docker build $(DOCKER_BUILD_PROTOBUF_ES_DIR) -t $(DOCKER_PROTOBUF_ES_BUILDER_IMAGE)

generate: generate-go generate-protobuf-es

generate-go:
	@rm -rf $(PROTO_OUT_GO_DIR)/*
	@mkdir -p $(PROTO_OUT_GO_DIR)
	@docker run --rm -v $(PWD)/$(PROTO_DIR):/proto -v $(PWD)/$(PROTO_OUT_GO_DIR):/$(PROTO_OUT_GO_DIR) --user $(USER_ID):$(GROUP_ID) $(DOCKER_GO_BUILDER_IMAGE)
	@mv $(PROTO_OUT_GO_DIR)/github.com/code-payments/ocp-protobuf-api/generated/go/* $(PROTO_OUT_GO_DIR)
	@rm -rf $(PROTO_OUT_GO_DIR)/github.com

generate-protobuf-es:
	@rm -rf $(PROTO_OUT_PROTOBUF_ES_DIR)/*
	@mkdir -p $(PROTO_OUT_PROTOBUF_ES_DIR)
	@docker run --rm -v $(PWD)/$(PROTO_DIR):/proto -v $(PWD)/$(PROTO_OUT_PROTOBUF_ES_DIR):/genproto --user $(USER_ID):$(GROUP_ID) $(DOCKER_PROTOBUF_ES_BUILDER_IMAGE)

.PHONY: all clean go protobuf-es docker-build docker-build-go docker-build-protobuf-es generate generate-go generate-protobuf-es
