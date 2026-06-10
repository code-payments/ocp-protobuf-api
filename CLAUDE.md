# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains the Open Code Protocol (OCP) Protobuf API definitions for communication between OCP clients and server. It uses Protocol Buffers to define gRPC services and generates client code for Go and TypeScript/JavaScript. The APIs target the Solana blockchain (Ed25519 keys, Solana transactions, the Code VM) and power payment, currency launchpad, and swap flows.

## Build & Code Generation

All code generation runs in Docker containers to ensure consistent builds across environments. Generated code is committed to the repository under `generated/`.

```bash
make                 # Clean, build Docker images, and generate all code
make go              # Generate Go code only
make protobuf-es     # Generate TypeScript/JavaScript code only
make clean           # Remove all generated code
make docker-build    # Build Docker images without generating
```

There are no tests in this repository; correctness is enforced via buf linting/breaking-change detection (`proto/buf.yaml`, FILE-level breaking rules) and by regenerating code.

### How generation works
- `build/go/Dockerfile` + `build/go/generate.sh` - golang:1.25 image with protoc, protoc-gen-go, protoc-gen-go-grpc, and protoc-gen-validate. Generates into `generated/go/` (the Makefile flattens the `github.com/...` output path).
- `build/protobuf-es/Dockerfile` + `build/protobuf-es/generate.sh` - generates TypeScript via protoc-gen-es and protoc-gen-connect-es into `generated/protobuf-es/`, and auto-creates `index.ts` barrel files with namespaced exports (e.g. `export * as Common from './common/v1'`).
- After changing any `.proto` file, run `make` and commit the regenerated code along with the proto change.

## Project Structure

### Proto Definitions (`proto/`)
Service proto files are prefixed with `ocp_` to avoid filename conflicts with implementation apps (renamed in PR #51 — keep this convention for new files):

- `proto/common/v1/model.proto` - Shared types used across all services
- `proto/account/v1/ocp_account_service.proto` (~215 lines) - Account service
- `proto/currency/v1/ocp_currency_service.proto` (~570 lines) - Currency/launchpad service
- `proto/messaging/v1/ocp_messaging_service.proto` (~245 lines) - Messaging service
- `proto/transaction/v1/ocp_transaction_service.proto` (~1385 lines) - Transaction/intent/swap service (largest and most complex)
- `proto/buf.yaml` - Buf config (FILE breaking detection, DEFAULT lint, deps on protoc-gen-validate and googleapis)

Package names follow `ocp.<service>.v1`. Go packages are `github.com/code-payments/ocp-protobuf-api/generated/go/<service>/v1`.

Import dependency graph (relevant when adding cross-service types):
- `common` depends on nothing (besides google/validate)
- `currency` imports `common`
- `transaction` imports `common`, `currency`
- `account` and `messaging` import `common`, `currency`, `transaction`

### Generated Code
- `generated/go/` - Go code with gRPC stubs and validate methods
- `generated/protobuf-es/` - TypeScript via Protobuf-ES/Connect-ES with index.ts barrels

## Architecture

### Common Types (proto/common/v1/model.proto)
- **AccountType enum**: how an account is used (PRIMARY, REMOTE_SEND_GIFT_CARD, SWAP, ASSOCIATED_TOKEN_ACCOUNT, POOL)
- **Solana primitives**: SolanaAccountId (32-byte Ed25519 key), SolanaAddressLookupTable (ALTs for versioned transactions), Transaction (max 1232 bytes), Blockhash, Signature (64 bytes)
- **OCP primitives**: IntentId, SwapId, Hash (32 bytes), UUID (16 bytes)
- **Generic RPC wrappers**: Request/Response with versioning
- **ServerPing/ClientPong**: keepalive protocol used by streaming RPCs (currency live data, messaging keepalive streams)
- **Interval enum**: RAW/SECOND/MINUTE/HOUR/DAY/WEEK

### Account Service (2 RPCs)
- `IsOcpAccount` - whether an owner account is an OCP account (can fail with UNLOCKED_TIMELOCK_ACCOUNT)
- `GetTokenAccountInfos` - token account metadata for an owner, with optional filters (token address, account type, mint). `TokenAccountInfo` carries balance source (blockchain vs cache), management state (LOCKING/LOCKED/UNLOCKING/UNLOCKED/CLOSING/CLOSED — reflects OCP's co-signing authority over timelock accounts), blockchain state, gift card claim state, mint metadata, live launchpad reserve state, and USD cost basis. Supports a secondary `requesting_owner` signature for cases like a user inspecting a gift card account.

### Currency Service (8 RPCs) — launchpad + market data
- `GetMints` - mint metadata by address. `Mint` includes decimals, name/symbol/description, image, social links, bill customization (1-3 hex colors), holder metrics, `VmMetadata` (VM address/authority/omnibus; only currencies with a VM are usable for payments; 21-day lock duration), and `LaunchpadMetadata` (currency config, liquidity pool, seed, bonding-curve supply, hardcoded 1% sell fee, price, market cap).
- `GetHistoricalMintData` / `StreamLiveMintData` - historical market cap and live streamed data (verified core-mint fiat exchange rates and launchpad reserve states) with ping/pong keepalive.
- `Launch` - launch a new currency on the launchpad. Name/symbol are printable-ASCII validated; name, symbol, description, and icon each require/accept a `ModerationAttestation` (opaque server-verifiable proof that content passed moderation).
- `UpdateIcon` / `UpdateMetadata` - mutate icon, description, bill customization, social links (with moderation attestations).
- `Discover` - server-streamed currency discovery (POPULAR/NEW categories).
- `CheckAvailability` - check whether a currency name is available before launch.

**Verified data pattern**: `VerifiedCoreMintFiatExchangeRate` and `VerifiedLaunchpadCurrencyReserveState` wrap data with a server signature so clients can later submit them as proofs in payment/swap flows (e.g. `VerifiedExchangeData` in intents). New price/state data that feeds payments should follow this pattern.

### Transaction Service (9 RPCs) — intents and swaps

**Intent system** (`SubmitIntent`): client and server never exchange transactions/instructions directly — they exchange required accounts and arguments, and each side independently constructs and validates transactions (or Code VM virtual instructions). The streaming RPC bundles two unary calls for DB-level transaction semantics: client sends `SubmitActions` (intent ID, owner, metadata, ordered actions, auth signature) → server validates and returns `ServerParameters` (one per action, including durable nonces/blockhashes) → client constructs locally, validates, signs → client sends `SubmitSignatures` → server verifies against its own locally constructed transactions and returns `Success` or `Error` (with structured `ErrorDetails`, e.g. the expected transaction or virtual instruction hash on signature mismatch).

Intent metadata types (each proto comment documents its exact "Action Spec"):
- `OpenAccountsMetadata` - open user (PRIMARY) or POOL accounts
- `SendPublicPaymentMetadata` - payments, withdrawals (with optional CREATE_ON_SEND_WITHDRAWAL fee), and remote send (gift card creation with auto-return)
- `ReceivePaymentsPubliclyMetadata` - claim a gift card (closes the account)
- `PublicDistributionMetadata` - distribute all of a pool's funds and close it
- Optional `AppMetadata` (opaque app-level bytes) can be attached to any intent

Action types: `OpenAccountAction`, `NoPrivacyTransferAction`, `NoPrivacyWithdrawAction`, `FeePaymentAction`. Every action/metadata carries the `mint` it operates against (multi-mint support). New-intent submissions use `VerifiedExchangeData` (proof-backed via verified exchange rate / reserve state); server returns plain `ExchangeData` for submitted intents.

**Swaps** sit outside the intent system because they're time-sensitive and unreliable; transactions are submitted best-effort outside the Code sequencer and balance changes apply after finalization:
- `StatefulSwap` - non-custodial state-managed swaps. Mirrors SubmitIntent flow (Initiate → ServerParameters → SubmitSignatures, 1-2 signatures: owner and swap_authority). Two client parameter kinds: **Reserve** (launchpad bonding-curve buy/sell/swap; funding via SUBMIT_INTENT, EXTERNAL_WALLET, or COINBASE_ONRAMP) and **CoinbaseStableSwapper** (stablecoin swaps). Server parameter variants cover existing-currency Reserve flows, new-currency Reserve flows (atomic currency creation + buy, creator-only), and Coinbase Stable Swapper flows — each documents the exact Solana v0 transaction instruction format in proto comments. Swap state machine: CREATED → FUNDING → FUNDED → SUBMITTING → FINALIZED / FAILED / CANCELLING / CANCELLED.
- `StatelessSwap` - like StatefulSwap but with no state management; currently CoinbaseStableSwapper only, single owner signature, regular blockhash (no durable nonce), optional `wait_for_finalization`.
- `GetSwap` / `GetPendingSwaps` - swap metadata and swaps pending client action. `SwapMetadata` wraps `VerifiedSwapMetadata` signed by the owner so state can't be tampered with.
- Also: `GetIntentMetadata`, `GetLimits` (identity-aware send limits by currency), `CanWithdrawToAccount` (withdrawal destination hints + fee), `VoidGiftCard` (idempotent).

### Messaging Service (5 RPCs)
Messages are routed via a **rendezvous key** — a keypair typically derived from a scan code payload, establishing an anonymous channel between payment participants. RPCs: `OpenMessageStream`, `OpenMessageStreamWithKeepAlive` (ping/pong protocol), `PollMessages` (temporary polling alternative), `AckMessages`, `SendMessage`. Message kinds: `RequestToGiveBill` (sender specifies mint + verified exchange data) and `RequestToGrabBill` (recipient provides destination). Server injects message IDs and echoes the sender's request signature so recipients can detect MITM tampering. The bill give/grab scan-code flow is documented step-by-step in the `OpenMessageStream` comment.

## Conventions

- **Authentication**: requests include a `signature` field computed with the relevant private key over `serialize(request)` with the signature field(s) unset. Nearly every RPC follows this; new RPCs should too.
- **Validation**: `protoc-gen-validate` annotations everywhere — required messages, byte lengths, regex patterns (currency codes `^[a-z]{3,4}$`, printable-ASCII names, hex colors), enum restrictions, repeated min/max items. Add validation rules to all new fields.
- **Result enums**: responses define a nested `Result`/`Code` enum with `OK = 0` plus failure cases, rather than using gRPC status codes.
- **Streaming request/response oneofs**: bidirectional streams use a `oneof` with `option (validate.required) = true` to multiplex message types (request/pong, response/ping, etc.).
- **Versioning**: services live under `v1` packages; buf FILE-level breaking change detection applies, so never renumber/retype existing fields — add new fields or new oneof variants instead.
- **Quarks**: token amounts are in quarks (the smallest unit of a mint), as uint64.
- Proto comments are the source of truth for protocol flows (action specs, instruction formats, keepalive protocols) — keep them updated when changing behavior.

## Dependencies

- **Buf**: proto linting, FILE-level breaking change detection, remote deps (`buf.build/envoyproxy/protoc-gen-validate`, `buf.build/googleapis/googleapis`)
- **protoc-gen-validate** v1.2.1: validation annotations and generated `Validate()` methods
- Go 1.25+, grpc v1.71, protobuf v1.36 (see `go.mod`)
- **Protobuf-ES / Connect-ES** for TypeScript generation
