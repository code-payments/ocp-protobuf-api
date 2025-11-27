#!/bin/bash -e

for f in $(find /proto -type f -name "*.proto"); do
    protoc -I/proto-common:/proto $f --go_out=../generated/go --go-grpc_out=../generated/go --validate_out=lang=go:../generated/go --experimental_allow_proto3_optional
done
