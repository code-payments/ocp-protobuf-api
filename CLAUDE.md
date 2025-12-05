# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains the Open Code Protocol (OCP) Protobuf API definitions for communication between OCP clients and server. It uses Protocol Buffers to define gRPC services and generates client code for multiple languages (Go and TypeScript/JavaScript).

## Build & Code Generation

All code generation is handled via Docker to ensure consistent builds across environments. Generated code is committed to the repository under `generated/`.

### Generate all code:
```bash
make
```

### Generate specific language:
```bash
make go              # Generate Go code only
make protobuf-es     # Generate TypeScript/JavaScript code only
```

### Clean generated code:
```bash
make clean
```

### Build Docker images without generating:
```bash
make docker-build
```

## Project Structure

### Proto Definitions
- `proto/` - All Protocol Buffer definitions organized by service and version
  - `proto/common/v1/model.proto` - Shared types used across all services (SolanaAccountId, Transaction, Signature, etc.)
  - `proto/account/v1/` - Account management service (checking Code accounts, token account metadata)
  - `proto/transaction/v1/` - Transaction and intent submission service (largest service at ~1200 lines)
  - `proto/messaging/v1/` - Messaging service
  - `proto/currency/v1/` - Currency/exchange rate service
  - `proto/buf.yaml` - Buf configuration with breaking change detection and linting

### Generated Code
- `generated/go/` - Generated Go code with gRPC stubs
- `generated/protobuf-es/` - Generated TypeScript/JavaScript code using Protobuf-ES

### Build Configuration
- `build/go/Dockerfile` - Docker image for Go code generation (uses golang:1.25, protoc, protoc-gen-go, protoc-gen-validate)
- `build/protobuf-es/Dockerfile` - Docker image for TypeScript/JavaScript code generation
- `Makefile` - Orchestrates Docker-based code generation

## Architecture

### Common Types (proto/common/v1/model.proto)
The `common/v1/model.proto` file defines foundational types used throughout the API:
- **Account Types**: Enum defining how accounts are used (PRIMARY, REMOTE_SEND_GIFT_CARD, SWAP, ASSOCIATED_TOKEN_ACCOUNT, POOL)
- **Solana Primitives**: SolanaAccountId (32-byte Ed25519 public keys), Transaction, Blockhash, Signature
- **Code Primitives**: IntentId, SwapId, Hash, UUID
- **Generic RPC Wrappers**: Request/Response with versioning
- **Ping/Pong**: ServerPing and ClientPong for network latency measurements

### Service Organization
Services follow versioned API patterns (`v1`) with clear separation of concerns:

1. **Account Service** - Manages Code account verification and token account metadata including balance sources (blockchain vs cache), management states (locked/unlocked), and claim states for gift cards

2. **Transaction Service** - Handles intent submission using a streaming RPC pattern for DB-level transaction semantics. Client and server independently construct transactions and exchange only accounts/arguments. Also manages swaps as time-sensitive operations outside the main intent system.

3. **Messaging Service** - Handles messaging functionality

4. **Currency Service** - Manages currency and exchange rate data

### Authentication Pattern
Services use signature-based authentication where clients sign requests with private keys. Requests include both the data and a signature field that is computed over the serialized request without the signature field set.

### Intent System
The Transaction service uses an "intent" model where:
- Client and server never exchange transactions/instructions directly
- Instead they exchange required accounts and arguments
- Both sides independently construct and validate transactions
- Signatures are only generated after full validation
- Uses streaming RPC with two-phase commit semantics

## Dependencies

- **Buf**: Used for proto linting, breaking change detection, and remote dependencies
- **protoc-gen-validate**: Provides validation annotations (required fields, size constraints, etc.)
- **googleapis**: Google common protos (timestamp, duration)
- Go 1.25+ for Go code generation
- Protobuf-ES for TypeScript/JavaScript generation

## Important Notes

- Generated code is committed to version control
- All code generation runs in Docker containers to ensure reproducibility
- Proto files use validation rules extensively via `protoc-gen-validate`
- The codebase targets Solana blockchain primitives (Ed25519 keys, Solana transactions)
- Transaction service is the most complex (~1200 lines) with streaming RPCs and swap functionality
