# todo: We should version all of these dependencies.

FROM node:16-bookworm

# Base libraries
RUN apt-get update
RUN apt-get install -y protobuf-compiler

WORKDIR /usr/app

# Protobuf-ES protoc dependencies
RUN npm init -y
RUN npm i @bufbuild/buf @bufbuild/protoc-gen-connect-es @bufbuild/protoc-gen-es
RUN npm i @bufbuild/connect @bufbuild/connect-web @bufbuild/protobuf

# Common base proto dependencies
RUN git clone --branch v0.1.0 https://github.com/envoyproxy/protoc-gen-validate
RUN git clone https://github.com/googleapis/googleapis

RUN mkdir /proto-common
RUN cp -r protoc-gen-validate/validate /proto-common/validate
RUN cp -r googleapis/google /proto-common

COPY generate.sh generate.sh
RUN chmod +x generate.sh

ENTRYPOINT [ "./generate.sh" ]