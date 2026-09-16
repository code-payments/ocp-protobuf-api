# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains the Open Code Protocol (OCP) Protobuf API definitions for communication between OCP clients and server (Flipcash is the primary consumer). It uses Protocol Buffers to define gRPC services and generates client code for Go and TypeScript/JavaScript. The APIs target the Solana blockchain (Ed25519 keys, Solana transactions, the Code VM) and power payment, currency launchpad, and swap flows.

The repo is a pure schema repo: no application code, no tests. The deliverable of any change is a `.proto` edit plus the regenerated code under `generated/`, committed together.

## Build & Code Generation

All code generation runs in Docker containers. Docker is the only local prerequisite; `buf` and `protoc` are not installed on the dev machine and are not needed. Generated code is committed to the repository under `generated/`.

```bash
make                 # Clean, build Docker images, and generate all code
make go              # Generate Go code only
make protobuf-es     # Generate TypeScript/JavaScript code only
make clean           # Remove all generated code
make docker-build    # Build Docker images without generating
```

The Makefile is `.NOTPARALLEL`. The first run is slow because the images clone `googleapis` and `protoc-gen-validate` for the shared `validate/` and `google/` imports.

### How generation works
- `build/go/Dockerfile` + `build/go/generate.sh` - `golang:1.25` image. Runs `protoc -I/proto-common:/proto` per file with `--go_out`, `--go-grpc_out`, `--validate_out=lang=go` and `--experimental_allow_proto3_optional`. Output lands at `github.com/code-payments/ocp-protobuf-api/generated/go/...`; the Makefile flattens that path into `generated/go/`.
- `build/protobuf-es/Dockerfile` + `build/protobuf-es/generate.sh` - `node:16-bookworm` image with `protoc-gen-es` and `protoc-gen-connect-es` (`target=ts`). The script also rewrites `import ... "_pb.js"` to `"_pb"` and auto-creates `index.ts` barrels: one per directory (`export * from './ocp_x_service_pb'`) and a root one with namespaced exports (`export * as Balance from './balance/v1'`). New service directories are picked up automatically; nothing manual is needed.
- Each `.proto` yields three Go files (`*.pb.go`, `*_grpc.pb.go`, `*.pb.validate.go`) and two TS files (`*_pb.ts`, `*_connect.ts`).
- `proto/buf.gen.yaml` exists but is not used by the Makefile.

### Toolchain versions (relevant when regenerated output looks unexpectedly different)
- Go generators are pinned: `protoc-gen-go v1.28.1`, `protoc-gen-go-grpc v1.2.0`, `protoc-gen-validate v0.1.0` (plugin; the Go runtime dep in `go.mod` is v1.2.1). `protoc` comes from Debian bookworm (3.21.12). Both Dockerfiles carry a `todo` to version dependencies.
- The npm generators are **unpinned** (`npm i @bufbuild/protoc-gen-es @bufbuild/protoc-gen-connect-es ...`). Committed TS was generated with `protoc-gen-es v1.10.1` (the class-based Protobuf-ES v1 API, legacy `@bufbuild/connect` packages). If a fresh image build pulls a newer major and `make protobuf-es` rewrites every TS file, that is the cause, not your proto change. Don't commit sweeping unrelated TS churn without flagging it.
- After `make`, check `git status`: only the proto you touched and its corresponding `generated/go/<svc>/v1` and `generated/protobuf-es/<svc>/v1` files should differ (plus the root `index.ts` if you added a service).

### Linting / breaking-change detection
`proto/buf.yaml` configures FILE-level breaking detection and DEFAULT lint, but nothing in this repo (Makefile or CI) runs buf, and there is no `.github/` directory. Treat the config as a statement of intent:
- Never renumber, retype, or rename existing fields/messages/enums. Add new fields or new `oneof` variants instead.
- The existing protos deliberately deviate from DEFAULT lint in places (bare enum values like `OK = 0`, `oneof Filter`, PascalCase values in `CanWithdrawToAccountResponse.AccountType`). Match the surrounding style rather than "fixing" lint.
- Some misspelled identifiers are locked in by compatibility and must stay: `VerifiedLaunchapdCurrencyReserveStateBatch`, `AckMesssagesResponse`. Don't rename them.
- Breaking removals have been done when clients were coordinated (PR #66 removed the `GetBalance` RPC), but default to additive changes and confirm with the user before removing or renaming anything public.

## Project Structure

### Proto Definitions (`proto/`)
Service proto files are prefixed with `ocp_` to avoid filename conflicts with implementation apps (renamed in PR #51; keep this convention for new files). Sizes below are approximate and drift; `transaction` is by far the largest.

- `proto/common/v1/model.proto` - Shared types used across all services
- `proto/account/v1/ocp_account_service.proto` - Account service
- `proto/balance/v1/ocp_balance_service.proto` - Balance service (smallest)
- `proto/currency/v1/ocp_currency_service.proto` - Currency/launchpad service
- `proto/messaging/v1/ocp_messaging_service.proto` - Messaging service
- `proto/transaction/v1/ocp_transaction_service.proto` - Transaction/intent/swap service (~1400 lines, most complex)
- `proto/buf.yaml` - Buf config (FILE breaking, DEFAULT lint, deps on protoc-gen-validate and googleapis)

Every proto file header follows the same pattern; copy it for new files:
```proto
package ocp.<service>.v1;
option go_package = "github.com/code-payments/ocp-protobuf-api/generated/go/<service>/v1;<service>";
option java_package = "com.codeinc.gen.<service>.v1";
option objc_class_prefix = "CPB<Service>V1";   // transaction uses a legacy "APB" prefix; use CPB for new files
```

Import dependency graph (relevant when adding cross-service types):
- `common` depends on nothing (besides google/validate)
- `currency` imports `common`
- `transaction` imports `common`, `currency`
- `account` and `messaging` import `common`, `currency`, `transaction`
- `balance` imports `common`

### Generated Code
- `generated/go/` - Go code with gRPC stubs and `Validate()` methods (the pinned v0.1.0 plugin predates `ValidateAll()`, so don't expect it). Go module path `github.com/code-payments/ocp-protobuf-api`, packages `.../generated/go/<service>/v1`.
- `generated/protobuf-es/` - TypeScript via Protobuf-ES/Connect-ES with index.ts barrels

### Releases
Consumers pin by git tag (`vX.Y.Z`, semver, published as GitHub releases). `main` is often a few commits ahead of the latest tag (v1.16.0 as of Sept 2026); tagging is a separate step from merging and is not something to do unprompted. Commits are squash-merged PRs whose titles carry the `(#N)` suffix, so the PR title is the commit message.

## Architecture

### Common Types (proto/common/v1/model.proto)
- **AccountType enum**: how an account is used (PRIMARY, REMOTE_SEND_GIFT_CARD, SWAP, ASSOCIATED_TOKEN_ACCOUNT, POOL)
- **Solana primitives**: SolanaAccountId (32-byte Ed25519 key), SolanaAddressLookupTable (ALTs for versioned transactions, 1-256 entries), Transaction (1-1232 bytes), Blockhash (32 bytes), Signature (64 bytes)
- **OCP primitives**: IntentId and SwapId (client-generated, 32 bytes), Hash (32 bytes), UUID (16 bytes)
- **Generic RPC wrappers**: Request/Response with versioning
- **ServerPing/ClientPong**: keepalive protocol used by streaming RPCs (currency live data, messaging keepalive streams). Ping carries the delay before the next ping so clients can detect unhealthy streams.
- **Interval enum**: RAW/SECOND/MINUTE/HOUR/DAY/WEEK

### Account Service (2 RPCs)
- `IsOcpAccount` - whether an owner account is an OCP account (can fail with UNLOCKED_TIMELOCK_ACCOUNT)
- `GetTokenAccountInfos` - token account metadata for an owner, with an optional `oneof Filter` (token address, account type, mint). `TokenAccountInfo` carries balance source (blockchain vs cache; cache is only reliable when LOCKED), management state (NONE/LOCKING/LOCKED/UNLOCKING/UNLOCKED/CLOSING/CLOSED, reflecting OCP's co-signing authority over timelock accounts), blockchain state, gift card claim state, `original_exchange_data` (from `transaction`), mint metadata and live launchpad reserve state (from `currency`), `created_at`, and USD cost basis. Supports a secondary `requesting_owner` + signature for cases like a user inspecting a gift card account (sets `is_gift_card_issuer`).

### Balance Service (1 RPC)
- `GetBalances` - core-mint-denominated balances for a set of `owners` (1-1024), optionally filtered by a `mints` list (empty means every mint each owner holds). Unauthenticated (no `signature` field) because balances are public blockchain state. Returns `balances_by_owner` (map of owner address to `OwnerBalance`, which carries the owner's aggregate `core_mint_value` in quarks and `balances_by_mint`, a map of mint address to `MintBalance`). `Result` is OK/DENIED. The earlier single-owner `GetBalance` RPC was removed in PR #66.

### Currency Service (8 RPCs) — launchpad + market data
- `GetMints` - mint metadata by address (1-1024). `Mint` includes decimals, name/symbol/description, image, social links (Website/X/Telegram/Discord), bill customization (1-3 hex colors), `HolderMetrics` and `MarketCapMetrics` (current value plus up to 4 `PredefinedRange` deltas; only populated where needed, e.g. `Discover`), `VmMetadata` (VM address/authority/omnibus; only currencies with a VM are usable for payments; lock duration is `const = 21` days), and `LaunchpadMetadata` (currency config, liquidity pool, seed, vaults, bonding-curve supply, `sell_fee_bps` `const = 100`, USD price, market cap).
- `GetHistoricalMintData` / `StreamLiveMintData` - historical market cap for a `PredefinedRange`, and live streamed data (batches of verified core-mint fiat exchange rates and launchpad reserve states) with ping/pong keepalive. To change the streamed mint set, close and reopen the stream.
- `Launch` - launch a new currency on the launchpad. Name/symbol are printable-ASCII validated (name pattern `^[!-~]([ -~]*[!-~])?$`, i.e. no leading/trailing spaces); icon up to 1 MB. Name requires a `ModerationAttestation`; symbol, description, and icon accept one (opaque server-verifiable proof that content passed moderation).
- `UpdateIcon` / `UpdateMetadata` - mutate icon, description, bill customization, social links (with moderation attestations). Each field of `UpdateMetadata` is wrapped in its own `*Update` message so "not provided" is distinguishable from "set to empty".
- `Discover` - server-streamed currency discovery (POPULAR/NEW categories).
- `CheckAvailability` - check whether a currency name is available before launch.

**Verified data pattern**: `VerifiedCoreMintFiatExchangeRate` and `VerifiedLaunchpadCurrencyReserveState` wrap data with a server signature so clients can later submit them as proofs in payment/swap flows (e.g. `VerifiedExchangeData` in intents). New price/state data that feeds payments should follow this pattern.

### Transaction Service (9 RPCs) — intents and swaps

**Intent system** (`SubmitIntent`): client and server never exchange transactions/instructions directly. They exchange required accounts and arguments, and each side independently constructs and validates transactions (or Code VM virtual instructions). The streaming RPC bundles two unary calls for DB-level transaction semantics: client sends `SubmitActions` (intent ID, owner, metadata, ordered actions, auth signature) → server validates and returns `ServerParameters` (one per action, in action order, including durable nonces/blockhashes) → client constructs locally, validates, signs → client sends `SubmitSignatures` → server verifies against its own locally constructed transactions and returns `Success` or `Error` (DENIED/INVALID_INTENT/SIGNATURE_ERROR/STALE_STATE with structured `ErrorDetails`, e.g. the expected transaction or virtual instruction hash on signature mismatch). If no client signatures are needed, server returns `Success` directly after step 1.

Intent metadata types (each proto comment documents its exact "Action Spec"; keep those in sync with behaviour changes):
- `OpenAccountsMetadata` - open user (PRIMARY) or POOL accounts
- `SendPublicPaymentMetadata` - payments, withdrawals (with optional CREATE_ON_SEND_WITHDRAWAL fee split out as a `FeePaymentAction`), and **indirect sends** (gift card creation with auto-return). "Indirect send" is the current term (renamed from "remote send" in PR #54); the account type is still `REMOTE_SEND_GIFT_CARD` and the field is `is_indirect_send`.
- `ReceivePaymentsPubliclyMetadata` - claim a gift card (closes the account; `is_indirect_send` is `const = true`)
- `PublicDistributionMetadata` - distribute all of a pool's funds and close it (last distribution is a `NoPrivacyWithdrawAction`)
- Optional `AppMetadata` (opaque app-level bytes, 1-4096) can be attached to any intent

Action types: `OpenAccountAction` (no client signature), `NoPrivacyTransferAction`, `NoPrivacyWithdrawAction` (`should_close` `const = true`), `FeePaymentAction`. `Action.id` must equal its index in the actions list. Every action/metadata carries the `mint` it operates against (multi-mint support). New-intent submissions use `VerifiedExchangeData` (proof-backed via verified exchange rate, plus reserve state for launchpad currencies); server returns plain `ExchangeData` for submitted intents.

**Swaps** sit outside the intent system because they're time-sensitive and unreliable; transactions are submitted best-effort outside the Code sequencer and balance changes apply after finalization:
- `StatefulSwap` - non-custodial state-managed swaps. Mirrors SubmitIntent flow (Initiate → ServerParameters → SubmitSignatures, 1-2 signatures: owner at index 0, `swap_authority` at index 1). `Initiate` also carries a `proof_signature` over `VerifiedSwapMetadata`. Two client parameter kinds:
  - **Reserve** (launchpad bonding-curve buy/sell/swap). Funding via SUBMIT_INTENT, EXTERNAL_WALLET, or COINBASE_ONRAMP (`funding_id` semantics differ per source). Optional `fee_amount` (buys pay a 1% fee routed to `fee_destination` via `VM::TransferForSwapWithFee`, PR #61). `full_amount_exchange_data` is required when creating a new reserve currency with a non-core mint.
  - **CoinbaseStableSwapper** (stablecoin swaps; from-mint is always the core mint, SUBMIT_INTENT funding only, fee must equal `CanWithdrawToAccountResponse.fee_amount`).
  - Server parameter variants: `ReserveExistingCurrencyServerParameters` (buy with/without fee, sell, launchpad-to-launchpad swap), `ReserveNewCurrencyServerParameter` (creator-only; one instruction list when paying with core mint, another treasury-funded sell+buy list for any other mint; currency, VM and deposit ATA are initialized *before* the transaction, so creation is explicitly not atomic), and `CoinbaseStableSwapperServerParameter`. Each documents the exact Solana v0 instruction list in proto comments; update those comments when a flow changes.
  - Swap state machine: CREATED → FUNDING → FUNDED → SUBMITTING → FINALIZED / FAILED / CANCELLING / CANCELLED.
- `StatelessSwap` - like StatefulSwap but with no state management; currently CoinbaseStableSwapper only, single owner signature, regular blockhash (no durable nonce), optional `wait_for_finalization` (Success code SUBMITTED vs FINALIZED; TRANSACTION_FAILED only when waiting).
- `GetSwap` / `GetPendingSwaps` - swap metadata and swaps pending client action. `SwapMetadata` wraps `VerifiedSwapMetadata` signed by the owner so state can't be tampered with.
- Also: `GetIntentMetadata` (signable by owner or rendezvous key), `GetLimits` (identity-aware send limits by currency; client supplies `consumed_since` as local start-of-day), `CanWithdrawToAccount` (destination type hints + `requires_initialization` + fee), `VoidGiftCard` (idempotent).

### Messaging Service (5 RPCs)
Messages are routed via a **rendezvous key**: a keypair typically derived from a scan code payload, establishing an anonymous channel between payment participants. RPCs: `OpenMessageStream`, `OpenMessageStreamWithKeepAlive` (ping/pong protocol), `PollMessages` (temporary polling alternative), `AckMessages`, `SendMessage`. Message kinds: `RequestToGiveBill` (sender specifies mint + verified exchange data; server attaches `Mint` metadata as `AdditionalServerContext`) and `RequestToGrabBill` (recipient provides destination). Server injects message IDs and echoes the sender's request signature so recipients can detect MITM tampering. `OpenMessageStreamRequest.signature` is still optional pending client migration. The bill give/grab scan-code flow is documented step-by-step in the `OpenMessageStream` comment.

## Conventions

- **Authentication**: requests include a `signature` field computed with the relevant private key over `serialize(request)` with the signature field(s) unset. Nearly every RPC follows this; new RPCs should too. Exceptions are public reads of blockchain/market state (`GetBalances`, every Currency RPC except `Launch`/`UpdateIcon`/`UpdateMetadata`, `CanWithdrawToAccount`) and `AckMessages`.
- **Validation**: `protoc-gen-validate` annotations everywhere: required messages, byte lengths, regex patterns (currency codes `^[a-z]{3,4}$`, printable-ASCII names, hex colors `^#[0-9a-fA-F]{6}$`), enum restrictions (`not_in: 0`, `in: [...]`, `defined_only`), `const` for hardcoded protocol values (21-day lock, 100 bps sell fee), repeated min/max items (1024 is the conventional "arbitrary" cap, commented as such). Add validation rules to all new fields.
- **Result enums**: responses define a nested `Result`/`Code` enum with `OK = 0` plus failure cases, rather than using gRPC status codes. Streaming responses use separate `Success` and `Error` messages with their own `Code` enums.
- **Streaming request/response oneofs**: bidirectional streams use a `oneof` with `option (validate.required) = true` to multiplex message types (request/pong, response/ping, initiate/submit_signatures, etc.).
- **Server-only vs client-only fields**: when a message is used in both directions, split them (e.g. `server_exchange_data` vs `client_exchange_data` in a `oneof`; `ReceivePaymentsPubliclyMetadata.exchange_data` is server-provided and rejected on submit). Document which side sets a field.
- **Versioning**: services live under `v1` packages; FILE-level breaking rules apply, so never renumber/retype existing fields. Add new fields or new oneof variants instead.
- **Quarks**: token amounts are in quarks (the smallest unit of a mint), as uint64. Fiat amounts are doubles; limits are floats.
- Proto comments are the source of truth for protocol flows (action specs, instruction formats, keepalive protocols). Keep them updated when changing behavior; downstream client and server implementations are written against them.

## Dependencies

- **Buf**: config only (`proto/buf.yaml`, `buf.lock`); remote deps `buf.build/envoyproxy/protoc-gen-validate`, `buf.build/googleapis/googleapis`. Not run by the Makefile.
- **protoc-gen-validate**: v0.1.0 plugin in the Go image; v1.2.1 Go runtime in `go.mod`
- Go 1.25, grpc v1.71, protobuf v1.36 (see `go.mod`)
- **Protobuf-ES v1 / Connect-ES** (`@bufbuild/*` package names) for TypeScript generation
